# Alloy

[![Hex.pm](https://img.shields.io/hexpm/v/alloy.svg)](https://hex.pm/packages/alloy)
[![CI](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml/badge.svg)](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alloy)
[![License](https://img.shields.io/hexpm/l/alloy.svg)](LICENSE)

**Minimal, OTP-native agent loop for Elixir.**

Alloy is the completion-tool-call loop and nothing else. Send messages to any LLM, execute tool calls, loop until done. Swap providers with one line. Run agents as supervised GenServers. No opinions on sessions, persistence, memory, scheduling, or UI — those belong in your application.

```elixir
{:ok, result} = Alloy.run("Read mix.exs and tell me the version",
  provider: {Alloy.Provider.OpenAI, api_key: System.get_env("OPENAI_API_KEY"), model: "gpt-5.4"},
  tools: [Alloy.Tool.Core.Read]
)

result.text #=> "The version is 0.12.0"
```

## Why Alloy?

Most agent frameworks try to be everything — sessions, memory, RAG, multi-agent orchestration, scheduling, UI. Alloy does one thing well: the agent loop. Inspired by [Pi Agent](https://github.com/badlogic/pi-mono)'s minimalism, Alloy brings the same philosophy to the BEAM with OTP's natural advantages: supervision, fault isolation, parallel tool execution, and real concurrency.

- **6 providers** — Anthropic, Gemini, OpenAI, Codex, xAI, and OpenAICompat (works with any OpenAI-compatible API: Ollama, OpenRouter, DeepSeek, Mistral, Groq, Together, etc.)
- **4 built-in tools** — read, write, edit, bash
- **GenServer agents** — supervised, stateful, message-passing
- **Streaming** — token-by-token from any provider, unified interface
- **Async dispatch** — `send_message/2` fires non-blocking, result arrives via PubSub
- **Middleware** — custom hooks, tool blocking, argument editing
- **Context compaction** — summary-based compaction when approaching token limits, with configurable reserve and fallback to truncation
- **Memory primitive** — `Alloy.Memory` behaviour for Anthropic's `memory_20250818` tool. Alloy owns the wire format and path validation; you own the store (in-memory, disk, Postgres — whatever fits)
- **Prompt caching** — Anthropic `cache: true` adds cache breakpoints for 60-90% input token savings
- **Reasoning blocks** — DeepSeek/xAI `reasoning_content` parsed as first-class thinking blocks
- **Tool safety** — `concurrent?/0` controls parallel execution, `max_result_chars/0` caps output, prompt-too-long auto-recovery
- **Structured output** — `until_tool` forces the loop to continue until a specific tool is called
- **Provider passthrough** — `extra_body` injects arbitrary provider-specific params (response_format, temperature, reasoning_effort)
- **Telemetry** — run, turn, provider, and compaction lifecycle events for OTEL/logging/metrics
- **Cost guard** — `max_budget_cents` halts the loop before overspending
- **OTP-native** — supervision trees, hot code reloading, real parallel tool execution
- **~7,500 lines** — small enough to read, understand, and extend

## Design Boundary

Alloy stays minimal by owning protocol and loop concerns, not application
workflows.

What belongs in Alloy:
- Provider wire-format translation
- Tool-call / completion loop mechanics
- Normalized message blocks
- Opaque provider-owned state such as stored response IDs
- Provider response metadata such as citations or server-side tool telemetry

What does not belong in Alloy:
- Sessions and persistence policy
- File storage, indexing, or retrieval workflows
- UI rendering for citations, search, or artifacts
- Scheduling, background job orchestration, or dashboards
- Tenant plans, quotas, billing, or hosted infrastructure policy

Rule of thumb: if the feature is required to speak a provider API correctly,
and could help any Alloy consumer, it likely belongs here. If it needs a
database table, product defaults, UI decisions, or tenancy logic, it belongs in
your application layer.

## Installation

Add `alloy` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:alloy, "~> 0.12"},
    # Optional: supervised runtime wrapper (sessions, async dispatch, memory stores)
    {:alloy_agent, "~> 0.1"}
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
  provider: {Alloy.Provider.Gemini,
    api_key: "...", model: "gemini-2.5-flash-lite"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  max_turns: 10
)
```

Gemini model IDs Alloy now budgets for include `gemini-2.5-pro`,
`gemini-2.5-flash`, `gemini-2.5-flash-lite`, `gemini-3-pro-preview`, and
`gemini-3-flash-preview`.

### Swap providers in one line

```elixir
# The same tools and conversation work with any provider
opts = [tools: [Alloy.Tool.Core.Read], max_turns: 10]

# Anthropic
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"}} | opts])

# OpenAI
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"}} | opts])

# Gemini
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Gemini, api_key: "...", model: "gemini-2.5-flash"}} | opts])

