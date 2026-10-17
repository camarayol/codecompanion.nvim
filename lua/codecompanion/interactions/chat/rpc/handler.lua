local adapters = require("codecompanion.adapters")
local async = require("codecompanion.utils.async")
local config = require("codecompanion.config")
local formatter = require("codecompanion.interactions.chat.rpc.formatters")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")
local watch = require("codecompanion.interactions.shared.watch")

local FILE_TOOLS = { edit = true, write = true }

---@class CodeCompanion.Chat.RPCHandler
---@field chat CodeCompanion.Chat
---@field output table Standard output message from the agent
---@field reasoning table Reasoning output from the agent
---@field tool_calls table<string, table> Name and arguments of in-flight tool calls, by tool call ID
---@field ui_state table<string, table> Cache of tool call UI states (line_number, icon_id) by tool call ID
---@field _event_data? table Data fired alongside RequestStarted/RequestFinished
---@field _finished? boolean The run has ended, so later events are ignored
---@field _streaming_started boolean
---@field _text_streamed boolean
---@field _thought_streamed boolean
local RPCHandler = {}

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.RPCHandler
function RPCHandler.new(chat)
  local self = setmetatable({
    chat = chat,
    output = {},
    reasoning = {},
    tool_calls = {},
    ui_state = {},
    _finished = false,
    _streaming_started = false,
    _text_streamed = false,
    _thought_streamed = false,
  }, { __index = RPCHandler })

  return self --[[@type CodeCompanion.Chat.RPCHandler]]
end

---Submit payload to the agent, registering the request on the chat before connecting
---@param payload table The payload to send to the LLM
---@return nil
function RPCHandler:submit(payload)
  local request = {}
  request.cancel = function()
    request.cancelled = true
    -- Marking finished drops later events, so close the request here
    if not self._finished then
      self._finished = true
      self:_finish("cancelled")
    end
    if self.chat.rpc_connection then
      self.chat.rpc_connection:abort()
    end
  end

  -- IMPORTANT: Registered before the connect below, so a second <CR> can't start a parallel submit
  self.chat.current_request = request

  -- Keep the agent's request off the main loop
  async.sync(function()
    local session_ready = self:ensure_connection() and self:ensure_session()

    -- A stop or a newer submission can replace this request while the agent boots
    if request.cancelled or self.chat.current_request ~= request then
      return
    end

    if not session_ready then
      local commands = self.chat.adapter.commands or {}
      local command = commands.selected or commands.default
      self:handle_error(
        ("Could not connect to %s. Check that `%s` runs on its own."):format(
          self.chat.adapter.formatted_name,
          table.concat(command or {}, " ")
        )
      )
      return
    end

    self:create_and_send_prompt(payload)
  end)()
end

---Ensure the RPC connection to the agent
---@return boolean
function RPCHandler:ensure_connection()
  if self.chat.rpc_connection and self.chat.rpc_connection:is_ready() then
    return true
  end

  if not self.chat.rpc_connection then
    local adapter = self.chat.adapter --[[@as CodeCompanion.RPCAdapter]]
    self.chat.rpc_connection = require("codecompanion.rpc").new({
      adapter = adapter,
      chat = self.chat,
    })
  end

  if not self.chat.rpc_connection:connect() then
    return false
  end

  self.chat:update_metadata()
  watch.enable()
  utils.fire("RPCConnected", { bufnr = self.chat.bufnr })

  return true
end

---Read the session and models from the agent
---@return boolean success
function RPCHandler:ensure_session()
  local conn = self.chat.rpc_connection
  if not conn then
    return false
  end

  if not conn:ensure_session() then
    return false
  end

  self.chat:update_metadata()

  return true
end

