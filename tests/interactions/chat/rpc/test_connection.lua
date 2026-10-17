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
        stdout_fn = nil
        exit_fn = nil

        function rpc_conn()
          local Connection = require("codecompanion.rpc")
          local adapter = vim.deepcopy(require("codecompanion.config").adapters.rpc.test_rpc)

          timers = {}
          stdin_writes = {}
          stdin_closed = 0

          conn = Connection.new({
            adapter = adapter,
            opts = {
              job = function(command, spawn_opts, on_exit)
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
