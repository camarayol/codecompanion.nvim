local adapter_utils = require("codecompanion.adapters.utils")
local async = require("codecompanion.utils.async")
local config = require("codecompanion.config")
local integrations = require("codecompanion.integrations")
local jsonrpc = require("codecompanion.utils.jsonrpc")
local log = require("codecompanion.utils.log")
local rpc_adapter = require("codecompanion.adapters.rpc")

local TIMEOUTS = {
  DEFAULT = 2e4, -- 20 seconds
  RESPONSE_POLL = 10, -- 10ms
  GRACE_EXIT = 3e3, -- 3 seconds to let an agent shut down after stdin closes
}

local api = vim.api
local uv = vim.uv

---@class CodeCompanion.RPC.Connection
---@field adapter CodeCompanion.RPCAdapter
---@field adapter_modified CodeCompanion.RPCAdapter Modified adapter with environment variables set
---@field chat? CodeCompanion.Chat
---@field session_id? string The agent's session ID
---@field session_file? string The path to the agent's session file
---@field pending_responses table<string, table> Raw responses awaiting a synchronous caller
---@field _state {handle: table, id_gen: CodeCompanion.JsonRPC.IdGenerator, line_buffer: CodeCompanion.JsonRPC.LineBuffer}
---@field _connected boolean
---@field _session_established boolean
---@field _in_flight table<string, CodeCompanion.RPC.Connection.InFlight> Establishment steps currently underway
---@field _pending_callbacks table<string, function> Async callbacks keyed by request ID
---@field _deadlines table<string, table> Response timers keyed by request ID, so hung agents can't wedge a submission
---@field _models table[] Models advertised by the agent
---@field _current_model_id? string
---@field _session_stats? table Token, cost and context statistics last fetched
---@field _event_handler? fun(event: table) Session event listener
---@field _rpc_log? { path: string, write: fun(data: string) } Per-connection log capturing raw protocol traffic
---@field _process_token? table Identifies the current process, so a replaced process's exit can be ignored
---@field _exit_autocmd? number The VimLeavePre autocmd that kills the process if Neovim exits without a clean disconnect
---@field methods table
local Connection = {}

---@class CodeCompanion.RPC.Connection.InFlight
---@field done boolean
---@field success boolean
---@field callbacks function[]

local METHOD_DEFAULTS = {
  decode = vim.json.decode,
  defer_fn = vim.defer_fn,
  encode = vim.json.encode,
  job = vim.system,
  schedule = vim.schedule,
  schedule_wrap = vim.schedule_wrap,
}

---@class CodeCompanion.RPCConnectionArgs
---@field adapter CodeCompanion.RPCAdapter
---@field chat? CodeCompanion.Chat
---@field opts? table

---Create new RPC connection
---@param args CodeCompanion.RPCConnectionArgs
---@return CodeCompanion.RPC.Connection
function Connection.new(args)
  args = args or {}

  local methods = vim.tbl_extend("force", METHOD_DEFAULTS, args.opts or {})

  local self = setmetatable({
    adapter = args.adapter,
    adapter_modified = {},
    chat = args.chat,
    methods = methods,
    pending_responses = {},
    _connected = false,
    _in_flight = {},
    _pending_callbacks = {},
    _deadlines = {},
    _session_established = false,
    _state = { handle = nil, id_gen = jsonrpc.IdGenerator.new(), line_buffer = jsonrpc.LineBuffer.new() },
  }, { __index = Connection }) ---@cast self CodeCompanion.RPC.Connection

  return self
end

---Check whether the agent process is running
---@return boolean
function Connection:is_ready()
  return self._state.handle ~= nil and self._connected
end

---Wait on an establishment step another caller already started
---@param in_flight CodeCompanion.RPC.Connection.InFlight
---@return boolean success
function Connection:_await_in_flight(in_flight)
  if coroutine.running() then
    return async.wait(function(callback)
      table.insert(in_flight.callbacks, callback)
    end)
  end

  -- vim.wait pumps the event loop, so the caller that owns the step can finish
  local defaults = (self.adapter_modified and self.adapter_modified.defaults) or {}
  vim.wait(defaults.timeout or TIMEOUTS.DEFAULT, function()
    return in_flight.done
  end, TIMEOUTS.RESPONSE_POLL)

  return in_flight.success
