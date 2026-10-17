local config = require("codecompanion.config")
local formatter = require("codecompanion.interactions.chat.rpc.formatters")

local M = {}

---Pull the first piece of text out of an agent message's content
---@param content table|string|nil
---@return string
local function extract_text(content)
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

---Index the tool results by the call they belong to, so each call can show its output
---@param messages table The agent's messages from get_messages
---@return table<string, table>
local function tool_results(messages)
  local results = {}
  for _, message in ipairs(messages) do
    if message.role == "toolResult" and message.toolCallId then
      results[message.toolCallId] = message
    end
  end

  return results
end

---Render the agent's messages into the chat buffer
---@param chat CodeCompanion.Chat
---@param messages table The agent's messages from get_messages
---@return nil
function M.restore(chat, messages)
  chat:clear()

  local results = tool_results(messages)

  local user_chunks = {}
  local llm_chunks = {}

  local function flush_user()
    if #user_chunks > 0 then
      local text = table.concat(user_chunks)
      chat:add_buf_message({ role = config.constants.USER_ROLE, content = text })
      user_chunks = {}
    end
  end

  local function flush_llm()
    if #llm_chunks > 0 then
      local text = table.concat(llm_chunks)
      chat:add_buf_message(
        { role = config.constants.LLM_ROLE, content = text },
        { type = chat.MESSAGE_TYPES.LLM_MESSAGE }
      )
      llm_chunks = {}
    end
  end

  ---A failed run has no content, so show the reason it failed
  ---@param error string
  local function add_error(error)
    flush_llm()

    chat:add_buf_message({ role = config.constants.LLM_ROLE, content = formatter.error_message(error) }, {
      type = chat.MESSAGE_TYPES.LLM_MESSAGE,
    })
  end

  ---Each tool call gets its own block, as it does when the agent runs it live
  ---@param block table
  local function add_tool_call(block)
    flush_llm()

    local content, status = formatter.history_message(block, results[block.id])
    chat:add_buf_message({ role = config.constants.LLM_ROLE, content = content }, {
      status = status,
      virt_text_pos = "inline",
      tools = { call_id = block.id },
      type = chat.MESSAGE_TYPES.TOOL_MESSAGE,
    })
  end

  for _, message in ipairs(messages) do
    if message.role == "user" then
      flush_llm()
      local text = extract_text(message.content)
      if text ~= "" then
        table.insert(user_chunks, text)
      end
    elseif message.role == "assistant" then
      flush_user()

      if message.stopReason == "error" then
        add_error(message.errorMessage or "The agent reported an error")
      elseif type(message.content) == "table" then
        for _, block in ipairs(message.content) do
          if block.type == "toolCall" and block.name then
            add_tool_call(block)
          elseif block.type == "text" and type(block.text) == "string" and block.text ~= "" then
            table.insert(llm_chunks, block.text)
          end
        end
      else
        local text = extract_text(message.content)
        if text ~= "" then
          table.insert(llm_chunks, text)
        end
      end
    end
  end
  flush_user()
  flush_llm()

  -- ready_for_input skips the prompt area when the last message was from the
  -- user, which would leave the parser range sitting over the restored history
  if chat._last_role == config.constants.USER_ROLE then
    chat.cycle = chat.cycle + 1
    chat:add_buf_message({ role = config.constants.USER_ROLE, content = "" })
    chat.header_line = (chat.builder.state.current_header_line or 0) + 1
  end

  chat:ready_for_input()
end

return M