---Create and send the prompt, wiring up the event stream
---@param payload table
---@return nil
function RPCHandler:create_and_send_prompt(payload)
  local conn = self.chat.rpc_connection
  conn:set_event_handler(function(event)
    self:process_event(event)
  end)

  local formatted = adapters.call_handler(self.chat.adapter, "build_messages", { messages = payload.messages })
  if not formatted then
    return self:handle_error(
      ("The `%s` adapter has no `handlers.request.build_messages` handler"):format(self.chat.adapter.name)
    )
  end

  local models = conn:get_models()
  self._event_data = {
    id = tostring(math.random(10000000)),
    adapter = {
      name = self.chat.adapter.name,
      formatted_name = self.chat.adapter.formatted_name,
      type = self.chat.adapter.type,
      model = models and models.currentModelId,
    },
    bufnr = self.chat.bufnr,
    interaction = "chat",
  }
  utils.fire("RequestStarted", self._event_data)

  local response = conn:prompt(formatted)

  if not response or not response.success then
    local error_message = (response and response.error) or "The agent rejected the prompt"
    self:handle_error(error_message)
    return nil
  end

  -- A handled prompt never starts a run, so no `agent_settled` will follow
  if response.data and response.data.disposition == "handled" then
    self:handle_complete(false)
  end
end

---Route a session event from the agent
---@param event table
---@return nil
function RPCHandler:process_event(event)
  if self._finished or type(event) ~= "table" then
    return
  end

  if event.type == "message_start" then
    self:handle_message_start(event.message)
  elseif event.type == "message_update" then
    self:handle_message_update(event.assistantMessageEvent)
  elseif event.type == "message_end" then
    self:handle_message_end(event.message)
  elseif event.type == "tool_execution_start" then
    self:process_tool_event(event, "in_progress")
  elseif event.type == "tool_execution_update" then
    self:process_tool_event(event, "in_progress")
  elseif event.type == "tool_execution_end" then
    self:process_tool_event(event, event.isError and "failed" or "completed")
  elseif event.type == "agent_settled" then
    self:handle_complete(event.aborted == true)
  elseif event.type == "session_info_changed" then
    if type(event.name) == "string" and event.name ~= "" then
      self.chat:set_title(event.name)
    end
  elseif event.type == "_process_exit" then
    -- The agent died mid-run; without this the request waits forever
    -- A missing code means the process was signalled out of existence
    if event.code == nil or event.code ~= 0 then
      self:handle_error(
        ("The agent exited unexpectedly (code %s)"):format(event.code or ("signal %s"):format(event.signal or "?"))
      )
    else
      self:handle_complete(false)
    end
  end
end

---Fire the streaming event once, on the first sign of output
---@return nil
function RPCHandler:_ensure_streaming()
  if self._streaming_started then
    return
  end

  self._streaming_started = true
  utils.fire("RequestStreaming", self._event_data)
end

---Reset the streamed-content tracking for a new assistant message
---@param message? table
---@return nil
function RPCHandler:handle_message_start(message)
  if type(message) ~= "table" or message.role ~= "assistant" then
    return
  end

  self._text_streamed = false
  self._thought_streamed = false
end

---Handle the final message, where provider errors and any unstreamed text land
---@param message? table
---@return nil
function RPCHandler:handle_message_end(message)
  if type(message) ~= "table" or message.role ~= "assistant" then
    return
  end

  if message.stopReason == "error" then
    return self:handle_error(message.errorMessage or "The agent reported an error")
  end

  -- A provider that didn't stream deltas only reports the text here
  if not self._text_streamed then
    local text = formatter.message_text(message.content)
    if text ~= "" then
      self:handle_message_chunk(text)
    end
  end
end

---Handle a streaming update to an assistant message
---@param update? table
---@return nil
function RPCHandler:handle_message_update(update)
  if type(update) ~= "table" then
    return
  end

  if update.type == "text_delta" and update.delta and update.delta ~= "" then
    self:handle_message_chunk(update.delta)
  elseif update.type == "thinking_delta" and update.delta and update.delta ~= "" then
    self:handle_thought_chunk(update.delta)
  elseif update.type == "text_end" and not self._text_streamed and update.content then
    -- Fallback for a provider that didn't stream deltas
    self:handle_message_chunk(update.content)
  elseif update.type == "thinking_end" and not self._thought_streamed and update.content then
    self:handle_thought_chunk(update.content)
  end
end

---Handle incoming message chunks
---@param content string
---@return nil
function RPCHandler:handle_message_chunk(content)
  self:_ensure_streaming()

  self._text_streamed = true
  table.insert(self.output, content)
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = content },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )
end

---Handle incoming thought chunks
---@param content string
---@return nil
function RPCHandler:handle_thought_chunk(content)
  self:_ensure_streaming()
  self._thought_streamed = true
  table.insert(self.reasoning, content)
  if config.display.chat.show_reasoning then
    self.chat:add_buf_message(
      { role = config.constants.LLM_ROLE, content = content },
      { type = self.chat.MESSAGE_TYPES.REASONING_MESSAGE }
    )
  end
