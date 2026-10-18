local markdown = require("codecompanion.utils.markdown")
local utils = require("codecompanion.utils")

local M = {}

local MAX_TEXT = 100

-- pi's own tools each name their subject differently, so a search reads best by its pattern
local TARGET_ARG = {
  bash = "command",
  edit = "path",
  find = "pattern",
  grep = "pattern",
  ls = "path",
  read = "path",
  write = "path",
}

local TARGET_KEYS = { "path", "file_path", "filePath", "command", "cmd", "pattern", "query", "url", "name" }

---Collapse text to a single line and truncate to a display budget
---@param text string|nil
---@param budget? number Display cells available, MAX_TEXT by default
---@return string
local function one_line(text, budget)
  budget = budget or MAX_TEXT

  if not text or text == "" then
    return ""
  end

  text = vim.trim((text:gsub("\r?\n", " "):gsub("%s+", " ")))

  return utils.truncate_width(text, budget)
end

---Join the text blocks of an agent message
---@param content table|string|nil
---@return string
function M.message_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end

  local text = {}
  for _, block in ipairs(content) do
    if block.type == "text" and type(block.text) == "string" then
      table.insert(text, block.text)
    end
  end

  return table.concat(text)
end

---The argument that best names what a tool is operating on
---@param tool_name string
---@param args table|nil
---@return string|nil
local function target_from_args(tool_name, args)
  if type(args) ~= "table" then
    return nil
  end

  local preferred = TARGET_ARG[tool_name]
  if preferred and type(args[preferred]) == "string" and args[preferred] ~= "" then
    return args[preferred]
  end

  for _, key in ipairs(TARGET_KEYS) do
    if type(args[key]) == "string" and args[key] ~= "" then
      return args[key]
    end
  end
end

---Pull a short summary out of a tool result or the latest partial one
---@param result table|nil
---@return string|nil
local function result_summary(result)
  if type(result) ~= "table" then
    return nil
  end

  for _, block in ipairs(result.content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      local text = one_line(block.text)
      if text ~= "" then
        return text
      end
    end
  end
end

---Build the single-line display string for an RPC tool execution
---@param event table
---@return string
function M.tool_message(event)
  local name = event.toolName or "tool"
  local target = target_from_args(name, event.args)

  -- The "name: " prefix shares the line, so it shares the budget
  local target_budget = MAX_TEXT - vim.fn.strdisplaywidth(name) - 2
  local label = target and ("%s: %s"):format(name, one_line(target, target_budget)) or name

  -- A running tool reports progress through `partialResult`
  local summary = result_summary(event.result or event.partialResult)
  if summary then
    label = label .. " - " .. summary
  end

  return label
end

---Render an agent error the same way live and when a session is restored
---@param error string
---@return string
function M.error_message(error)
  return "\n" .. markdown.form_codeblock(error, { ft = "txt" })
end

---Build the same label for a tool call read back from the agent's history
---@param call { name?: string, arguments?: table } A tool call block from an assistant message
---@param result? table The matching tool result message
---@return string label, string status
function M.history_message(call, result)
  local status = "in_progress"
  if result then
    status = result.isError and "failed" or "completed"
  end

  local label = M.tool_message({
    toolName = call.name,
    args = call.arguments,
    result = result and { content = result.content },
  })

  return label, status
end

return M
