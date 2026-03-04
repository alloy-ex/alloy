# Alloy

[![Hex.pm](https://img.shields.io/hexpm/v/alloy.svg)](https://hex.pm/packages/alloy)
[![CI](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml/badge.svg)](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alloy)
[![License](https://img.shields.io/hexpm/l/alloy.svg)](LICENSE)

**Minimal, OTP-native agent loop for Elixir.**

Alloy is the completion-tool-call loop and nothing else. Send messages to any LLM, execute tool calls, loop until done. Swap providers with one line. Run agents as supervised GenServers. No opinions on sessions, persistence, memory, scheduling, or UI — those belong in your application.

```elixir
{:ok, result} = Alloy.run("Read mix.exs and tell me the version",
  provider: {Alloy.Provider.OpenAI, api_key: System.get_env("OPENAI_API_KEY"), model: "gpt-5.2"},
  tools: [Alloy.Tool.Core.Read]
)

result.text #=> "The version is 0.7.0"
```

## Why Alloy?

Most agent frameworks try to be everything — sessions, memory, RAG, multi-agent orchestration, scheduling, UI. Alloy does one thing well: the agent loop. Inspired by [Pi Agent](https://github.com/badlogic/pi-mono)'s minimalism, Alloy brings the same philosophy to the BEAM with OTP's natural advantages: supervision, fault isolation, parallel tool execution, and real concurrency.

- **3 providers** — Anthropic, OpenAI, and OpenAICompat (works with any OpenAI-compatible API: Ollama, OpenRouter, xAI, DeepSeek, Mistral, Groq, Together, etc.)
- **4 built-in tools** — read, write, edit, bash
- **GenServer agents** — supervised, stateful, message-passing
- **Streaming** — token-by-token from any provider, unified interface
- **Async dispatch** — `send_message/2` fires non-blocking, result arrives via PubSub
- **Middleware** — custom hooks, tool blocking
- **Context compaction** — automatic summarization when approaching token limits
- **OTP-native** — supervision trees, hot code reloading, real parallel tool execution
- **~5,000 lines** — small enough to read, understand, and extend

## Installation

Add `alloy` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:alloy, "~> 0.7"}
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
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://generativelanguage.googleapis.com",
    chat_path: "/v1beta/openai/chat/completions",
    api_key: "...", model: "gemini-2.5-flash"},
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

# Any OpenAI-compatible API (Ollama, OpenRouter, xAI, DeepSeek, Mistral, Groq, etc.)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAICompat, api_url: "http://localhost:11434", model: "llama4"}} | opts])
```

### Streaming

Stream tokens as they arrive — works with every provider:

```elixir
{:ok, agent} = Alloy.Agent.Server.start_link(
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.2"},
  tools: [Alloy.Tool.Core.Read]
)

{:ok, result} = Alloy.Agent.Server.stream_chat(agent, "Explain OTP", fn chunk ->
  IO.write(chunk)  # Print each token as it arrives
end)
```

All providers support streaming. If a custom provider doesn't implement
`stream/4`, the turn loop falls back to `complete/3` automatically.

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

### Async dispatch (Phoenix LiveView)

Fire a message without blocking the caller — ideal for LiveView and background jobs:

```elixir
# Subscribe to receive the result
Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}:responses")

# Returns {:ok, request_id} immediately — agent works in the background
{:ok, req_id} = Alloy.Agent.Server.send_message(agent, "Summarise this report",
  request_id: "req-123"
)

# Handle the result whenever it arrives
def handle_info({:agent_response, %{text: text, request_id: "req-123"}}, socket) do
  {:noreply, assign(socket, :response, text)}
end
```

## Providers

| Provider | Module | Example |
|----------|--------|---------|
| Anthropic | `Alloy.Provider.Anthropic` | `model: "claude-sonnet-4-6"` |
| OpenAI | `Alloy.Provider.OpenAI` | `model: "gpt-5.2"` |
| Any OpenAI-compatible | `Alloy.Provider.OpenAICompat` | Ollama, OpenRouter, xAI, DeepSeek, Mistral, Groq, Together |

`OpenAICompat` works with any API that implements the OpenAI chat completions format.
Just set `api_url`, `model`, and optionally `api_key` and `chat_path`.

## Built-in Tools

| Tool | Module | Description |
|------|--------|-------------|
| **read** | `Alloy.Tool.Core.Read` | Read files from disk |
| **write** | `Alloy.Tool.Core.Write` | Write files to disk |
| **edit** | `Alloy.Tool.Core.Edit` | Search-and-replace editing |
| **bash** | `Alloy.Tool.Core.Bash` | Execute shell commands (restricted shell by default) |

### Custom tools

```elixir
defmodule MyApp.Tools.WebSearch do
  @behaviour Alloy.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information"

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{query: %{type: "string", description: "Search query"}},
      required: ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}, _context) do
    # Your implementation here
    {:ok, "Results for: #{query}"}
  end
end
```

### Code execution (Anthropic)

Enable Anthropic's server-side code execution sandbox:

```elixir
{:ok, result} = Alloy.run("Calculate the first 20 Fibonacci numbers",
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
  code_execution: true
)
```

## Architecture

```
Alloy.run/2                    One-shot agent loop (pure function)
Alloy.Agent.Server             GenServer wrapper (stateful, supervisable)
Alloy.Agent.Turn               Single turn: call provider → execute tools → return
Alloy.Provider                 Behaviour: translate wire format ↔ Alloy.Message
Alloy.Tool                     Behaviour: name, description, input_schema, execute
Alloy.Middleware               Pipeline: custom hooks, tool blocking
Alloy.Context.Compactor        Automatic conversation summarization
```

Sessions, persistence, multi-agent coordination, scheduling, skills, and UI
belong in your application layer. See [Anvil](https://github.com/alloy-ex/anvil)
for a reference Phoenix application built on Alloy.

## License

MIT — see [LICENSE](LICENSE).
