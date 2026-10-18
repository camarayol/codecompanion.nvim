local h = require("tests.helpers")

local new_set = MiniTest.new_set
local T = new_set()
local child = MiniTest.new_child_neovim()

T["RPC Connection"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        h.setup_plugin()

        -- Captured fake process handles
        timers = {}
        stdin_writes = {}
        stdin_closed = 0
        job_started = 0
        stdout_fn = nil
        exit_fn = nil

        function rpc_conn(handlers)
          local Connection = require("codecompanion.rpc")
          local adapter = vim.deepcopy(require("codecompanion.config").adapters.rpc.test_rpc)
          if handlers then
            adapter.handlers = vim.tbl_deep_extend("force", adapter.handlers or {}, handlers)
          end

          timers = {}
          stdin_writes = {}
          stdin_closed = 0
          job_started = 0

          conn = Connection.new({
            adapter = adapter,
            opts = {
              job = function(command, spawn_opts, on_exit)
                job_started = job_started + 1
                stdout_fn = spawn_opts.stdout
                exit_fn = on_exit
                return {
                  -- vim.system processes expose write as a method, so the
                  -- receiver arrives as the first argument
                  write = function(_, data)
                    if data == nil then
                      stdin_closed = stdin_closed + 1
                    else
                      table.insert(stdin_writes, data)
                    end
                  end,
                  kill = function() end,
                }
              end,
              schedule = function(f) f() end,
              schedule_wrap = function(f) return f end,
              defer_fn = function(f)
                table.insert(timers, f)
                return { is_closing = function() return false end, stop = function() end, close = function() end }
              end,
            },
          })

          conn:connect()
          return conn
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC Connection"]["abort()"] = new_set()

T["RPC Connection"]["abort()"]["writes the command with no wait registered"] = function()
  local result = child.lua([[
    rpc_conn()
    stdin_writes = {}
    local ok = conn:abort()

    return {
      wrote = ok,
      json = stdin_writes[1],
    }
  ]])

  h.eq(result.wrote, true)
  h.eq(result.json, '{"type":"abort"}\n')
end

T["RPC Connection"]["steer()"] = new_set()

T["RPC Connection"]["steer()"]["writes the message with no wait registered"] = function()
  local result = child.lua([[
    rpc_conn()
    stdin_writes = {}
    local ok = conn:steer("Take the other path")

    return { wrote = ok, message = vim.json.decode(stdin_writes[1]), armed = vim.tbl_count(conn._deadlines) }
  ]])

  h.eq(result.wrote, true)
  h.eq(result.message, { type = "steer", message = "Take the other path" })
  h.eq(result.armed, 0)
end

T["RPC Connection"]["send_command()"] = new_set()

T["RPC Connection"]["send_command()"]["resolves an async wait on a string response ID"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()

    local outcome = {}
    async.sync(function()
      outcome.state = conn:send_command("get_state")
    end)()

    -- One write on the wire and one armed deadline while we yield
    local wrote = #stdin_writes
    local armed = vim.tbl_count(conn._deadlines)

    stdout_fn(nil, '{"type":"response","id":"1","success":true,"data":{"sessionId":"abc"}}\n')

    return {
      wrote = wrote,
      armed = armed,
      resolved = outcome.state ~= nil,
      success = outcome.state and outcome.state.success,
      deadline_released = vim.tbl_count(conn._deadlines) == 0,
    }
  ]])

  h.eq(result.wrote, 1)
  h.eq(result.armed, 1)
  h.eq(result.resolved, true)
  h.eq(result.success, true)
  h.eq(result.deadline_released, true)
end

T["RPC Connection"]["send_command()"]["DOES resolve an async wait on a numeric response ID"] = function()
  -- pi echoes the string ID it is sent, so a number never arrives; the
  -- correlation must cope regardless, as a miss hangs the submission forever
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()

    local outcome = {}
    async.sync(function()
      outcome.models = conn:send_command("get_available_models")
    end)()

    stdout_fn(nil, '{"type":"response","command":"get_available_models","id":1,"success":true,"data":{"models":[]}}\n')

    return {
      resolved = outcome.models ~= nil,
      success = outcome.models and outcome.models.success,
    }
  ]])

  h.eq(result.resolved, true)
  h.eq(result.success, true)