end

---Run an establishment step once, sharing its result with concurrent callers
---@param opts { key: string, work: fun(): boolean }
---@return boolean success
function Connection:_run_once(opts)
  local in_flight = self._in_flight[opts.key]
  if in_flight then
    return self:_await_in_flight(in_flight)
  end

  in_flight = { done = false, success = false, callbacks = {} }
  self._in_flight[opts.key] = in_flight

  -- An error here must still release the step, or every later caller waits on it forever
  local ok, result = pcall(opts.work)
  if not ok then
    log:error("[rpc::_run_once] Step `%s` failed: %s", opts.key, result)
  end
  local success = ok and result and true or false

  in_flight.done = true
  in_flight.success = success
  self._in_flight[opts.key] = nil

  for _, callback in ipairs(in_flight.callbacks) do
    self.methods.schedule(function()
      callback(success)
    end)
  end

  return success
end

---Start the agent process and mark the connection ready
---@return CodeCompanion.RPC.Connection|nil
function Connection:connect()
  if self:is_ready() then
    return self
  end

  local connected = self:_run_once({
    key = "connect",
    work = function()
      return self:start_agent_process()
    end,
  })

  return connected and self or nil
end

---Create the agent process
---@return boolean success
function Connection:start_agent_process()
  local adapter = self:prepare_adapter()
  self.adapter_modified = adapter

  if rpc_adapter.get_handler(adapter, "setup") then
    if not rpc_adapter.call_handler(adapter, "setup") then
      log:error("[rpc::start_agent_process] Adapter setup failed")
      return false
    end
  end

  self._state.line_buffer:reset()

  self._rpc_log = log.new_response_file()
  log:info("[rpc] RPC log: %s", self._rpc_log.path)

  -- A reconnect can start a second process before the first has exited; the
  -- token lets the first's exit be told apart from the live one
  local process_token = {}
  self._process_token = process_token

  local ok, sysobj = pcall(
    self.methods.job,
    self.adapter_modified.command,
    {
      stdin = true,
      cwd = vim.fn.getcwd(),
      env = vim.tbl_extend("force", adapter.env_replaced or {}, integrations.agent_env()),
      stdout = self.methods.schedule_wrap(function(err, data)
        if err then
          log:error("[rpc::start_agent_process::stdout] Error: %s", err)
        elseif data then
          self:buffer_stdout_and_dispatch(data)
        end
      end),
      stderr = self.methods.schedule_wrap(function(err, data)
        if err then
          log:error("[rpc::start_agent_process::stderr] Error: %s", err)
        end
      end),
    },
    self.methods.schedule_wrap(function(obj)
      self:handle_process_exit(obj.code, obj.signal, process_token)
    end)
  )

  if not ok then
    self._process_token = nil
    log:error("[rpc::start_agent_process] Failed: %s", sysobj)
    return false
  end

  self._state.handle = sysobj
  self._connected = true

  self:_register_exit_autocmd()

  log:debug("[rpc] Process started: %s", table.concat(self.adapter_modified.command, " "))
  return true
end

---Register the hook that kills the process if Neovim exits before a disconnect
---@return nil
function Connection:_register_exit_autocmd()
  self:_clear_exit_autocmd()

  self._exit_autocmd = api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("codecompanion.rpc.disconnect", { clear = false }),
    callback = function()
      pcall(function()
        return self:disconnect({ graceful = false })
      end)
    end,
  })
end

---Drop the exit hook, as the process is already gone or shutting down
---@return nil
function Connection:_clear_exit_autocmd()
  if not self._exit_autocmd then
    return
  end

  pcall(api.nvim_del_autocmd, self._exit_autocmd)
  self._exit_autocmd = nil
end

