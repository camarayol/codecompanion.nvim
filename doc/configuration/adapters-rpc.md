---
description: "Configure RPC adapters in CodeCompanion to connect with agents that speak newline-delimited JSON over stdin and stdout, such as pi."
---

# Configuring RPC Adapters

An `RPC adapter` drives an agent that reads and writes newline-delimited JSON over stdin and stdout. It's a lighter contract than [ACP](/configuration/adapters-acp): there's no handshake, no session listing and no permission round-trips. CodeCompanion sends commands and reads back responses and events.

The only preset is [pi](https://pi.dev).

## Customising an Adapter

There are two ways to customise a preset adapter, and you'll see both throughout this page:

- **Function** - Use this for full or computed setups. Custom `commands`, `defaults`, or values resolved at call time
- **extend table** - Use this for static overrides like a different command

::: code-group

```lua [Function]
require("codecompanion").setup({
  adapters = {
    rpc = {
      pi = function()
        return require("codecompanion.adapters").extend("pi", {
          commands = {
            default = { "some-other-pi", "--mode", "rpc" },
          },
          defaults = {
            timeout = 20000, -- 20 seconds
          },
          env = { PI_API_KEY = "cmd:op read op://personal/Pi/credential --no-newline" },
        })
      end,
    },
  },
})
```

```lua [Extend Table]
require("codecompanion").setup({
  adapters = {
    rpc = {
      extend = {
        pi = {
          env = { PI_API_KEY = "cmd:op read op://personal/Pi/credential --no-newline" },
        },
      },
    },
  },
})
```

:::

> [!IMPORTANT]
> The `extend` key is the adapter's name in the config, not the resolved adapter name.

## Setting a Default Adapter

You can select an RPC adapter to be the default for all chat interactions:

```lua
require("codecompanion").setup({
  interactions = {
    chat = {
      adapter = "pi",
    },
  },
})
```

## Hiding Preset Adapters

By default, the plugin shows all available adapters, including the presets. If you prefer to only display the adapters defined in your user configuration, you can set the `show_presets` option to `false`:

```lua
require("codecompanion").setup({
  adapters = {
    rpc = {
      opts = {
        show_presets = false,
      },
    },
  },
})
```

## Setup: pi

To use [pi](https://pi.dev) within CodeCompanion:

1. [Install](https://pi.dev/docs/latest/cli) pi
2. Run `pi` in your terminal and authenticate
3. Select the `pi` adapter in your chat buffer

CodeCompanion runs `pi --mode rpc` to start the agent. On Windows it runs `pi.cmd` instead. pi keeps its own session files, so your conversation history is preserved between runs and can be reopened with `/resume`.

## Creating Custom RPC Adapters

Not every RPC-compatible tool will have a built-in adapter. You can define your own in your configuration - the example below uses a hypothetical `myagent` CLI tool. Use the [built-in pi adapter](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/adapters/rpc/pi.lua) as a reference.

````lua
require("codecompanion").setup({
  adapters = {
    rpc = {
      my_agent = function()
        local helpers = require("codecompanion.adapters.rpc.helpers")
        return {
          name = "my_agent",
          formatted_name = "MyAgent",
          type = "rpc",
          roles = {
            llm = "assistant",
            user = "user",
          },
          commands = {
            default = {
              "myagent",
              "--mode",
              "rpc",
            },
          },
          defaults = {
            timeout = 20000, -- 20 seconds
          },
          opts = {
            -- Opt in to /resume when the agent stores sessions in pi's format
            resume_sessions = true,
            -- The flag that reopens the active session file when the process restarts
            session_flag = "--session",
          },
          handlers = {
            setup = function(self)
              return true
            end,
            form_messages = function(self, messages)
              return helpers.form_messages(self, messages)
            end,
            on_exit = function(self, code) end,
          },
        }
      end,
    },
  },
})
````

> [!NOTE]
> `form_messages` returns a `{ message, images? }` table rather than a list of messages. The agent keeps its own conversation state, so CodeCompanion only sends the messages the agent hasn't seen yet.

## Limitations

- **Tool approval**: pi runs its own tools without asking CodeCompanion for permission, so there's no approval step to accept or reject. Tool calls are shown in the chat buffer as they run.
- **Slash commands**: pi offers its own slash commands through `get_commands`, but CodeCompanion doesn't use them yet, so the `\command` trigger only applies to ACP agents.
- **Session resume**: The RPC protocol has no command for listing sessions, so CodeCompanion reads pi's session files from disk and loads the one you pick with `switch_session`. Only the active project's sessions are listed, that is, the folder pi grouped the current working directory under, so sessions from other projects are never shown. The session root comes from the agent's own `sessionFile` (reported by `get_state`), so it follows `--session-dir`, `PI_CODING_AGENT_SESSION_DIR` and `PI_CODING_AGENT_DIR` without extra configuration. This is offered only when the adapter sets `opts.resume_sessions = true`, which the pi preset does. Sessions you have exchanged messages in are listed; pi stores its own display names when set, otherwise the first user message is shown. A restored session rebuilds the tool calls the agent made, along with their arguments and output, and the reason any run ended in an error.
- **Sessions across restarts**: Each process starts a new pi session, because CodeCompanion runs `pi --mode rpc` without naming one. When the process dies mid-conversation, the next submission reopens the session file pi reported, so the agent keeps its context. Switching adapter or changing command starts a new agent session, while the chat buffer keeps showing the old history.
- **Blocking dialogs**: If the agent opens a blocking dialog (a select, confirm, input or editor request), CodeCompanion answers it as cancelled so the agent isn't left waiting. Non-blocking notifications are ignored.
- **System prompts**: The protocol has no way to send a system prompt to the agent, so CodeCompanion doesn't merge any with your messages. pi reads its own `AGENTS.md`, and `--append-system-prompt` on the command is the way to add instructions of your own.

## See Also

- [pi RPC documentation](https://pi.dev/docs/latest/rpc) - The protocol CodeCompanion implements
- [Choosing an Adapter](/guides/choosing-an-adapter) - How agent adapters compare to HTTP ones
- [Using Agents and Tools](/usage/chat-buffer/agents-tools) - How to interact with agents in chat