end

T["RPC Connection"]["send_command()"]["DOES resolve a sync wait on a numeric response ID"] = function()
  -- The sync path is taken outside a coroutine; it must correlate against the
  -- same string ID the async path does, or the wait runs to its timeout
  local result = child.lua([[
    rpc_conn()

    vim.defer_fn(function()
      stdout_fn(nil, '{"type":"response","id":1,"success":true,"data":{"sessionId":"abc"}}\n')
    end, 1)

    local response = conn:send_command("get_state")

    return { resolved = response ~= nil, success = response and response.success }
  ]])

  h.eq(result.resolved, true)
  h.eq(result.success, true)
end

T["RPC Connection"]["send_command()"]["fires the deadline when the agent never responds"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()

    local outcome = {}
    async.sync(function()
      outcome.state = conn:send_command("get_state")
    end)()

    -- The agent accepted the process but went silent
    for _, fire in ipairs(timers) do
      fire()
    end

    return {
      released = outcome.state == nil,
      deadline_released = vim.tbl_count(conn._deadlines) == 0,
      no_pending = vim.tbl_isempty(conn._pending_callbacks),
    }
  ]])

  h.eq(result.released, true)
  h.eq(result.deadline_released, true)
  h.eq(result.no_pending, true)
end

T["RPC Connection"]["send_command()"]["keeps the response cache bounded"] = function()
  local result = child.lua([[
    rpc_conn()

    -- A response no caller ever collects, e.g. one that arrived after its deadline
    for id = 1, 40 do
      stdout_fn(nil, ('{"type":"response","id":"%d","success":true}\n'):format(id))
    end

    return {
      stored = vim.tbl_count(conn.pending_responses),
      oldest = conn.pending_responses["1"] ~= nil,
      newest = conn.pending_responses["40"] ~= nil,
    }
  ]])

  h.eq(result.stored, 32)
  h.eq(result.oldest, false)
  h.eq(result.newest, true)
end

T["RPC Connection"]["refresh_session_stats()"] = new_set()

T["RPC Connection"]["refresh_session_stats()"]["DOES NOT ask an agent that reports no statistics"] = function()
  local result = child.lua([[
    rpc_conn()
    stdin_writes = {}

    conn:refresh_session_stats()

    return { writes = #stdin_writes, cached = conn:get_session_stats() == nil }
  ]])

  h.eq(result.writes, 0)
  h.eq(result.cached, true)
end

T["RPC Connection"]["refresh_session_stats()"]["asks an agent that reports statistics"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()
    conn.adapter.opts.session_stats = true
    stdin_writes = {}

    async.sync(function()
      conn:refresh_session_stats()
    end)()

    local sent = vim.json.decode(stdin_writes[1])
    stdout_fn(nil, '{"type":"response","id":"' .. sent.id .. '","success":true,"data":{"tokens":{"total":42}}}\n')

    local stats = conn:get_session_stats()

    return { command = sent.type, cached = stats and stats.tokens.total }
  ]])

  h.eq(result.command, "get_session_stats")
  h.eq(result.cached, 42)
end

T["RPC Connection"]["ensure_session()"] = new_set()

T["RPC Connection"]["ensure_session()"]["switches to the model the adapter was configured with"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    local connection = rpc_conn()
    connection.adapter_modified.defaults.model = "claude-sonnet-4"

    local established = false
    async.sync(function()
      established = connection:ensure_session()
    end)()

    stdout_fn(nil, '{"id":"1","type":"response","command":"get_state","success":true,"data":{"sessionId":"abc","sessionFile":"/tmp/s.jsonl","model":{"id":"gpt-5-mini"}}}\n')
    stdout_fn(nil, '{"id":"2","type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"claude-sonnet-4","provider":"anthropic"}]}}\n')

    local set_model = vim.json.decode(stdin_writes[#stdin_writes])
    stdout_fn(nil, '{"id":"3","type":"response","command":"set_model","success":true,"data":{"id":"claude-sonnet-4","provider":"anthropic"}}\n')

    return {
      established = established,
      command = set_model.type,
      provider = set_model.provider,
      model_id = set_model.modelId,
      current_model = connection._current_model_id,
    }
  ]])

  h.eq(result.established, true)
  h.eq(result.command, "set_model")
  h.eq(result.provider, "anthropic")
  h.eq(result.model_id, "claude-sonnet-4")
  h.eq(result.current_model, "claude-sonnet-4")
