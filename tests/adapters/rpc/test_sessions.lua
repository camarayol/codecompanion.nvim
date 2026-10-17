local h = require("tests.helpers")

local new_set = MiniTest.new_set

local T = new_set()
local child = MiniTest.new_child_neovim()

local FIXTURE_ROOT = "/tmp/codecompanion_rpc_sessions_test"

T["RPC Sessions"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        ROOT = "]] .. FIXTURE_ROOT .. [["
        vim.fn.delete(ROOT, "rf")

        ---Write a session file. Each entry is one JSONL line, matching pi's
        ---layout: a header first, then message and session_info entries
        function write_session(file, entries)
          local path = vim.fs.joinpath(ROOT, file)
          vim.fn.mkdir(vim.fs.dirname(path), "p")
          local handle = io.open(path, "w")
          handle:write(table.concat(entries, "\n") .. "\n")
          handle:close()
          return path
        end

        function session_entries(uuid, cwd, name, message)
          local header = vim.json.encode({ type = "session", version = 3, id = uuid, timestamp = "2025-01-01T10:00:00.000Z", cwd = cwd })
          local user = vim.json.encode({ type = "message", id = "e1", parentId = nil, timestamp = "2025-01-01T10:00:01.000Z", message = { role = "user", content = message } })
          local assistant = vim.json.encode({ type = "message", id = "e2", parentId = "e1", timestamp = "2025-01-01T10:00:02.000Z", message = { role = "assistant", content = { { type = "text", text = "On it." } } } })
          local lines = { header, user, assistant }
          if name then
            table.insert(lines, vim.json.encode({ type = "session_info", id = "s1", parentId = "e2", timestamp = "2025-01-01T10:00:03.000Z", name = name }))
          end
          return lines
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC Sessions"]["list()"] = new_set()

T["RPC Sessions"]["list()"]["lists only the active project's sessions, skipping the live and empty ones"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")

    write_session("projA/new_named.jsonl", session_entries("uuid-a", "/projA", "Named session", "Fix the tests"))
    write_session("projA/mid_unnamed.jsonl", session_entries("uuid-c", "/projA", nil, "Another chat"))
    write_session("projA/live.jsonl", session_entries("uuid-d", "/projA", nil, "Live chat"))
    write_session("projA/empty.jsonl", session_entries("uuid-e", "/projA", nil, ""))
    write_session("projB/older.jsonl", session_entries("uuid-b", "/projB", nil, "Older chat"))

    local old = os.time() - 86400
    vim.uv.fs_utime(ROOT .. "/projA/new_named.jsonl", old + 10, old + 10)
    vim.uv.fs_utime(ROOT .. "/projA/mid_unnamed.jsonl", old + 5, old + 5)
    vim.uv.fs_utime(ROOT .. "/projA/live.jsonl", old + 20, old + 20)
    vim.uv.fs_utime(ROOT .. "/projB/older.jsonl", old, old)

    local history = sessions.list({ session_file = ROOT .. "/projA/live.jsonl" })
    return vim.tbl_map(function(session) return session.title end, history)
  ]])

  h.eq(result, { "Named session", "Another chat" })
end

T["RPC Sessions"]["list()"]["lists nothing when the active project has no other sessions"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")

    write_session("projA/live.jsonl", session_entries("uuid-a", "/projA", nil, "Live chat"))
    write_session("projB/older.jsonl", session_entries("uuid-b", "/projB", nil, "Older chat"))

    return #sessions.list({ session_file = ROOT .. "/projA/live.jsonl" })
  ]])

  h.eq(result, 0)
end

T["RPC Sessions"]["list()"]["prefers an explicit session name over the first user message"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")

    local header = vim.json.encode({ type = "session", version = 3, id = "uuid-a", timestamp = "2025-01-01T10:00:00.000Z", cwd = "/projA" })
    local user = vim.json.encode({ type = "message", id = "e1", parentId = nil, timestamp = "2025-01-01T10:00:01.000Z", message = { role = "user", content = "First user message" } })
    local named = vim.json.encode({ type = "session_info", id = "s1", parentId = nil, timestamp = "2025-01-01T10:00:02.000Z", name = "User's own name" })

    write_session("projA/named.jsonl", { header, user, named })
    -- The live session is filtered out, so it doesn't need to exist
    return { title = sessions.list({ session_file = ROOT .. "/projA/live.jsonl" })[1].title }
  ]])

  h.eq(result.title, "User's own name")
end

T["RPC Sessions"]["list()"]["uses a compaction summary as the title when nothing else survives"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")

    local header = vim.json.encode({ type = "session", version = 3, id = "uuid-a", timestamp = "2025-01-01T10:00:00.000Z", cwd = "/projA" })
    local compaction = vim.json.encode({ type = "compaction", id = "c1", parentId = nil, timestamp = "2025-01-01T10:00:02.000Z", summary = "Earlier work on\nmultiple lines" })

    write_session("projA/compacted.jsonl", { header, compaction })
    -- The live session is filtered out, so it doesn't need to exist
    return { title = sessions.list({ session_file = ROOT .. "/projA/live.jsonl" })[1].title }
  ]])

  h.eq(result.title, "Earlier work on multiple lines")
end

T["RPC Sessions"]["list()"]["returns an empty list when pi has no sessions folder"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")
    return sessions.list({
      root = "/tmp/codecompanion_rpc_sessions_missing",
      session_file = "/tmp/codecompanion_rpc_sessions_missing/projA/live.jsonl",
    })
  ]])

  h.eq(vim.tbl_isempty(result), true)
end

T["RPC Sessions"]["enabled()"] = new_set()

T["RPC Sessions"]["enabled()"]["IS true for pi and false for an adapter without the capability"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")
    return {
      pi = sessions.enabled(require("codecompanion.adapters.rpc.pi")),
      custom = sessions.enabled({ name = "my_agent", opts = { vision = true } }),
    }
  ]])

  h.eq(result.pi, true)
  h.eq(result.custom, false)
end

T["RPC Sessions"]["root()"] = new_set()

T["RPC Sessions"]["root()"]["derives the grouping root from the active session file"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")
    local path = vim.fs.joinpath(ROOT, "projA", "abc.jsonl")
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    return sessions.root(path)
  ]])

  h.eq(result, FIXTURE_ROOT)
end

T["RPC Sessions"]["root()"]["is nil without an active session file"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")
    return {
      missing = sessions.root(nil) == nil,
      from_file = sessions.root(vim.fs.joinpath(ROOT, "projA", "abc.jsonl")),
    }
  ]])

  -- No session file means the active project is unknown, so there is nothing to list
  h.eq(result.missing, true)
  h.eq(result.from_file, FIXTURE_ROOT)
end

T["RPC Sessions"]["list()"]["trims a long title to the display budget, not the byte count"] = function()
  local result = child.lua([[
    local sessions = require("codecompanion.adapters.rpc.sessions")

    -- 60 CJK characters: 120 display cells and 180 bytes
    write_session("projA/cjk.jsonl", session_entries("uuid-a", "/projA", nil, string.rep("检", 60)))

    local title = sessions.list({ session_file = ROOT .. "/projA/live.jsonl" })[1].title
    return { width = vim.fn.strdisplaywidth(title), tail = title:sub(-3) }
  ]])

  h.eq(result.tail, "...")
  h.eq(result.width > 70, true)
  h.eq(result.width <= 80, true)
end

return T