# xAI via Responses-compatible API
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAI, api_key: "...", api_url: "https://api.x.ai", model: "grok-4.20-0309-reasoning"}} | opts])

# xAI via chat completions (reasoning models, extra_body)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAICompat, api_key: "...", api_url: "https://api.x.ai", model: "grok-4.1-fast-reasoning"}} | opts])

# Any OpenAI-compatible API (Ollama, OpenRouter, DeepSeek, Mistral, Groq, etc.)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAICompat, api_url: "http://localhost:11434", model: "llama4"}} | opts])
```

### Streaming

For a one-shot run, use `Alloy.stream/3`:

```elixir
{:ok, result} =
  Alloy.stream("Explain OTP", fn chunk ->
    IO.write(chunk)
  end,
    provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"}
  )
```

For a persistent agent process with conversation state, use `Alloy.Agent.Server.stream_chat/4`:

```elixir
{:ok, agent} = Alloy.Agent.Server.start_link(
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"},
  tools: [Alloy.Tool.Core.Read]
)

{:ok, result} = Alloy.Agent.Server.stream_chat(agent, "Explain OTP", fn chunk ->
  IO.write(chunk)  # Print each token as it arrives
end)
```

All providers support streaming. If a custom provider doesn't implement
`stream/4`, the turn loop falls back to `complete/3` automatically.

`Alloy.run/2` remains the buffered convenience API. Use `Alloy.stream/3`
when you want the same one-shot flow with token streaming.

### Provider-owned state

Some provider APIs expose server-side state such as stored response IDs.
That transport concern lives in Alloy; your app decides whether and how to
persist it.

Results expose provider-owned state in `result.metadata.provider_state`:

```elixir
{:ok, result} =
  Alloy.run("Read the repo",
    provider: {Alloy.Provider.OpenAI,
      api_key: System.get_env("XAI_API_KEY"),
      api_url: "https://api.x.ai",
      model: "grok-4.20-0309-reasoning",
      store: true
    }
  )

provider_state = result.metadata.provider_state
```

Pass that state back to the same provider on the next turn to continue a
provider-native conversation:

```elixir
{:ok, next_result} =
  Alloy.run("Keep going",
    messages: result.messages,
    provider: {Alloy.Provider.OpenAI,
      api_key: System.get_env("XAI_API_KEY"),
      api_url: "https://api.x.ai",
      model: "grok-4.20-0309-reasoning",
      provider_state: provider_state
    }
  )
```

### Provider-native tools and citations

Responses-compatible providers can expose built-in server-side tools without
leaking those wire details into your app layer.

For xAI search tools:

```elixir
{:ok, result} =
  Alloy.run("Summarise the latest xAI docs updates",
    provider: {Alloy.Provider.OpenAI,
      api_key: System.get_env("XAI_API_KEY"),
      api_url: "https://api.x.ai",
      model: "grok-4.20-0309-reasoning",
      web_search: %{allowed_domains: ["docs.x.ai"]},
      include: ["inline_citations"]
    }
  )
```

Citation metadata is exposed in two places:
- `result.metadata.provider_response.citations` for provider-level citation data
- assistant text blocks may include `:annotations` for inline citation spans

### Overriding model metadata

Alloy derives the compaction budget from the configured provider model when it
knows that model's context window. If you need to support a just-released model
before Alloy ships a catalog update, override it in config:

```elixir
{:ok, result} = Alloy.run("Summarise this repository",
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4-2026-03-05"},
  model_metadata_overrides: %{
    "gpt-5.4" => 900_000,
    "acme-reasoner" => %{limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]}
  }
)
```

Set `max_tokens` explicitly when you want a fixed compaction budget. Otherwise
Alloy derives it from the current model, including after
`Alloy.Agent.Server.set_model/2` switches to a different provider model.

Use `compaction:` when you want to tune how much room Alloy reserves before it
summarizes older context:

```elixir
{:ok, result} = Alloy.run("Summarise this repository",
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"},
  compaction: [
    reserve_tokens: 12_000,
    keep_recent_tokens: 8_000,
    fallback: :truncate
  ]
)
```

### Cost guard

Cap how much an agent run can spend:

```elixir
{:ok, result} = Alloy.run("Research this codebase thoroughly",
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  max_budget_cents: 50
)