end

T["RPC Connection"]["start_agent_process()"] = new_set()

T["RPC Connection"]["start_agent_process()"]["does not start the agent when the setup handler fails"] = function()
  local result = child.lua([[
    rpc_conn({ lifecycle = { setup = function() return false end } })

    return { ready = conn:is_ready(), started = job_started }
  ]])

  h.eq(result.ready, false)
  h.eq(result.started, 0)
end

T["RPC Connection"]["process exit"] = new_set()

T["RPC Connection"]["process exit"]["releases pending waits and clears deadlines"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()

    local outcome = {}
    async.sync(function()
      outcome.state = conn:send_command("get_state")
    end)()

    exit_fn({ code = 1, signal = 0 })

    return {
      released = outcome.state == nil,
      deadline_released = vim.tbl_count(conn._deadlines) == 0,
      no_pending = vim.tbl_isempty(conn._pending_callbacks),
      gone = not conn:is_ready(),
    }
  ]])

  h.eq(result.released, true)
  h.eq(result.deadline_released, true)
  h.eq(result.no_pending, true)
  h.eq(result.gone, true)
end

T["RPC Connection"]["process exit"]["clears the connection before the event fires"] = function()
  local result = child.lua([[
    local connection = rpc_conn()

    local seen = {}
    connection:set_event_handler(function(event)
      if event.type ~= "_process_exit" then
        return
      end
      seen.ready = connection:is_ready()
      seen.handle = connection._state.handle ~= nil
      seen.prompt_sent = connection:prompt({ message = "again" }) ~= nil
    end)

    stdin_writes = {}
    exit_fn({ code = 1, signal = 0 })

    seen.writes = #stdin_writes
    return seen
  ]])

  h.eq(result.ready, false)
  h.eq(result.handle, false)
  h.eq(result.prompt_sent, false)
  h.eq(result.writes, 0)
end

T["RPC Connection"]["process exit"]["marks a signalled death with a nil exit code"] = function()
  local result = child.lua([[
    local async = require("codecompanion.utils.async")

    rpc_conn()

    local outcome = {}
    async.sync(function()
      outcome.state = conn:send_command("get_state")
    end)()

    -- Signalled out of existence: code is nil, only the signal carries meaning
    exit_fn({ code = nil, signal = 15 })

    return { released = outcome.state == nil, gone = not conn:is_ready() }
  ]])

  h.eq(result.released, true)
  h.eq(result.gone, true)
end

T["RPC Connection"]["process exit"]["passes the exit code to the adapter's on_exit handler"] = function()
  local result = child.lua([[
    rpc_conn({ lifecycle = { on_exit = function(_, args) exit_args = args end } })

    exit_fn({ code = 3, signal = 0 })

    return { code = exit_args and exit_args.code, gone = not conn:is_ready() }
  ]])

  h.eq(result.code, 3)
  h.eq(result.gone, true)
end

T["RPC Connection"]["handle_message()"] = new_set()