end

---Output a tool execution to the chat
---@param event table
---@param status string
---@return nil
function RPCHandler:process_tool_event(event, status)
  self:_ensure_streaming()

  local call = self:_merge_tool_event(event)
  local id = call.toolCallId
  local content = self:_tool_label(call, status)
  local finished = status == "completed" or status == "failed"

  if finished then
    self.tool_calls[id] = nil
    self:_track_edited_file(call, status)
  end

  -- If the tool has already written to the chat buffer, update the existing line
  local cached = id and self.ui_state[id]
  if cached then
    local ok, _, new_icon_id = pcall(self.chat.update_buf_line, self.chat, {
      line_number = cached.line_number,
      content = content,
      status = status,
      icon_id = cached.icon_id,
      priority = 120,
      virt_text_pos = "inline",
    })

    if ok then
      if finished then
        self.ui_state[id] = nil
      elseif new_icon_id then
        cached.icon_id = new_icon_id
      end
      return
    end

    if finished then
      self.ui_state[id] = nil
    end
    log:debug("[RPC::Handler] Failed to update tool call line for toolCallId %s", id)
  end

  local line_number, icon_id = self.chat:add_buf_message({
    role = config.constants.LLM_ROLE,
    content = content,
  }, {
    status = status,
    virt_text_pos = "inline",
    tools = { call_id = id },
    type = self.chat.MESSAGE_TYPES.TOOL_MESSAGE,
  })

  if not finished and id then
    self.ui_state[id] = { line_number = line_number, icon_id = icon_id }
  end
end

---Keep the name and arguments a tool call started with, as pi only sends them
---once and later events carry just the result
---@param event table
---@return table
function RPCHandler:_merge_tool_event(event)
  local id = event.toolCallId
  if not id then
    return event
  end

  local call = self.tool_calls[id] or {}
  self.tool_calls[id] = call

  for _, key in ipairs({ "toolName", "args" }) do
    if event[key] ~= nil then
      call[key] = event[key]
    end
  end

  return vim.tbl_extend("force", call, event)
end

---Format a tool event for the chat buffer, never raising on a malformed event
---@param event table
---@param status string
---@return string
function RPCHandler:_tool_label(event, status)
  local ok, content = pcall(formatter.tool_message, vim.tbl_extend("force", event, { status = status }))
  if not ok then
    return "[Error formatting tool output]"
  end

  return content
end

---Fire an event for a file a successful tool call has changed, so buffers reload
---@param event table
---@param status string
---@return nil
function RPCHandler:_track_edited_file(event, status)
  if status ~= "completed" or not FILE_TOOLS[event.toolName] then
    return
  end

  local path = type(event.args) == "table" and event.args.path
  if type(path) == "string" and path ~= "" then
    utils.fire("FileEdited", { path = path, tool = self.chat.adapter.name })
  end
end

---Handle the end of the agent's run
---@param aborted boolean
---@return nil
function RPCHandler:handle_complete(aborted)
  if self._finished then
    return
  end
  self._finished = true

  self:_finish(aborted and "cancelled" or "success")

  if not self.chat.status or self.chat.status == "" then
    self.chat.status = aborted and "cancelled" or "success"
  end

  -- An aborted run follows the stop path, so orphaned tool calls are cleaned up
  self.chat:done({
    output = self.output,
    reasoning = self.reasoning,
    tools = {},
    status = aborted and "stopped" or nil,
  })
end

---Handle errors
---@param error string
---@return nil
function RPCHandler:handle_error(error)
  if self._finished then
    return
  end
  self._finished = true

  self:_finish("error", error)

  self.chat.status = "error"
  log:error("[RPC::Handler] %s", error)

  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = formatter.error_message(error) },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )

  self.chat:done({ output = self.output, error = error })
end

---Fire the completion event for this request
---@param status string
---@param error? string
---@return nil
function RPCHandler:_finish(status, error)
  if not self._event_data then
    return
  end

  self._event_data.status = status
  self._event_data.error = error
  utils.fire("RequestFinished", self._event_data)
end

return RPCHandler
