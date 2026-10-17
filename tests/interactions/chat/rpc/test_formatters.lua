local h = require("tests.helpers")

local new_set = MiniTest.new_set

local T = new_set()
local child = MiniTest.new_child_neovim()

local MAX_TEXT = 100 -- Mirrors the formatter's label limit

T["RPC Formatters"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        MAX_TEXT = 100
        formatter = require("codecompanion.interactions.chat.rpc.formatters")

        ---For a target of repeated two-byte characters, the label is on the
        ---character budget when each character stays intact
        function truncate_target(char, count)
          return formatter.tool_message({
            toolName = "bash",
            args = { command = string.rep(char, count) },
            status = "in_progress",
          })
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC Formatters"]["tool_message()"] = new_set()

T["RPC Formatters"]["tool_message()"]["DOES NOT truncate a target that is INSIDE the limit"] = function()
  local result = child.lua([[
    return formatter.tool_message({
      toolName = "bash",
      args = { command = "ls -la" },
      status = "in_progress",
    })
  ]])

  h.eq(result, "bash: ls -la")
end

T["RPC Formatters"]["tool_message()"]["truncates a target that is OUTSIDE the limit without splitting characters"] = function()
  local result = child.lua([[
    local label = truncate_target("ä", 100)
    return {
      label = label,
      char_length = vim.fn.strchars(label),
      byte_length = #label,
      display_width = vim.fn.strdisplaywidth(label),
      ends_with_ellipsis = label:sub(-3) == "...",
    }
  ]])

  -- The character budget holds 91 target characters behind the "bash: " prefix
  h.eq(result.ends_with_ellipsis, true)
  h.eq(result.char_length, 100)
  h.eq(result.byte_length, 191)
  h.eq(result.display_width, MAX_TEXT)
end

T["RPC Formatters"]["message_text()"] = new_set()

T["RPC Formatters"]["message_text()"]["joins the text blocks and skips everything else"] = function()
  local result = child.lua([[
    return formatter.message_text({
      { type = "text", text = "hello " },
      { type = "toolCall", id = "call_1" },
      { type = "text", text = "there" },
    })
  ]])

  h.eq(result, "hello there")
end

T["RPC Formatters"]["message_text()"]["is empty for a message with no text blocks"] = function()
  local result = child.lua([[
    return {
      no_blocks = formatter.message_text({}),
      tool_only = formatter.message_text({ { type = "toolCall", id = "call_1" } }),
      not_a_message = formatter.message_text(nil),
    }
  ]])

  h.eq(result.no_blocks, "")
  h.eq(result.tool_only, "")
  h.eq(result.not_a_message, "")
end

T["RPC Formatters"]["tool_message()"]["names a search by its pattern, not the directory it runs in"] = function()
  local result = child.lua([[
    return formatter.tool_message({
      toolName = "grep",
      args = { pattern = "TODO", path = "lua/codecompanion" },
      status = "in_progress",
    })
  ]])

  h.eq(result, "grep: TODO")
end

T["RPC Formatters"]["tool_message()"]["appends the partial output of a running tool"] = function()
  local result = child.lua([[
    return formatter.tool_message({
      toolName = "bash",
      args = { command = "npm test" },
      status = "in_progress",
      partialResult = { content = { { type = "text", text = "running 3 tests" } } },
    })
  ]])

  h.eq(result, "bash: npm test - running 3 tests")
end

T["RPC Formatters"]["history_message()"] = new_set()

T["RPC Formatters"]["history_message()"]["shows the call and the output it produced"] = function()
  local result = child.lua([[
    local label, status = formatter.history_message(
      { name = "bash", arguments = { command = "git status" } },
      { toolCallId = "call_1", content = { { type = "text", text = "clean\n" } }, isError = false }
    )
    return { label = label, status = status }
  ]])

  h.eq(result.label, "bash: git status - clean")
  h.eq(result.status, "completed")
end

T["RPC Formatters"]["history_message()"]["marks a call that ended in an error as failed"] = function()
  local result = child.lua([[
    local label, status = formatter.history_message({ name = "edit", arguments = { path = "init.lua" } }, {
      toolCallId = "call_1",
      content = { { type = "text", text = "oldText not found" } },
      isError = true,
    })
    return { label = label, status = status }
  ]])

  h.eq(result.label, "edit: init.lua - oldText not found")
  h.eq(result.status, "failed")
end

T["RPC Formatters"]["history_message()"]["keeps the call when the run ended before a result arrived"] = function()
  local result = child.lua([[
    local label, status = formatter.history_message({ name = "read", arguments = { path = "init.lua" } }, nil)
    return { label = label, status = status }
  ]])

  h.eq(result.label, "read: init.lua")
  h.eq(result.status, "in_progress")
end

return T
