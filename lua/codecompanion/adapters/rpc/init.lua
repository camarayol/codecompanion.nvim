local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local shared = require("codecompanion.adapters.shared")

---@class CodeCompanion.RPCAdapter
---@field name string The name of the adapter
---@field type string|"rpc" The type of the adapter
---@field formatted_name string The formatted name of the adapter
---@field roles table The mapping of roles in the config to the agent's defined roles
---@field command table The command to execute
---@field commands { default: table, [string]: table } The list of possible commands for the adapter. Must include a 'default' key
---@field opts? table Additional options for the adapter
---@field opts.resume_sessions? boolean Whether /resume can read the agent's session files from disk
---@field opts.session_flag? string The flag that reopens an existing session file on reconnect
---@field opts.session_stats? boolean Whether the agent answers with token, cost and context statistics
---@field opts.vision? boolean Whether the agent accepts images
---@field defaults? table Additional options for the adapter
---@field env? table Environment variables which can be referenced in the command
---@field env_replaced? table Replacement of environment variables with their actual values
---@field handlers CodeCompanion.RPCAdapter.Handlers Functions which link the output from the agent to CodeCompanion

---@class CodeCompanion.RPCAdapter.Handlers.Lifecycle
---@field setup? fun(self: CodeCompanion.RPCAdapter): boolean
---@field on_exit? fun(self: CodeCompanion.RPCAdapter, args: { code: number }): nil

---@class CodeCompanion.RPCAdapter.Handlers.Request
---@field build_messages? fun(self: CodeCompanion.RPCAdapter, args: { messages: table }): { message: string, images?: table[] }

---@class CodeCompanion.RPCAdapter.Handlers
---@field lifecycle? CodeCompanion.RPCAdapter.Handlers.Lifecycle
---@field request? CodeCompanion.RPCAdapter.Handlers.Request

local Adapter = {}

---Find a handler on the adapter
---@param adapter CodeCompanion.RPCAdapter
---@param name string
---@return function|nil
local function find_handler(adapter, name)
  local handlers = adapter.handlers
  if not handlers then
    return nil
  end

  for _, category in ipairs({ "lifecycle", "request" }) do
    if handlers[category] and handlers[category][name] then
      return handlers[category][name]
    end
  end

  return nil
end

Adapter.get_handler = find_handler

---Call a handler on the adapter
---@param adapter CodeCompanion.RPCAdapter
---@param name string
---@param args? table
---@return any|nil
function Adapter.call_handler(adapter, name, args)
  local handler = find_handler(adapter, name)
  if not handler then
    return nil
  end
  return handler(adapter, args or {})
end

---@return CodeCompanion.RPCAdapter
function Adapter.new(args)
  return setmetatable(args, { __index = Adapter })
end

Adapter.map_roles = shared.map_roles

---Extend an existing adapter
---@param adapter table|string|function
---@param opts? table
---@return CodeCompanion.RPCAdapter
function Adapter.extend(adapter, opts)
  local ok
  local adapter_config
  opts = opts or {}

  if type(adapter) == "string" then
    ok, adapter_config = pcall(require, "codecompanion.adapters.rpc." .. adapter)
    if not ok then
      -- Check rpc adapters first, then fall back to root adapters
      adapter_config = (config.adapters.rpc and config.adapters.rpc[adapter]) or config.adapters[adapter]
      if type(adapter_config) == "function" then
        adapter_config = adapter_config()
      end
    end
  elseif type(adapter) == "function" then
    adapter_config = adapter()
  else
    adapter_config = adapter
  end

  if not adapter_config then
    return log:error("[adapters::rpc::extend] Adapter not found: %s", adapter)
  end

  adapter_config = vim.tbl_deep_extend("force", {}, vim.deepcopy(adapter_config), opts or {})

  return Adapter.new(adapter_config)
end

---Resolve an adapter from deep within the plugin...somewhere
---@param adapter? CodeCompanion.RPCAdapter|string|function
---@param opts? { model?: string }
---@return CodeCompanion.RPCAdapter
function Adapter.resolve(adapter, opts)
  adapter = adapter or config.interactions.chat.adapter
  opts = opts or {}

  local key = type(adapter) == "string" and adapter or nil

  if type(adapter) == "table" then
    -- Handle { name = "pi", model = "..." } style config
    if adapter.name and not adapter.type then
      log:trace("[adapters::rpc::resolve] Table adapter: %s", adapter.name)
      return Adapter.resolve(adapter.name, { model = adapter.model })
    end

    adapter = Adapter.new(adapter)
  elseif type(adapter) == "string" then
    if not config.adapters.rpc or not config.adapters.rpc[adapter] then
      return log:error("[adapters::rpc::resolve] Adapter not found: %s", adapter)
    end
    adapter = Adapter.extend(config.adapters.rpc[adapter])
  elseif type(adapter) == "function" then
    adapter = adapter()
  end

  shared.apply_extend(adapter, { extend = config.adapters.rpc.extend, key = key })

  -- Applied by the connection once the agent has reported the models it offers
  if opts.model then
    adapter.defaults = adapter.defaults or {}
    adapter.defaults.model = opts.model
  end

  if adapter.commands and adapter.commands.default then
    adapter.commands.selected = adapter.commands.default
  end

  return adapter
end

---Check if an adapter has already been resolved
---@param adapter CodeCompanion.RPCAdapter|string|function|nil
---@return boolean
function Adapter.resolved(adapter)
  if adapter and getmetatable(adapter) and getmetatable(adapter).__index == Adapter then
    return true
  end
  return false
end

---Make an adapter safe for serialization
---@param adapter CodeCompanion.RPCAdapter
---@return table
function Adapter.make_safe(adapter)
  return {
    name = adapter.name,
    formatted_name = adapter.formatted_name,
    type = adapter.type,
    command = adapter.command,
    defaults = adapter.defaults,
    opts = adapter.opts,
    handlers = adapter.handlers,
  }
end

---Set the model used by the agent
---@param args { rpc_connection: CodeCompanion.RPC.Connection, adapter: CodeCompanion.RPCAdapter, model: string, provider?: string }
---@return boolean
function Adapter.set_model(args)
  return args.rpc_connection:set_model(args.model, args.provider)
end

return Adapter
