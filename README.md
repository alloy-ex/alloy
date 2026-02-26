# Alloy

[![Hex.pm](https://img.shields.io/hexpm/v/alloy.svg)](https://hex.pm/packages/alloy)
[![CI](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml/badge.svg)](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alloy)
[![License](https://img.shields.io/hexpm/l/alloy.svg)](LICENSE)

**Model-agnostic agent harness for Elixir.**

Alloy gives you the agent loop: send messages to any LLM, execute tool calls, loop until done. Swap providers with one line. Run agents as supervised GenServers. Build multi-agent teams with fault isolation. Zero framework lock-in.

```elixir
{:ok, result} = Alloy.run("Read mix.exs and tell me the version",
  provider: {Alloy.Provider.OpenAI, api_key: System.get_env("OPENAI_API_KEY"), model: "gpt-5.2"},
  tools: [Alloy.Tool.Core.Read]
)

result.text #=> "The version is 0.1.0"
```

## Why Alloy?

Most agent frameworks target Python and single-script usage. Alloy targets what happens after — when you need agents running **in production** with supervision, fault isolation, concurrency, and multi-agent orchestration.

- **8 providers** — Anthropic, OpenAI, Gemini, Ollama, OpenRouter, xAI, DeepSeek, Mistral
- **5 built-in tools** — read, write, edit, bash, scratchpad
- **GenServer agents** — supervised, stateful, message-passing
- **Multi-agent teams** — delegate, broadcast, handoff, fault isolation
- **Streaming** — token-by-token from any provider
- **Middleware** — telemetry, logging, custom hooks, tool blocking
- **Context compaction** — automatic summarization when approaching token limits
- **OTP-native** — supervision trees, hot code reloading, real parallel tool execution

## Installation

Add `alloy` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:alloy, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Simple completion

```elixir
{:ok, result} = Alloy.run("What is 2+2?",
  provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-sonnet-4-6"}
)

result.text #=> "4"
```

### Agent with tools

```elixir
{:ok, result} = Alloy.run("Read mix.exs and summarize the dependencies",
  provider: {Alloy.Provider.Google, api_key: "...", model: "gemini-2.5-flash"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  max_turns: 10
)
```

### Swap providers in one line

```elixir
# The same tools and conversation work with any provider
opts = [tools: [Alloy.Tool.Core.Read], max_turns: 10]

# Anthropic
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"}} | opts])

# OpenAI
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.2"}} | opts])

# Local (Ollama — no API key needed)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Ollama, model: "llama4"}} | opts])
```

### Supervised GenServer agent

```elixir
{:ok, agent} = Alloy.Agent.Server.start_link(
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Edit, Alloy.Tool.Core.Bash],
  system_prompt: "You are a senior Elixir developer."
)

{:ok, response} = Alloy.Agent.Server.chat(agent, "What does this project do?")
{:ok, response} = Alloy.Agent.Server.chat(agent, "Now refactor the main module")
```

### Multi-agent teams

```elixir
{:ok, team} = Alloy.Team.start_link(
  agents: [
    researcher: [
      provider: {Alloy.Provider.Google, api_key: "...", model: "gemini-2.5-flash"},
      system_prompt: "You are a research assistant."
    ],
    coder: [
      provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
      tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Write, Alloy.Tool.Core.Edit],
      system_prompt: "You are a senior developer."
    ]
  ]
)

# Delegate tasks to specific agents
{:ok, research} = Alloy.Team.delegate(team, :researcher, "Find the latest Elixir release notes")
{:ok, code} = Alloy.Team.delegate(team, :coder, "Write a GenServer that #{research.text}")
```

## Providers

| Provider | Module | API Key Env Var | Example Model |
|----------|--------|----------------|---------------|
| Anthropic | `Alloy.Provider.Anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-6` |
| OpenAI | `Alloy.Provider.OpenAI` | `OPENAI_API_KEY` | `gpt-5.2` |
| Google Gemini | `Alloy.Provider.Google` | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| Ollama | `Alloy.Provider.Ollama` | _(none — local)_ | `llama4` |
| OpenRouter | `Alloy.Provider.OpenRouter` | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-4-6` |
| xAI (Grok) | `Alloy.Provider.XAI` | `XAI_API_KEY` | `grok-3` |
| DeepSeek | `Alloy.Provider.DeepSeek` | `DEEPSEEK_API_KEY` | `deepseek-chat` |
| Mistral | `Alloy.Provider.Mistral` | `MISTRAL_API_KEY` | `mistral-large-latest` |

Adding a provider is ~200 lines implementing the `Alloy.Provider` behaviour.

## CLI

Alloy ships with an interactive REPL:

```bash
# Interactive mode
mix alloy
mix alloy --provider gemini --tools read,bash

# One-shot mode
mix alloy -p "What is the capital of France?"
mix alloy -p "Read mix.exs" --tools read --provider openai
```

## Built-in Tools

| Tool | Module | Description |
|------|--------|-------------|
| **read** | `Alloy.Tool.Core.Read` | Read files from disk |
| **write** | `Alloy.Tool.Core.Write` | Write files to disk |
| **edit** | `Alloy.Tool.Core.Edit` | Search-and-replace editing |
| **bash** | `Alloy.Tool.Core.Bash` | Execute shell commands |
| **scratchpad** | `Alloy.Tool.Core.Scratchpad` | Persistent key-value notepad |

### Custom tools

```elixir
defmodule MyApp.Tools.WebSearch do
  @behaviour Alloy.Tool

  @impl true
  def definition do
    %{
      name: "web_search",
      description: "Search the web for information",
      input_schema: %{
        type: "object",
        properties: %{query: %{type: "string", description: "Search query"}},
        required: ["query"]
      }
    }
  end

  @impl true
  def execute(%{"query" => query}, _context) do
    # Your implementation here
    {:ok, "Results for: #{query}"}
  end
end
```

## Architecture

```
Alloy.run/2                    One-shot agent loop (pure function)
Alloy.Agent.Server             GenServer wrapper (stateful, supervisable)
Alloy.Team                     Multi-agent supervisor (delegate, broadcast, handoff)
Alloy.Agent.Turn               Single turn: call provider → execute tools → return
Alloy.Provider                 Behaviour: translate wire format ↔ Alloy.Message
Alloy.Tool                     Behaviour: definition + execute
Alloy.Middleware               Pipeline: logger, telemetry, custom hooks
Alloy.Context.Compactor        Automatic conversation summarization
Alloy.Scheduler                Cron/heartbeat for recurring agent runs
```

## License

MIT — see [LICENSE](LICENSE).
