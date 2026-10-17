local tags = require("codecompanion.interactions.shared.tags")

local M = {}

---Format messages into the single prompt an RPC agent expects
---@param self CodeCompanion.RPCAdapter
---@param args { messages: table }
---@return { message: string, images?: table[] }
M.build_messages = function(self, args)
  local messages = args.messages
  local text = {}
  local images = {}

  for _, message in ipairs(messages) do
    -- The agent keeps its own conversation state, so only unsent user messages are shared
    if message.role == self.roles.user and message._meta and not message._meta.sent then
      if message._meta.tag == tags.IMAGE and message.context and message.context.mimetype then
        table.insert(images, {
          type = "image",
          data = message.content,
          mimeType = message.context.mimetype,
        })
      elseif message.content and message.content ~= "" then
        if
          (message._meta.tag == tags.FILE or message._meta.tag == tags.BUFFER)
          and message.context
          and message.context.path
        then
          table.insert(text, ("Sharing the following file as context: %s"):format(message.context.path))
        else
          table.insert(text, message.content)
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
