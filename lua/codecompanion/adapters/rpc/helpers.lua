local tags = require("codecompanion.interactions.shared.tags")

local M = {}

---Format messages into the single prompt an RPC agent expects
---@param self CodeCompanion.RPCAdapter
---@param messages table
---@return { message: string, images?: table[] }
M.form_messages = function(self, messages)
  local text = {}
  local images = {}

  for _, msg in ipairs(messages) do
    -- The agent keeps its own conversation state, so only unsent user messages are shared
    if msg.role == self.roles.user and msg._meta and not msg._meta.sent then
      if msg._meta.tag == tags.IMAGE and msg.context and msg.context.mimetype then
        table.insert(images, {
          type = "image",
          data = msg.content,
          mimeType = msg.context.mimetype,
        })
      elseif msg.content and msg.content ~= "" then
        if (msg._meta.tag == tags.FILE or msg._meta.tag == tags.BUFFER) and msg.context and msg.context.path then
          table.insert(text, ("Sharing the following file as context: %s"):format(msg.context.path))
        else
          table.insert(text, msg.content)
        end
      end
    end
  end

  return {
    message = table.concat(text, "\n\n"),
    images = #images > 0 and images or nil,
  }
end

return M