---Setup the adapter, making a copy and setting environment variables
---@return CodeCompanion.RPCAdapter
function Connection:prepare_adapter()
  local adapter = vim.deepcopy(self.adapter)
  adapter = adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })

  local command = adapter.commands.selected or adapter.commands.default
  local session_file = self:restorable_session_file()
  if session_file then
    command = vim.list_extend(vim.deepcopy(command), { adapter.opts.session_flag, session_file })
  end
  adapter.command = adapter_utils.set_env_vars(adapter, command)

  return adapter
end

---The session file to reopen on reconnect, when the agent keeps one on disk
---@return string|nil
function Connection:restorable_session_file()
  local flag = self.adapter.opts and self.adapter.opts.session_flag
  if not flag or not self.session_file then
    return nil
  end

  -- pi writes a session file on the first message, so there may be nothing to reopen yet
  if not uv.fs_stat(self.session_file) then
    return nil
  end

  return self.session_file
end

---Read the session and models from the agent, once
---@return boolean success
function Connection:ensure_session()
  if self._session_established then
    return true
  end

  if not self:is_ready() then
    return false
  end

  return self:_run_once({
    key = "session",
    work = function()
      local state = self:send_command("get_state")
      if not state or not state.success then
        log:error("[rpc::ensure_session] Failed to read session state")
        return false
      end

      self:_apply_state(state.data)
      self:refresh_session_stats()

      -- A model list is only needed to power the change-model picker
      local models = self:send_command("get_available_models")
      if models and models.success then
        self._models = (models.data and models.data.models) or {}
      end

      self._session_established = true
      return true
    end,
  })
end

---Record the agent's session state
---@param state table|nil
---@return nil
function Connection:_apply_state(state)
  if type(state) ~= "table" then
    return
  end
  self.session_id = state.sessionId
  self.session_file = state.sessionFile
  self._current_model_id = state.model and state.model.id or nil
  self._session_stats = nil
end

---Send a command to the agent process
---@param command_type string
---@param fields? table
---@return table|nil response
function Connection:send_command(command_type, fields)
  if not self._state.handle then
    return nil
  end

  -- pi expects a string ID and echoes it back on the response
  local id = tostring(self._state.id_gen:next())
  local command = vim.tbl_extend("force", { id = id, type = command_type }, fields or {})

  if not self:write_message(self.methods.encode(command) .. "\n") then
    return nil
  end

  -- Async path: yield and let store_response resume us
  if coroutine.running() then
    return async.wait(function(callback)
      self:_register_callback(id, callback)
    end)
  end

  -- Sync fallback
  return self:wait_for_response(id)
end

---Register an async response callback behind a deadline, so an agent that
---accepts the process but never responds can't wedge a submission forever
---@param id string
---@param callback function
---@return nil
function Connection:_register_callback(id, callback)
  self._pending_callbacks[id] = callback

  self._deadlines[id] = self.methods.defer_fn(function()
    -- A fired one-shot timer runs itself down, so only the map entry goes
    self._deadlines[id] = nil

    local pending = self._pending_callbacks[id]
    if not pending then
      return
    end
    self._pending_callbacks[id] = nil
    log:error("[rpc::send_command] Timed out waiting for response ID %s", id)
    pending(nil)
  end, self:timeout())
end

---Cancel the deadline timer for a request ID
---@param id string
---@return nil
function Connection:_clear_deadline(id)
  local timer = self._deadlines[id]
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  self._deadlines[id] = nil
end

---The per-command timeout in milliseconds
---@return number
function Connection:timeout()
  local defaults = (self.adapter_modified and self.adapter_modified.defaults) or {}
  return defaults.timeout or TIMEOUTS.DEFAULT
end

---Wait for a specific response ID
---@param id string
---@return table|nil
function Connection:wait_for_response(id)
  vim.wait(self:timeout(), function()
    return self.pending_responses[id] ~= nil
  end, TIMEOUTS.RESPONSE_POLL)

  local response = self.pending_responses[id]
  self.pending_responses[id] = nil

  if not response then
    log:error("[rpc::wait_for_response] Request timeout ID %s", id)
  end

  return response
end

---Send a prompt to the agent
---@param formatted { message: string, images?: table[] }
---@return table|nil response
function Connection:prompt(formatted)
  local fields = { message = formatted.message or "" }
  if formatted.images and #formatted.images > 0 then
    fields.images = formatted.images
  end

  return self:send_command("prompt", fields)