case result.status do
  :completed -> IO.puts(result.text)
  :budget_exceeded -> IO.puts("Stopped: spent #{result.usage.estimated_cost_cents}¢")
end
```

Set `max_budget_cents: nil` (default) for no limit.

### Anthropic prompt caching

Enable prompt caching to save 60-90% on input tokens. Alloy automatically adds
`cache_control` breakpoints to the system prompt and last tool definition:

```elixir
{:ok, result} = Alloy.run("Explain this codebase",
  provider: {Alloy.Provider.Anthropic,
    api_key: "...", model: "claude-sonnet-4-6",
    cache: true
  },
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  system_prompt: "You are a senior Elixir developer."
)

# Cache usage is reported in result.usage
result.usage.cache_creation_input_tokens  #=> 1500
result.usage.cache_read_input_tokens      #=> 1500  (on subsequent calls)
```

### Memory (Anthropic `memory_20250818`)

Alloy exposes memory as a behaviour — `Alloy.Memory` — matching the split
Anthropic uses in their own Python SDK: Alloy owns the protocol (six
commands on a `/memories/` tree, return-string formats, path validation);
your code owns the backing store. No bytes touch Anthropic's servers.

```elixir
defmodule MyApp.Memory.Disk do
  @behaviour Alloy.Memory

  @impl true
  def view(store, path), do: # read from disk
  @impl true
  def create(store, path, text), do: # write
  @impl true
  def str_replace(store, path, old, new), do: # ...
  @impl true
  def insert(store, path, line, text), do: # ...
  @impl true
  def delete(store, path), do: # ...
  @impl true
  def rename(store, old_path, new_path), do: # ...
end

{:ok, result} = Alloy.run("Remember the user prefers SI units",
  provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-sonnet-4-6"},
  memory: {MyApp.Memory.Disk, root: "/var/agent/memories"}
)
```

When `:memory` is set, Alloy injects the `memory_20250818` tool into the
Anthropic request and adds the `context-management-2025-06-27` beta
header. Memory tool calls are routed through `Alloy.Memory.Router`
(not the general tool executor) so the typed-tool contract stays clean.

The store term (second element of `{module, opts}`) is opaque — pass a
keyword list, a map, a `pid()`, or a struct, whichever your store needs.
Alloy does not bake session scoping into the contract; if you want
per-session memory trees, thread `session_id: "..."` through your store
opts and namespace inside your implementation.

As of 0.12.0, memory is Anthropic-only — configuring `:memory` with any
other provider raises at `Alloy.run/2` entry. Other providers will be
wired as they ship their own memory primitives.

### Reasoning model support (DeepSeek, xAI)

OpenAI-compatible reasoning models that return `reasoning_content` (DeepSeek-R1,
xAI Grok reasoning variants) are automatically parsed into thinking blocks:

```elixir
{:ok, result} = Alloy.run("Solve this step by step",
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://api.x.ai",
    api_key: "...", model: "grok-4.1-fast-reasoning"
  }
)

