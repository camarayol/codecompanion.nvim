local config = require("codecompanion.config")

local M = {}

---Determine the adapter type
---@param adapter string|table|nil
---@return string
local function adapter_type(adapter)
  -- If no adapter provided, use the default from config
  if adapter == nil then
    adapter = config.interactions.chat.adapter
  end

  if type(adapter) == "table" and adapter.type then
    return adapter.type
  end

  -- Check by name (for tables like { name = "claude_code", model = "opus" })
  local name = type(adapter) == "string" and adapter or (type(adapter) == "table" and adapter.name)
  if name then
    if config.adapters.acp and config.adapters.acp[name] then
      return "acp"
    end
    if config.adapters.rpc and config.adapters.rpc[name] then
      return "rpc"
    end
    if config.adapters.http and config.adapters.http[name] then
      return "http"
    end
  end

  -- The fallback
  return "http"
end

---Factory method to resolve adapters
---@param adapter string|table
---@param opts? table
---@return CodeCompanion.ACPAdapter|CodeCompanion.HTTPAdapter|CodeCompanion.RPCAdapter
function M.resolve(adapter, opts)
  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").resolve(adapter, opts)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").resolve(adapter, opts)
  end
  return require("codecompanion.adapters.http").resolve(adapter, opts)
end

---Factory method to check if the adapter has been resolved
---@param adapter string|table
---@return boolean
function M.resolved(adapter)
  if not adapter then
    return false
  end

  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").resolved(adapter)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").resolved(adapter)
  end
  return require("codecompanion.adapters.http").resolved(adapter)
end

---Factory method to extend the adapter
---@param adapter string|table
---@param opts? table
---@return CodeCompanion.ACPAdapter|CodeCompanion.HTTPAdapter|CodeCompanion.RPCAdapter
function M.extend(adapter, opts)
  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").extend(adapter, opts)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").extend(adapter, opts)
  end
  return require("codecompanion.adapters.http").extend(adapter, opts)
end

---Factory method to make adapters safe for serialization
---@param adapter string|table
---@return table
function M.make_safe(adapter)
  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").make_safe(adapter)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").make_safe(adapter)
  end
  return require("codecompanion.adapters.http").make_safe(adapter)
end

---Backwards compatibility: expose HTTP methods directly at root level
---@param args { adapter: CodeCompanion.HTTPAdapter|CodeCompanion.ACPAdapter|CodeCompanion.RPCAdapter, acp_connection?: CodeCompanion.ACP.Connection, rpc_connection?: CodeCompanion.RPC.Connection, model?: string }
---@return CodeCompanion.HTTPAdapter
function M.set_model(args)
  if adapter_type(args.adapter) == "acp" then
    return require("codecompanion.adapters.acp").set_model(args)
  end
  if adapter_type(args.adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").set_model(args)
  end
  return require("codecompanion.adapters.http").set_model(args)
end

---Get a handler function from an adapter with backwards compatibility
---@param adapter CodeCompanion.HTTPAdapter|CodeCompanion.ACPAdapter|CodeCompanion.RPCAdapter
---@param handler_name string
---@return function|nil
function M.get_handler(adapter, handler_name)
  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").get_handler(adapter, handler_name)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").get_handler(adapter, handler_name)
  end
  return require("codecompanion.adapters.http").get_handler(adapter, handler_name)
end

---Call a handler on an adapter with backwards compatibility
---@param adapter CodeCompanion.HTTPAdapter|CodeCompanion.ACPAdapter|CodeCompanion.RPCAdapter
---@param handler_name string
---@param args? table
---@return any|nil
function M.call_handler(adapter, handler_name, args)
  if adapter_type(adapter) == "acp" then
    return require("codecompanion.adapters.acp").call_handler(adapter, handler_name, args)
  end
  if adapter_type(adapter) == "rpc" then
    return require("codecompanion.adapters.rpc").call_handler(adapter, handler_name, args)
  end
  return require("codecompanion.adapters.http").call_handler(adapter, handler_name, args)
end

return M
