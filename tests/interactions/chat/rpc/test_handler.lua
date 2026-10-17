local h = require("tests.helpers")

local new_set = MiniTest.new_set

local T = new_set()
local child = MiniTest.new_child_neovim()

T["RPC Handler"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        h.setup_plugin()

        -- A chat stub with only the surface the handler touches, so the
        -- request lifecycle can be driven without a real agent process
        function fake_chat(opts)
          opts = opts or {}
          local connected = opts.connect ~= false

          local conn = {
            is_ready = function() return connected end,
            connect = function() return connected end,
            ensure_session = function() return true end,
            set_event_handler = function() end,
            prompt = function() return { success = true, data = {} } end,
            abort = function() aborted = (aborted or 0) + 1 end,
          }

          local chat = {
            adapter = {
              name = "pi",
              formatted_name = "Pi",
              type = "rpc",
              commands = { selected = { "pi", "--mode", "rpc" } },
              handlers = { form_messages = function() return { message = "hi" } end },
            },
            bufnr = 1,
            messages = {},
            status = "",
            rpc_connection = conn,
            MESSAGE_TYPES = { LLM_MESSAGE = "llm_message" },
            buffer_messages = {},
            completed = {},
            update_metadata = function() end,
            set_title = function() end,
          }

          function chat:add_buf_message(data, message_opts)
            table.insert(self.buffer_messages, { content = data.content, type = message_opts and message_opts.type })
            return #self.buffer_messages, #self.buffer_messages
          end

          function chat:update_buf_line(line_number, content)
            local message = self.buffer_messages[line_number]
            if not message then
              return false
            end
            message.content = content
            return true, line_number
          end

          function chat:done(output, _, _, _, done_opts)
            table.insert(self.completed, {
              output = output and table.concat(output, "") or nil,
              error = done_opts and done_opts.error,
            })
          end

          return chat
        end

        events = {}
        fired = require("codecompanion.utils")
        fired.fire = function(name, data)
          table.insert(events, { name = name, status = data and data.status, data = data })
        end

        ---Every FileEdited payload fired so far
        function edited_files()
          local edited = {}
          for _, event in ipairs(events) do
            if event.name == "FileEdited" then
              table.insert(edited, event.data)
            end
          end
          return edited
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC Handler"]["fires RequestFinished when a request is cancelled"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())
    handler:submit({ messages = {} })

    handler.chat.current_request.cancel()

    return { events = events, aborted = aborted or 0 }
  ]])

  h.eq(result.aborted, 1)
  h.eq(
    vim.tbl_map(function(event)
      return { name = event.name, status = event.status }
    end, result.events),
    {
      { name = "RequestStarted" },
      { name = "RequestFinished", status = "cancelled" },
    }
  )
end

T["RPC Handler"]["submit()"] = new_set()

T["RPC Handler"]["submit()"]["shows an error in the chat buffer when the agent cannot start"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat({ connect = false }))
    local chat = handler.chat

    handler:submit({ messages = {} })

    return {
      status = chat.status,
      shown = chat.buffer_messages[1] and chat.buffer_messages[1].content or "",
      error = chat.completed[1] and chat.completed[1].error,
    }
  ]])

  h.eq(result.status, "error")
  h.eq(result.shown:find("Could not connect to Pi", 1, true) ~= nil, true)
  h.eq(result.shown:find("pi --mode rpc", 1, true) ~= nil, true)
  h.eq(result.error ~= nil, true)
end

T["RPC Handler"]["message_end"] = new_set()

T["RPC Handler"]["message_end"]["surfaces the error a provider reported"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())
    local chat = handler.chat

    handler:submit({ messages = {} })
    handler:process_event({
      type = "message_end",
      message = { role = "assistant", content = {}, stopReason = "error", errorMessage = "model_not_supported" },
    })

    return {
      status = chat.status,
      error = chat.completed[1] and chat.completed[1].error,
      shown = chat.buffer_messages[1] and chat.buffer_messages[1].content or "",
      last_event = { name = events[#events].name, status = events[#events].status },
    }
  ]])

  h.eq(result.status, "error")
  h.eq(result.error, "model_not_supported")
  h.eq(result.shown:find("model_not_supported", 1, true) ~= nil, true)
  h.eq(result.last_event, { name = "RequestFinished", status = "error" })
end