end

---Abort the agent's current run without waiting for a response
---pi only answers abort once its session is idle, which can outlast the
---caller (Chat:stop runs on the main loop) and the response is never used,
---as the caller has already marked the request finished
---@return boolean
function Connection:abort()
  return self:write_message(self.methods.encode({ type = "abort" }) .. "\n")
end

---Queue a steering message for the agent's running turn
---The agent answers without a request ID to correlate against, so the caller
---does not wait on it
---@param message string
---@return boolean
function Connection:steer(message)
  if not message or message == "" then
    return false
  end
  return self:write_message(self.methods.encode({ type = "steer", message = message }) .. "\n")
end

---Switch the agent to a previous session and refresh our view of its state
---An extension may veto the switch, which reports as cancelled on a success
---@param session_path string
---@return boolean success
function Connection:load_session(session_path)
  local response = self:send_command("switch_session", { sessionPath = session_path })
  if not response or not response.success then
    log:error("[rpc::load_session] Failed to load `%s`", session_path)
    return false
  end

  if response.data and response.data.cancelled == true then
    log:info("[rpc::load_session] Session switch was cancelled by the agent")
    return false
  end

  -- session_id, session_file and the model now describe the loaded session
  local state = self:send_command("get_state")
  if state and state.success then
    self:_apply_state(state.data)
    self:refresh_session_stats()
  end

  return true
end

---Get the agent's full message history, as the agent keeps its own conversation
---@return table|nil messages
function Connection:get_messages()
  local response = self:send_command("get_messages")
  if not response or not response.success then
    return nil
  end

  return response.data and response.data.messages or nil
end

---Get the models the agent advertised
---@return { availableModels: table[], currentModelId: string|nil }|nil
function Connection:get_models()
  if not self._models and not self._current_model_id then
    return nil
  end

  return {
    availableModels = self._models or {},
    currentModelId = self._current_model_id,
  }
end

---The session statistics last fetched, if any
---@return table|nil
function Connection:get_session_stats()
  return self._session_stats
end

---Fetch and cache the session's token, cost and context statistics
---@return nil
function Connection:refresh_session_stats()
  local response = self:send_command("get_session_stats")
  if response and response.success then
    self._session_stats = response.data
  end
end

---Switch the agent to a different model
---@param model_id string
---@return boolean success
function Connection:set_model(model_id)
  local model
  for _, candidate in ipairs(self._models or {}) do
    if candidate.id == model_id then
      model = candidate
      break
    end
  end

  if not model then
    log:error("[rpc::set_model] `%s` is not one of the models the agent reported", model_id)
    return false
  end

  local response = self:send_command("set_model", { provider = model.provider, modelId = model.id })
  if not response or not response.success then
    log:error("[rpc::set_model] Failed to set `%s`", model_id)
    return false
  end

  self._current_model_id = (response.data and response.data.id) or model_id
  log:debug("[rpc::set_model] Switched model to %s", self._current_model_id)
  return true
end

---Register a listener for session events
---@param handler? fun(event: table)
---@return nil
function Connection:set_event_handler(handler)
  self._event_handler = handler
end

---Disconnect and clean up the agent process
---By default the stdin is closed first, as pi treats that as an orderly
---shutdown request, and SIGTERM follows only if the process hasn't exited.
---Neovim teardown can't wait, so pass { graceful = false } to kill immediately
---@param opts? { graceful?: boolean }
---@return nil
function Connection:disconnect(opts)
  opts = opts or {}

  -- Mark the connection not ready straight away, so a later connect restarts
  -- the process rather than reusing one that is being shut down
  self._connected = false
  self._session_established = false
  self:_clear_exit_autocmd()

  local handle = self._state.handle
  if not handle then
    return
  end

  local close_input = pcall(function()
    return handle:write(nil)
  end)

  local function kill()
    pcall(function()
      return handle:kill("sigterm")
    end)
  end

  if not close_input or opts.graceful == false then
    kill()
    return
  end

  self.methods.defer_fn(kill, TIMEOUTS.GRACE_EXIT)
