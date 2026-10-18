local config = require("codecompanion.config")
local sessions = require("codecompanion.interactions.chat.sessions")
local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.Resume: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Is the slash command enabled?
---@param chat CodeCompanion.Chat
---@return boolean,string
function SlashCommand.enabled(chat)
  -- Only agents that persist pi-compatible session files can list and resume
  if chat.adapter and chat.adapter.type == "rpc" then
    if require("codecompanion.adapters.rpc.sessions").enabled(chat.adapter) then
      return true, ""
    end
    return false, "This agent does not support listing sessions"
  end

  -- HTTP chats resume from the sessions we persist ourselves
  if not chat.acp_connection then
    return true, ""
  end

  if not chat.acp_connection:can_list_sessions() then
    return false, "This agent does not support listing sessions"
  end

  if not chat.acp_connection:can_load_session() then
    return false, "This agent does not support loading sessions"
  end

  return true, ""
end

---Format a session for display in the picker
---@param session table SessionInfo
---@return string
local function format_session(session)
  local parts = {}

  if session.updatedAt then
    local ts = utils.timestamp_from_iso(session.updatedAt)
    if ts then
      table.insert(parts, "(" .. utils.make_relative(ts) .. ")")
    end
  end

  if session.title then
    table.insert(parts, session.title)
  else
    table.insert(parts, session.sessionId)
  end

  return table.concat(parts, " ")
end

---@param chat CodeCompanion.Chat
---@return boolean
local function has_user_messages(chat)
  return vim.iter(chat.messages):any(function(message)
    return message.role == config.constants.USER_ROLE and message.content ~= ""
  end)
end

---Load the selected session into the agent and render its history
---@param self CodeCompanion.SlashCommand.Resume
---@param selected table A session from adapters.rpc.sessions.list
---@return nil
local function restore_rpc_session(self, selected)
  local Chat = self.Chat
  local async = require("codecompanion.utils.async")

  -- The agent may not be running yet, so connect first and continue here
  require("codecompanion.interactions.chat.helpers").create_rpc_connection(Chat, function()
    local conn = Chat.rpc_connection
    if not conn or not conn:is_ready() then
      return utils.notify("Could not connect to the agent", vim.log.levels.ERROR)
    end

    async.sync(function()
      if not conn:load_session(selected.path) then
        return utils.notify("Failed to load session", vim.log.levels.ERROR)
      end

      -- The agent holds the restored context; only the view is rebuilt here
      local history = conn:get_messages()
      if history then
        require("codecompanion.interactions.chat.rpc.history").restore(Chat, history)
      end

      if selected.title then
        Chat:set_title(selected.title)
      end

      utils.fire("RPCChatRestored", {
        bufnr = Chat.bufnr,
        id = Chat.id,
        session_file = conn.session_file,
        title = Chat.title,
      })

      utils.notify("Resumed session: " .. (selected.title or selected.sessionId), vim.log.levels.INFO)
    end)()
  end)
end

---Offer the RPC agent's sessions, persisted as JSONL files on disk
---@param self CodeCompanion.SlashCommand.Resume
---@return nil
local function select_rpc_session(self)
  local Chat = self.Chat

  -- Connect first, as the agent's session file locates pi's root and the active project
  require("codecompanion.interactions.chat.helpers").create_rpc_connection(Chat, function()
    local rpc_sessions = require("codecompanion.adapters.rpc.sessions")
    local conn = Chat.rpc_connection

    local history = rpc_sessions.list({
      session_file = conn and conn.session_file or nil,
    })

    if #history == 0 then
      return utils.notify("No previous sessions found", vim.log.levels.INFO)
    end

    local choices = {}
    local session_map = {}
    for i, session in ipairs(history) do
      table.insert(choices, format_session(session))
      session_map[i] = session
    end

    vim.ui.select(choices, {
      prompt = "Resume Session",
      kind = "codecompanion.nvim",
    }, function(_, idx)
      if not idx then
        return
      end

      return restore_rpc_session(self, session_map[idx])
    end)
  end)
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  local Chat = self.Chat

  if Chat.current_request then
    return utils.notify("Cannot resume a session while a request is running", vim.log.levels.WARN)
  end

  if Chat.adapter.type == "rpc" then
    if Chat.submitted then
      return utils.notify("The /resume command must be called before submitting any messages", vim.log.levels.WARN)
    end

    return select_rpc_session(self)
  end

  if not Chat.acp_connection then
    return sessions.select({
      on_restored = function()
        if not has_user_messages(Chat) then
          Chat:close()
        end
      end,
    })
  end

  if Chat.submitted then
    return utils.notify("The /resume command must be called before submitting any messages", vim.log.levels.WARN)
  end

  local sessions = Chat.acp_connection:session_list({
    max_sessions = (self.config.opts and self.config.opts.max_sessions) or 500,
  })

  if #sessions == 0 then
    return utils.notify("No previous sessions found", vim.log.levels.INFO)
  end

  local choices = {}
  local session_map = {}
  for i, session in ipairs(sessions) do
    table.insert(choices, format_session(session))
    session_map[i] = session
  end

  vim.ui.select(choices, {
    prompt = "Resume Session",
    kind = "codecompanion.nvim",
  }, function(_, idx)
    if not idx then
      return
    end

    local selected = session_map[idx]

    -- Collect all session updates during the synchronous load
    local updates = {}
    local ok = Chat.acp_connection:load_session(selected.sessionId, {
      on_session_update = function(update)
        table.insert(updates, update)
      end,
    })

    if ok then
      local acp_commands = require("codecompanion.interactions.chat.acp.commands")
      acp_commands.link_buffer_to_session(Chat.bufnr, Chat.acp_connection.session_id)

      require("codecompanion.interactions.chat.acp.render").restore_session(Chat, updates)

      if selected.title then
        Chat:set_title(selected.title)
      end

      utils.fire("ACPChatRestored", {
        bufnr = Chat.bufnr,
        id = Chat.id,
        session_id = Chat.acp_connection.session_id,
        title = Chat.title,
      })

      utils.notify("Resumed session: " .. (selected.title or selected.sessionId), vim.log.levels.INFO)
    else
      utils.notify("Failed to load session", vim.log.levels.ERROR)
    end
  end)
end

return SlashCommand