T["RPC Connection"]["handle_message()"]["answers a blocking dialog with a cancellation"] = function()
  local result = child.lua([[
    rpc_conn()
    stdin_writes = {}

    stdout_fn(
      nil,
      '{"type":"extension_ui_request","id":"ui1","method":"select","title":"Pick one","options":["a"]}\n'
    )

    return { count = #stdin_writes, response = vim.json.decode(stdin_writes[1] or "{}") }
  ]])

  h.eq(result.count, 1)
  h.eq(result.response, { type = "extension_ui_response", id = "ui1", cancelled = true })
end

T["RPC Connection"]["handle_message()"]["IGNORES a notification that expects no answer"] = function()
  local result = child.lua([[
    rpc_conn()
    stdin_writes = {}

    stdout_fn(nil, '{"type":"extension_ui_request","id":"ui2","method":"notify","message":"Working"}\n')

    return { count = #stdin_writes }
  ]])

  h.eq(result.count, 0)
end

T["RPC Connection"]["prepare_adapter()"] = new_set()

T["RPC Connection"]["prepare_adapter()"]["reopens the session file when the agent keeps one on disk"] = function()
  local result = child.lua([[
    rpc_conn()

    local session_file = vim.fs.joinpath(vim.fn.tempname(), "session.jsonl")
    vim.fn.mkdir(vim.fs.dirname(session_file), "p")
    vim.fn.writefile({ "{}" }, session_file)
    conn.session_file = session_file

    return { command = conn:prepare_adapter().command, session_file = session_file }
  ]])

  h.eq(result.command, { "pi", "--mode", "rpc", "--session", result.session_file })
end

T["RPC Connection"]["prepare_adapter()"]["DOES NOT reopen a session the agent never wrote"] = function()
  local result = child.lua([[
    rpc_conn()

    -- pi reports its session file before anything is persisted to it
    conn.session_file = vim.fs.joinpath(vim.fn.tempname(), "missing.jsonl")

    return { command = conn:prepare_adapter().command }
  ]])

  h.eq(result.command, { "pi", "--mode", "rpc" })
end

T["RPC Connection"]["disconnect()"] = new_set()

T["RPC Connection"]["disconnect()"]["closes stdin and schedules the kill"] = function()
  local result = child.lua([[
    local connection = rpc_conn()
    connection:disconnect()

    return { stdin_closed = stdin_closed, killed_scheduled = #timers }
  ]])

  h.eq(result.stdin_closed, 1)
  h.eq(result.killed_scheduled, 1)
end

T["RPC Connection"]["disconnect()"]["marks the connection not ready and drops its exit hook"] = function()
  local result = child.lua([[
    local connection = rpc_conn()
    connection:disconnect()

    return {
      ready = connection:is_ready(),
      autocmd_cleared = connection._exit_autocmd == nil,
    }
  ]])

  h.eq(result.ready, false)
  h.eq(result.autocmd_cleared, true)
end

T["RPC Connection"]["disconnect()"]["stops later commands writing to the closing process"] = function()
  local result = child.lua([[
    local connection = rpc_conn()
    connection:disconnect()
    stdin_writes = {}

    return {
      prompt_sent = connection:prompt({ message = "hi" }) ~= nil,
      aborted = connection:abort(),
      steer_sent = connection:steer("go left"),
      ready = connection:is_ready(),
      writes = #stdin_writes,
    }
  ]])

  h.eq(result.prompt_sent, false)
  h.eq(result.aborted, false)
  h.eq(result.steer_sent, false)
  h.eq(result.ready, false)
  h.eq(result.writes, 0)
end

T["RPC Connection"]["disconnect()"]["does not accumulate VimLeavePre hooks across reconnects"] = function()
  local result = child.lua([[
    local connection = rpc_conn()

    local function exit_hooks()
      return #vim.api.nvim_get_autocmds({ group = "codecompanion.rpc.disconnect" })
    end

    local first = exit_hooks()
    connection:disconnect()
    connection:connect()
    connection:disconnect()
    connection:connect()

    return { first = first, after = exit_hooks() }
  ]])

  h.eq(result.first, 1)
  h.eq(result.after, 1)
end

T["RPC Connection"]["process exit"]["IGNORES the exit of a process a reconnect has replaced"] = function()
  local result = child.lua([[
    local connection = rpc_conn()

    -- Capture the first process's exit hook before the reconnect replaces it
    local first_exit = exit_fn

    connection:disconnect()
    connection:connect()
    first_exit({ code = 1, signal = 0 })

    return { ready = connection:is_ready() }
  ]])

  h.eq(result.ready, true)
end

return T