T["RPC Handler"]["message_end"]["streams the text of a message the provider never streamed"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())
    local chat = handler.chat

    handler:submit({ messages = {} })
    handler:process_event({ type = "message_start", message = { role = "assistant" } })
    handler:process_event({
      type = "message_end",
      message = { role = "assistant", content = { { type = "text", text = "hello there" } }, stopReason = "stop" },
    })
    handler:process_event({ type = "agent_settled", aborted = false })

    return { output = chat.completed[1] and chat.completed[1].output, chunks = #handler.output }
  ]])

  h.eq(result.chunks, 1)
  h.eq(result.output, "hello there")
end

T["RPC Handler"]["message_end"]["DOES NOT repeat text the deltas already streamed"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())
    local chat = handler.chat

    handler:submit({ messages = {} })
    handler:process_event({ type = "message_start", message = { role = "assistant" } })
    handler:process_event({ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "hello there" } })
    handler:process_event({
      type = "message_end",
      message = { role = "assistant", content = { { type = "text", text = "hello there" } }, stopReason = "stop" },
    })
    handler:process_event({ type = "agent_settled", aborted = false })

    return { output = chat.completed[1] and chat.completed[1].output, chunks = #handler.output }
  ]])

  h.eq(result.chunks, 1)
  h.eq(result.output, "hello there")
end

T["RPC Handler"]["tool events"] = new_set()

T["RPC Handler"]["tool events"]["keeps the command of a call whose end event carries no arguments"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())

    -- pi sends the arguments once, when the call starts
    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_1",
      toolName = "bash",
      args = { command = "echo hello-from-tool" },
    })
    handler:process_event({
      type = "tool_execution_end",
      toolCallId = "call_1",
      toolName = "bash",
      result = { content = { { type = "text", text = "hello-from-tool\n" } } },
      isError = false,
    })

    return {
      line = handler.chat.buffer_messages[1] and handler.chat.buffer_messages[1].content,
      lines = #handler.chat.buffer_messages,
      tracked = next(handler.tool_calls),
    }
  ]])

  h.eq(result.line, "bash: echo hello-from-tool - hello-from-tool")
  h.eq(result.lines, 1)
  h.eq(result.tracked, nil)
end

T["RPC Handler"]["tool events"]["shows the partial output of a tool that is still running"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())

    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_1",
      toolName = "bash",
      args = { command = "npm test" },
    })
    handler:process_event({
      type = "tool_execution_update",
      toolCallId = "call_1",
      toolName = "bash",
      args = { command = "npm test" },
      partialResult = { content = { { type = "text", text = "running 3 tests" } } },
    })

    return { line = handler.chat.buffer_messages[#handler.chat.buffer_messages].content, lines = #handler.chat.buffer_messages }
  ]])

  h.eq(result.line, "bash: npm test - running 3 tests")
  h.eq(result.lines, 1)
end

T["RPC Handler"]["tool events"]["names a search by its pattern rather than its directory"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())

    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_1",
      toolName = "grep",
      args = { pattern = "TODO", path = "lua/codecompanion" },
    })

    return { line = handler.chat.buffer_messages[1].content }
  ]])

  h.eq(result.line, "grep: TODO")
end

T["RPC Handler"]["tool events"]["reports the file an edit tool changed"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())

    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_1",
      toolName = "write",
      args = { path = "lua/codecompanion/rpc/sessions.lua" },
    })
    handler:process_event({
      type = "tool_execution_end",
      toolCallId = "call_1",
      toolName = "write",
      result = { content = { { type = "text", text = "Wrote 100 lines" } } },
      isError = false,
    })

    local edited = edited_files()
    return { count = #edited, path = edited[1] and edited[1].path, tool = edited[1] and edited[1].tool }
  ]])

  h.eq(result.count, 1)
  h.eq(result.path, "lua/codecompanion/rpc/sessions.lua")
  h.eq(result.tool, "pi")
end

T["RPC Handler"]["tool events"]["IGNORES a failed edit and tools that do not change files"] = function()
  local result = child.lua([[
    local handler = require("codecompanion.interactions.chat.rpc.handler").new(fake_chat())

    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_1",
      toolName = "edit",
      args = { path = "lua/codecompanion/rpc/init.lua" },
    })
    handler:process_event({
      type = "tool_execution_end",
      toolCallId = "call_1",
      toolName = "edit",
      isError = true,
    })
    handler:process_event({
      type = "tool_execution_start",
      toolCallId = "call_2",
      toolName = "read",
      args = { path = "lua/codecompanion/rpc/init.lua" },
    })
    handler:process_event({
      type = "tool_execution_end",
      toolCallId = "call_2",
      toolName = "read",
      result = { content = { { type = "text", text = "file contents" } } },
      isError = false,
    })

    return { count = #edited_files() }
  ]])

  h.eq(result.count, 0)
end

return T
