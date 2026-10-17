local h = require("tests.helpers")

local new_set = MiniTest.new_set

local T = new_set()
local child = MiniTest.new_child_neovim()

T["RPC Adapter Helpers"] = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        h.setup_plugin()

        helpers = require("codecompanion.adapters.rpc.helpers")
        tags = require("codecompanion.interactions.shared.tags")
        adapter = { roles = { user = "user", llm = "assistant" } }

        function form(messages)
          return helpers.form_messages(adapter, messages)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["RPC Adapter Helpers"]["form_messages()"] = new_set()

T["RPC Adapter Helpers"]["form_messages()"]["joins the chunks the agent has not seen"] = function()
  local result = child.lua([[
    return form({
      { role = "user", content = "Look at this", _meta = { tag = tags.RULES } },
      { role = "user", content = "And this", _meta = {} },
    })
  ]])

  h.eq(result.message, "Look at this\n\nAnd this")
end

T["RPC Adapter Helpers"]["form_messages()"]["IGNORES messages the agent has already been sent"] = function()
  local result = child.lua([[
    return form({
      { role = "user", content = "Sent earlier", _meta = { sent = true } },
      { role = "assistant", content = "The agent's own reply", _meta = {} },
      { role = "user", content = "New question", _meta = {} },
    })
  ]])

  h.eq(result.message, "New question")
end

T["RPC Adapter Helpers"]["form_messages()"]["collects images apart from the message text"] = function()
  local result = child.lua([[
    return form({
      { role = "user", content = "iVBORw0KGgo=", _meta = { tag = tags.IMAGE }, context = { mimetype = "image/png" } },
      { role = "user", content = "What is in this image?", _meta = {} },
    })
  ]])

  h.eq(result.message, "What is in this image?")
  h.eq(result.images, { { type = "image", data = "iVBORw0KGgo=", mimeType = "image/png" } })
end

T["RPC Adapter Helpers"]["form_messages()"]["names the file a context item came from"] = function()
  local result = child.lua([[
    return form({
      { role = "user", content = "local x = 1", _meta = { tag = tags.BUFFER }, context = { path = "/tmp/init.lua" } },
    })
  ]])

  -- The agent reads the file itself, so only its path is shared
  h.eq(result.message, "Sharing the following file as context: /tmp/init.lua")
end

return T