# Thinking blocks are preserved in message content
[thinking, text] = hd(result.messages).content
thinking.type     #=> "thinking"
thinking.thinking #=> "Step 1: Let me consider..."
text.type         #=> "text"
text.text         #=> "The answer is 42."
```

### Provider-specific parameters (extra_body)

Pass arbitrary provider-specific parameters via `extra_body`. It merges last,
so it can override any default field:

```elixir
{:ok, result} = Alloy.run("Return JSON",
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://api.deepseek.com",
    api_key: "...", model: "deepseek-chat",
    extra_body: %{
      "response_format" => %{"type" => "json_object"},
      "temperature" => 0.3
    }
  }
)
```

Works for any provider param: `reasoning_effort`, `max_completion_tokens`,
`presence_penalty`, etc.

### Telemetry

Alloy emits telemetry events for observability. Attach handlers for OTEL,
logging, or custom metrics:

```elixir
:telemetry.attach_many("my-handler", [
  [:alloy, :run, :start],
  [:alloy, :run, :stop],
  [:alloy, :turn, :start],
  [:alloy, :turn, :stop],
  [:alloy, :provider, :request],
  [:alloy, :compaction, :done],
  [:alloy, :tool, :start],
  [:alloy, :tool, :stop],
  [:alloy, :event]
], &MyApp.Telemetry.handle_event/4, nil)
```

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:alloy, :run, :start]` | `system_time` | `model` |
| `[:alloy, :run, :stop]` | `duration_ms` | `status`, `turns`, `model` |
| `[:alloy, :turn, :start]` | `system_time` | `turn` |
| `[:alloy, :turn, :stop]` | — | `turn`, `status` |
| `[:alloy, :provider, :request]` | `duration_ms` | `provider`, `model`, `streaming`, `attempt`, `result` |
| `[:alloy, :compaction, :done]` | `messages_before`, `messages_after` | `turn` |
| `[:alloy, :tool, :start]` | — | tool identity, correlation |
| `[:alloy, :tool, :stop]` | `duration_ms` | tool identity, result |

### Structured output with `until_tool`

Force the model to call a specific tool before the loop completes. This is more
reliable than response format instructions because the tool schema is validated
at the API level:

```elixir
defmodule SubmitAnswer do
  @behaviour Alloy.Tool
  def name, do: "submit_answer"
  def description, do: "Submit your final answer as structured data."
  def input_schema do
    %{type: "object", properties: %{
      answer: %{type: "string"},
      confidence: %{type: "number", minimum: 0, maximum: 1}
    }, required: ["answer", "confidence"]}
  end
  def execute(input, _ctx), do: {:ok, "Received: #{input["answer"]}"}
end

{:ok, result} = Alloy.run("What is the capital of France?",
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
  tools: [SubmitAnswer],
  until_tool: "submit_answer"
)
```

### Middleware: editing tool arguments

Middleware can return `{:edit, modified_call}` from `:before_tool_call` to rewrite
tool arguments before execution (e.g., policy enforcement, input sanitization):

```elixir
defmodule SanitizeBash do
  @behaviour Alloy.Middleware

  def call(:before_tool_call, state) do
    call = state.config.context[:current_tool_call]

    if call[:name] == "bash" && String.contains?(call[:input]["command"], "rm ") do
      {:edit, %{call | input: %{"command" => "echo 'rm commands are blocked'"}}}
    else
      state
    end
  end

  def call(_hook, state), do: state
end
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

| Vendor | Recommended Module | Example Models |
|--------|---------------------|----------------|
| Anthropic | `Alloy.Provider.Anthropic` | `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5` |
| Gemini | `Alloy.Provider.Gemini` | `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-3-pro-preview`, `gemma-4-26b-a4b-it` (open-weight) |
| OpenAI | `Alloy.Provider.OpenAI` | `gpt-5.4` |
| xAI | `Alloy.Provider.OpenAI` with `api_url: "https://api.x.ai"` | `grok-4.20-0309-reasoning`, `grok-4.20-multi-agent-0309`, `grok-4.1-fast-reasoning`, `grok-code-fast-1` |
| Other OpenAI-compatible APIs | `Alloy.Provider.OpenAICompat` | `kimi-k2.6` (Moonshot), `qwen3-coder-plus` (1M ctx), `glm-4.6`, `mistral-large-2512`, plus Ollama, OpenRouter, DeepSeek, Groq, Together |

Use `Alloy.Provider.OpenAI` for native Responses APIs like OpenAI and xAI.
Use `Alloy.Provider.Gemini` for Gemini's native GenerateContent API.
Use `Alloy.Provider.OpenAICompat` for chat-completions compatible APIs and local runtimes.

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

## Releases

Hex.pm publishing is handled by GitHub Actions on `v*` tags.
Successful publishes also dispatch the landing-site version sync workflow.
