local h = require("tests.helpers")

local new_set = MiniTest.new_set

local T = new_set()
local child = MiniTest.new_child_neovim()

T["RPC History"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        h.setup_plugin()

        history = require("codecompanion.interactions.chat.rpc.history")

        -- A chat stub with only the surface the renderer touches, so a session
        -- can be restored without a buffer or an agent process
        function fake_chat()
          local chat = {
            cycle = 1,
            builder = { state = {} },
            buffer = {},
            MESSAGE_TYPES = { LLM_MESSAGE = "llm_message", TOOL_MESSAGE = "tool_message" },
          }

          function chat:clear() end
          function chat:ready_for_input() end

          function chat:add_buf_message(data, opts)
            table.insert(self.buffer, {
              role = data.role,
              content = data.content,
              type = opts and opts.type,
              status = opts and opts.status,
            })
          end

          return chat
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC History"]["restore()"] = new_set()

T["RPC History"]["restore()"]["shows why a run failed, even though the message has no content"] = function()
  local result = child.lua([[
    local chat = fake_chat()

    history.restore(chat, {
      { role = "user", content = { { type = "text", text = "Say hello" } } },
      { role = "assistant", content = {}, stopReason = "error", errorMessage = "model_not_supported" },
    })

    return chat.buffer
  ]])

  h.eq(#result, 2)
  h.eq(result[2].role, "llm")
  h.eq(result[2].type, "llm_message")
  h.eq(result[2].content:find("model_not_supported", 1, true) ~= nil, true)
end

T["RPC History"]["restore()"]["renders a tool call with the arguments it ran with and its output"] = function()
  local result = child.lua([[
    local chat = fake_chat()

    history.restore(chat, {
      {
        role = "assistant",
        content = {
          { type = "text", text = "Let me check." },
          { type = "toolCall", id = "call_1", name = "bash", arguments = { command = "git status" } },
        },
      },
      {
        role = "toolResult",
        toolCallId = "call_1",
        toolName = "bash",
        content = { { type = "text", text = "clean" } },
        isError = false,
      },
    })

    return chat.buffer
  ]])

  h.eq(#result, 2)
  h.eq(result[1].content, "Let me check.")
  h.eq(result[2].type, "tool_message")
  h.eq(result[2].content, "bash: git status - clean")
  h.eq(result[2].status, "completed")
end

T["RPC History"]["restore()"]["IGNORES the thinking blocks of a restored message"] = function()
  local result = child.lua([[
    local chat = fake_chat()

    history.restore(chat, {
      {
        role = "assistant",
        content = {
          { type = "thinking", thinking = "The user wants a greeting" },
          { type = "text", text = "Hello" },
        },
      },
    })

    return chat.buffer
  ]])

  h.eq(#result, 1)
  h.eq(result[1].content, "Hello")
end

return T
