local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local M = {}

local MAX_SESSIONS = 50
local TITLE_LENGTH = 80
-- A title is in the first few entries, so the scan needn't read every line of every file
local MAX_SCAN_LINES = 200

local is_windows = vim.fn.has("win32") == 1

---Compare two paths the way the filesystem does
---@param left string
---@param right string
---@return boolean
local function same_path(left, right)
  left = vim.fs.normalize(left)
  right = vim.fs.normalize(right)
  if is_windows then
    left = left:lower()
    right = right:lower()
  end
  return left == right
end

---Whether this adapter persists pi-compatible session files that /resume can list
---@param adapter? CodeCompanion.RPCAdapter
---@return boolean
function M.enabled(adapter)
  return adapter ~= nil and adapter.opts ~= nil and adapter.opts.resume_sessions == true
end

---Build a short, single-line title from raw message text
---@param text? string
---@return string|nil
local function flatten(text)
  if type(text) ~= "string" then
    return nil
  end

  text = vim.trim((text:gsub("\r?\n", " "):gsub("%s+", " ")))
  if text == "" then
    return nil
  end

  return utils.truncate_width(text, TITLE_LENGTH)
end

---Pull the first piece of text out of an agent message's content
---@param content table|string|nil
---@return string|nil
local function message_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end

  for _, block in ipairs(content) do
    if block.type == "text" and type(block.text) == "string" then
      return block.text
    end
  end

  return nil
end

---Extract a session's display title and ids from its file
---@param path string
---@return table|nil metadata { path, sessionId, updatedAt, cwd, title }
local function read_metadata(path)
  local ok, file = pcall(io.open, path, "r")
  if not ok or not file then
    return nil
  end

  local metadata = { path = path }
  local name, first_user, summary
  local header_found = false
  local scanned = 0

  for line in file:lines() do
    scanned = scanned + 1
    local decoded, entry = pcall(vim.json.decode, line)
    if decoded and type(entry) == "table" then
      if entry.type == "session" then
        metadata.sessionId = entry.id
        metadata.cwd = entry.cwd
        header_found = true
      elseif entry.type == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
        name = entry.name
      elseif entry.type == "message" and type(entry.message) == "table" then
        if entry.message.role == "user" then
          local text = message_text(entry.message.content)
          if not first_user and type(text) == "string" then
            first_user = text
          end
        end
      elseif entry.type == "compaction" and type(entry.summary) == "string" then
        summary = entry.summary
      end
    end

    -- A session name wins over any message text, so nothing later can change the title
    if name or scanned >= MAX_SCAN_LINES then
      break
    end
  end
  file:close()

  if not header_found then
    return nil
  end

  metadata.title = name or flatten(first_user) or flatten(summary)
  if not metadata.title then
    -- Nothing to display, e.g. a fresh session file with a header only
    return nil
  end

  return metadata
end

---The folder pi groups its session files under, derived from the active session file
---@param session_file? string The agent's active session file, if connected
---@return string|nil
function M.root(session_file)
  if not session_file or session_file == "" then
    return nil
  end

  -- pi groups sessions into a folder per working directory, so the file's grandparent is pi's root
  return vim.fs.dirname(vim.fs.dirname(session_file))
end

local function by_mtime(a, b)
  return a.mtime > b.mtime
end

---List the active project's sessions from disk, newest first
---@param opts? { session_file?: string, root?: string }
---@return table[] sessions { path, sessionId, updatedAt, cwd, title }
function M.list(opts)
  opts = opts or {}

  -- Without the agent's session file we can't tell which project is active
  if not opts.session_file or opts.session_file == "" then
    return {}
  end

  local root = opts.root or M.root(opts.session_file)
  if not root or not vim.uv.fs_stat(root) then
    return {}
  end

  local project_dir = vim.fs.dirname(opts.session_file)

  local files = {}
  for name, _ in vim.fs.dir(root, { depth = 2, type = "file" }) do
    if name:match("%.jsonl$") then
      local path = vim.fs.joinpath(root, name)
      local stat = vim.uv.fs_stat(path)
      -- Other projects and the live session are not things to resume
      if stat and same_path(vim.fs.dirname(path), project_dir) and not same_path(path, opts.session_file) then
        table.insert(files, { path = path, mtime = stat.mtime.sec })
      end
    end
  end

  table.sort(files, by_mtime)

  local sessions = {}
  for _, file in ipairs(files) do
    if #sessions >= MAX_SESSIONS then
      break
    end
    local metadata = read_metadata(file.path)
    if metadata then
      metadata.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", file.mtime)
      table.insert(sessions, metadata)
    end
  end

  log:trace("[rpc] Found %d sessions in `%s`", #sessions, project_dir)
  return sessions
end

return M