end

---Process the output
---@param data string
function Connection:buffer_stdout_and_dispatch(data)
  -- JSONL guarantees one record per line, but I/O boundaries need not align with records
  self._state.line_buffer:push(data, function(line)
    self:handle_message(line)
  end)
end

---Handle an incoming JSON record
---@param line string
function Connection:handle_message(line)
  if not line or line == "" then
    return
  end

  -- Anything that isn't a protocol record is diagnostics we should ignore
  if not line:match("^%s*{") then
    return
  end

  if self._rpc_log then
    self._rpc_log.write("Received:\n" .. line)
  end

  local ok, message = jsonrpc.decode(line, self.methods.decode)
  if not ok then
    return log:error("[rpc::handle_message] Invalid JSON:\n%s", line)
  end

  if not message.type then
    return log:error("[rpc::handle_message] Invalid message format: %s", message)
  end

  if message.type == "response" then
    self:store_response(message)
  elseif message.type == "extension_ui_request" then
    self:handle_extension_ui_request(message)
  elseif self._event_handler then
    self._event_handler(message)
  end
end

---Handles the response to a command
---@param response table
function Connection:store_response(response)
  if response.id == nil then
    -- A parse failure has no request ID to correlate against
    if response.error then
      log:error("[rpc::store_response] %s", response.error)
    end
    return
  end

  -- Correlate as strings, matching what send_command always sends
  local id = tostring(response.id)

  -- Async path: resume the waiting coroutine via its callback
  local cb = self._pending_callbacks[id]
  if cb then
    self._pending_callbacks[id] = nil
    self:_clear_deadline(id)
    self.methods.schedule(function()
      cb(response)
    end)
    return
  end

  -- Sync path: store for polling under the same string ID send_command used
  self.pending_responses[id] = response
end

---Answer a blocking dialog with a cancellation so the agent isn't left waiting
---@param request table
---@return nil
function Connection:handle_extension_ui_request(request)
  local dialogs = { select = true, confirm = true, input = true, editor = true }
  if not dialogs[request.method] then
    return
  end

  self:write_message(self.methods.encode({
    type = "extension_ui_response",
    id = request.id,
    cancelled = true,
  }) .. "\n")
end

---Send data to the agent process
---@param data string
---@return boolean
function Connection:write_message(data)
  if not self._state.handle then
    log:error("[rpc::write_message] Process not running")
    return false
  end

  if self._rpc_log then
    self._rpc_log.write("Sent:\n" .. vim.trim(data))
  end

  local ok, err = pcall(function()
    self._state.handle:write(data)
  end)

  if not ok then
    log:error("[rpc::write_message] Failed to send data: %s", err)
    return false
  end

  return true
end

---Handle process exit
---@param code number
---@param signal number
---@param process_token? table The token of the process this exit belongs to
function Connection:handle_process_exit(code, signal, process_token)
  -- A reconnect may have already replaced this process; leave the new one alone
  if process_token and process_token ~= self._process_token then
    return
  end
  self._process_token = nil

  log:debug("[rpc] Process exited (code=%s, signal=%s)", code, signal)

  if self.adapter_modified then
    rpc_adapter.call_handler(self.adapter_modified, "on_exit", { code = code })
  end

  -- Fire any pending async callbacks so coroutines don't hang
  for id, cb in pairs(self._pending_callbacks) do
    self._pending_callbacks[id] = nil
    pcall(cb, nil)
  end

  -- Let the active request know the agent is gone, or it waits for a settle that never comes
  if self._event_handler then
    local handler = self._event_handler
    self._event_handler = nil
    pcall(handler, { type = "_process_exit", code = code, signal = signal })
  end

  self._state.handle = nil
  self._connected = false
  self._session_established = false
  self._pending_callbacks = {}
  self.pending_responses = {}

  -- The responses can never arrive now, so the timers have no purpose
  for id, timer in pairs(self._deadlines) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    self._deadlines[id] = nil
  end

  self.adapter_modified = nil
  self:_clear_exit_autocmd()
end

return Connection
