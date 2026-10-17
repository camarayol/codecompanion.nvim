local helpers = require("codecompanion.adapters.rpc.helpers")

local is_windows = vim.fn.has("win32") == 1

---@class CodeCompanion.RPCAdapter.Pi: CodeCompanion.RPCAdapter
return {
  name = "pi",
  formatted_name = "Pi",
  type = "rpc",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    vision = true,
    resume_sessions = true,
    session_flag = "--session",
  },
  commands = {
    default = is_windows and { "pi.cmd", "--mode", "rpc" } or { "pi", "--mode", "rpc" },
  },
  defaults = {
    timeout = 20000, -- 20 seconds
  },
  handlers = {
    lifecycle = {
      ---@param self CodeCompanion.RPCAdapter
      ---@return boolean
      setup = function(self)
        return true
      end,

      ---@param self CodeCompanion.RPCAdapter
      ---@param args { code: number }
      ---@return nil
      on_exit = function(self, args) end,
    },

    request = {
      ---@param self CodeCompanion.RPCAdapter
      ---@param args { messages: table }
      ---@return { message: string, images?: table[] }
      build_messages = function(self, args)
        return helpers.build_messages(self, args)
      end,
    },
  },
}
