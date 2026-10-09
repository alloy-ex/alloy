# Alloy

[![Hex.pm](https://img.shields.io/hexpm/v/alloy.svg)](https://hex.pm/packages/alloy)
[![CI](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml/badge.svg)](https://github.com/alloy-ex/alloy/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alloy)
[![License](https://img.shields.io/hexpm/l/alloy.svg)](LICENSE)

**Minimal, OTP-native agent loop for Elixir.**

Alloy is the completion-tool-call loop and nothing else. Send messages to any LLM, execute tool calls, loop until done. Swap providers with one line. No opinions on sessions, persistence, memory, scheduling, or UI — those belong in your application, where OTP already gives you the runtime.

Alloy is a harness, not a framework. Four runtime dependencies, ~11,000 lines — small enough to read in a day, and everything beyond the loop is a [recipe](https://hexdocs.pm/alloy/sub-agents.html) built on the primitives, not a subsystem.

```elixir
{:ok, result} = Alloy.run("Read mix.exs and tell me the version",
  provider: {Alloy.Provider.OpenAI, api_key: System.get_env("OPENAI_API_KEY"), model: "gpt-5.4"},
  tools: [Alloy.Tool.Core.Read]
)

result.text #=> "The version is 0.12.4"
```

## Why Alloy?

Most agent frameworks try to be everything — sessions, memory, RAG, multi-agent orchestration, scheduling, UI. Alloy does one thing well: the agent loop. The BEAM makes the rest cheaper than a framework can: sub-agents are supervised function calls ([recipe](https://hexdocs.pm/alloy/sub-agents.html)), MCP servers mount as tools ([recipe](https://hexdocs.pm/alloy/mcp-tools.html)), parallel tool execution is `Task.Supervisor`, and crash isolation is just processes.

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

## Non-goals

Alloy does not own multi-agent orchestration; use the
[sub-agents recipe](https://hexdocs.pm/alloy/sub-agents.html), where an agent
spawns itself via a function call. Alloy does not sandbox your machine; use
`:bash_executor` with containers or another isolated runner. Sessions,
persistence, scheduling, hosted queues, dashboards, and UI stay in your
application layer. The library stays small so those choices remain yours.

## What's in the box

- **6 providers** — Anthropic, Gemini, OpenAI, Codex, xAI, and OpenAICompat (works with any OpenAI-compatible API: Ollama, OpenRouter, DeepSeek, Mistral, Groq, Together, etc.)
- **4 built-in tools** — read, write, edit, bash — plus inline tools defined as data with `Alloy.Tool.inline/1`
- **GenServer agents** — supervised, stateful, message-passing (moving to the optional `alloy_agent` runtime package in 0.13)
- **Streaming** — incremental HTTP provider output; Codex replays final text through the same interface
- **Async dispatch** — `send_message/2` fires non-blocking, result arrives via PubSub
- **Middleware** — custom hooks, tool blocking, argument editing
- **Context compaction** — tool-result clearing plus summary-based compaction when approaching token limits, with configurable reserve and fallback to truncation
- **Memory primitive** — `Alloy.Memory` behaviour for Anthropic's `memory_20250818` tool. Alloy owns the wire format and path validation; you own the store (in-memory, disk, Postgres — whatever fits)
- **Prompt caching** — Anthropic `cache: true` adds cache breakpoints for 60-90% input token savings
- **Reasoning blocks** — OpenAI encrypted reasoning, Anthropic and Gemini signed thinking, and DeepSeek/Kimi/GLM `reasoning_content` are kept as blocks and sent back the way each API requires
- **Tool guardrails** — `concurrent?/0` controls parallel execution, `max_result_chars/0` caps output, prompt-too-long auto-recovery. Note: the bash tool's restricted mode is a guardrail, not a sandbox — see [Built-in tools](#built-in-tools)
- **Structured output** — `until_tool` forces the loop to continue until a specific tool is called
- **Provider passthrough** — `extra_body` injects arbitrary provider-specific params (response_format, temperature, reasoning_effort)
- **Telemetry** — run, turn, provider, and compaction lifecycle events for OTEL/logging/metrics
- **Budget limits** — a small `:before_completion` middleware [recipe](#budget-limits) prices usage and halts the run
- **Pluggable model catalog** — `Alloy.ModelCatalog` behaviour; bring your own context-window source (e.g., an `llm_db` adapter)
- **~11,000 lines** — small enough to read, understand, and extend

## Installation

Add `alloy` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:alloy, "~> 0.12"}
  ]
end
```

> **Note:** the optional `alloy_agent` runtime wrapper (sessions, async
> dispatch, memory stores) referenced by the 0.12.x deprecation notices is
> **not yet published** to Hex. Until it ships, keep using
> `Alloy.Agent.Server` and `Alloy.Session` from this package — the 0.13
> removals will not happen before `alloy_agent` is available.

## Quick Start

Prefer a runnable version? [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Falloy-ex%2Falloy%2Fmain%2Flivebooks%2Fquickstart.livemd)

### Simple completion

```elixir
{:ok, result} = Alloy.run("What is 2+2?",
  provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-sonnet-5-5"}
)

result.text #=> "4"
```

### Agent with tools

```elixir
{:ok, result} = Alloy.run("Read mix.exs and summarize the dependencies",
  provider: {Alloy.Provider.Gemini,
    api_key: "...", model: "gemini-3.5-flash"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  max_turns: 10
)
```

For new Gemini integrations, Google recommends `gemini-3.8-flash` or
`gemini-3.5-flash-lite`; 2.5 access is restricted to prior active users. The
built-in catalog budgets context for Gemini 2.5 Pro/Flash/Flash-Lite,
`gemini-3.1-pro-preview`, 3.1 and 3.5 Flash-Lite, and 3.5–3.8 Flash. See
[provider compatibility](docs/provider-compatibility.md).

### Swap providers in one line

```elixir
# The same tools and conversation work with any provider
opts = [tools: [Alloy.Tool.Core.Read], max_turns: 10]

# Anthropic
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-5-5"}} | opts])

# OpenAI (Responses API)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-6.1-sol"}} | opts])

# Gemini
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.Gemini, api_key: "...", model: "gemini-3.8-flash"}} | opts])

# xAI (Responses API; its Chat Completions API is legacy and returns no reasoning)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.XAI, api_key: "...", model: "grok-4.7"}} | opts])

# DeepSeek (thinking mode; reasoning_content is sent back as the API requires)
Alloy.run("Read mix.exs", [{:provider, {Alloy.Provider.OpenAICompat, api_key: "...", api_url: "https://api.deepseek.com", model: "deepseek-v4-pro"}} | opts])

# Any OpenAI-compatible API (Ollama, OpenRouter, Mistral, Groq, etc.)
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

HTTP providers stream incrementally; Codex emulates streaming by replaying final text. If a custom provider doesn't implement
`stream/4`, the turn loop falls back to `complete/3` automatically.

`Alloy.run/2` remains the buffered convenience API. Use `Alloy.stream/3`
when you want the same one-shot flow with token streaming.

### Provider-owned state

Some provider APIs keep state on their side, such as stored OpenAI/xAI
response IDs or an Anthropic code-execution container. That transport
concern lives in Alloy; your app decides whether and how to persist it.

Results expose provider-owned state in `result.metadata.provider_state`.
Pass it back with the conversation when you continue a run, and the provider
reuses what it needs (for example the code-execution container):

```elixir
{:ok, next_result} =
  Alloy.run("Keep going",
    messages: result.messages,
    provider: {Alloy.Provider.Anthropic,
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      model: "claude-sonnet-5-5",
      provider_state: result.metadata.provider_state
    }
  )
```

By default every request carries the full conversation. To continue an
OpenAI or xAI response stored server-side instead, pass its ID as
`previous_response_id:` together with **only the new messages**: the server
prepends the stored conversation, so sending the full history too would
duplicate it and bill it twice.

```elixir
{:ok, next_result} =
  Alloy.run("Keep going",
    provider: {Alloy.Provider.XAI,
      api_key: System.get_env("XAI_API_KEY"),
      model: "grok-4.7",
      previous_response_id: result.metadata.provider_state.response_id
    }
  )
```

Without `previous_response_id` (and with `store` not `true`), the OpenAI and
xAI providers run stateless: they request encrypted reasoning and send
returned reasoning items back verbatim before their related function calls;
`result.text` ignores those opaque blocks.

### Provider-native tools and citations

Responses-compatible providers can expose built-in server-side tools without
leaking those wire details into your app layer.

For xAI search tools:

```elixir
{:ok, result} =
  Alloy.run("Summarise the latest xAI docs updates",
    provider: {Alloy.Provider.XAI,
      api_key: System.get_env("XAI_API_KEY"),
      model: "grok-4.7",
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

### Pluggable model catalog

The built-in catalog is deliberately small — Alloy is a harness, not a model
database, and a hand-curated list will always lag the release treadmill. For a
richer source of truth, implement the `Alloy.ModelCatalog` behaviour and pass
it via `model_catalog:`. For example, backed by
[`llm_db`](https://hex.pm/packages/llm_db) (45+ providers, maintained against
models.dev):

```elixir
defmodule MyApp.LlmDbCatalog do
  @behaviour Alloy.ModelCatalog

  @impl true
  def context_window(model) do
    case LLMDb.model(model) do
      %{context_window: limit} when is_integer(limit) -> limit
      _ -> nil
    end
  end
end

{:ok, result} = Alloy.run("Summarise this repository",
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"},
  model_catalog: MyApp.LlmDbCatalog
)
```

Resolution order: explicit `max_tokens` → `model_metadata_overrides` →
`model_catalog` → default window. Returning `nil` for an unknown model is
fine — Alloy falls back to the default.

Use `compaction:` when you want to tune how much room Alloy reserves before it
compacts older context:

```elixir
{:ok, result} = Alloy.run("Summarise this repository",
  provider: {Alloy.Provider.OpenAI, api_key: "...", model: "gpt-5.4"},
  compaction: [
    reserve_tokens: 12_000,
    keep_recent_tokens: 8_000,
    clear_tool_results: true,
    keep_recent_tool_results: 3,
    fallback: :truncate
  ]
)
```

Alloy first clears old `tool_result` content in one batch, preserving the
newest `keep_recent_tool_results` results, then only calls the summarizer if
the run is still over budget. Batched clearing matters with prompt caching:
clearing invalidates cached prefixes, so Alloy amortizes that cost instead of
dripping changes across turns. The estimate counts the system prompt, tool
definitions and every message block.

Whenever compaction changes history, thinking blocks are removed from turns
before the current one: Claude rejects signed thinking whose earlier history
changed, and dropping all of it from earlier turns is the documented way to
keep the transcript valid. Compaction never splits a tool call from its
result.

Set `summary_system_prompt:` and `summary_prompt:` inside `compaction:` when
your application needs to own the handoff format. Both values must be strings;
omitting them uses Alloy's default summary prompts.

### Budget limits

Price the accumulated usage in `:before_completion` middleware, which runs
before every provider request, and halt when the run reaches its limit:

```elixir
defmodule MyApp.BudgetGuard do
  @behaviour Alloy.Middleware

  # USD per million tokens for the model you run.
  @input_per_m 3.0
  @output_per_m 15.0

  @impl true
  def call(:before_completion, state) do
    limit = Map.fetch!(state.config.context, :max_budget_cents)
    usage = Alloy.Usage.estimate_cost(state.usage, @input_per_m, @output_per_m)

    if usage.estimated_cost_cents >= limit,
      do: {:halt, "budget of #{limit} cents reached"},
      else: state
  end

  def call(_hook, state), do: state
end

Alloy.run(prompt,
  provider: provider,
  middleware: [MyApp.BudgetGuard],
  context: %{max_budget_cents: 50}
)
```

A halted run returns `{:error, result}` with `status: :halted`.
`estimate_cost/3` prices input and output tokens only; `usage.input_tokens`
is uncached input, so add your provider's cache read and write prices
(`cache_read_input_tokens`, `cache_creation_input_tokens`) if you use prompt
caching. The `max_budget_cents:` option is deprecated and will be removed in
0.13: no built-in provider reports a cost, so it never fired with them.

### Anthropic prompt caching

Enable prompt caching to save 60-90% on input tokens. Alloy automatically adds
`cache_control` breakpoints to the system prompt, the last tool definition
that is not `defer_loading`, and the end of the conversation:

```elixir
{:ok, result} = Alloy.run("Explain this codebase",
  provider: {Alloy.Provider.Anthropic,
    api_key: "...", model: "claude-sonnet-5-5",
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
  provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-sonnet-5-5"},
  memory: {MyApp.Memory.Disk, root: "/var/agent/memories"}
)
```

When `:memory` is set, Alloy injects the `memory_20250818` tool into the
Anthropic request (the memory tool is generally available; no beta header is
needed). Memory tool calls are routed through `Alloy.Memory.Router`, which
validates every path against the `/memories` root, so the typed-tool
contract stays clean. Configuring `:memory` together with your own tool named
`memory` raises at startup.

The store term (second element of `{module, opts}`) is opaque — pass a
keyword list, a map, a `pid()`, or a struct, whichever your store needs.
Alloy does not bake session scoping into the contract; if you want
per-session memory trees, thread `session_id: "..."` through your store
opts and namespace inside your implementation.

As of 0.12.0, memory is Anthropic-only — configuring `:memory` with any
other provider raises at `Alloy.run/2` entry. Other providers will be
wired as they ship their own memory primitives.

### Reasoning model support (DeepSeek, Kimi, GLM)

OpenAI-compatible reasoning models that return `reasoning_content` are parsed
into thinking blocks, and the reasoning is sent back on later assistant
messages, which DeepSeek's thinking mode requires during tool calls:

```elixir
{:ok, result} = Alloy.run("Solve this step by step",
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://api.deepseek.com",
    api_key: "...", model: "deepseek-v4-pro"
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
    api_key: "...", model: "deepseek-v4-pro",
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
  [:alloy, :run, :exception],
  [:alloy, :turn, :start],
  [:alloy, :turn, :stop],
  [:alloy, :turn, :exception],
  [:alloy, :provider, :request],
  [:alloy, :compaction, :cleared],
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
| `[:alloy, :run, :exception]` | `duration_ms` | `kind`, `reason`, `stacktrace`, `model` |
| `[:alloy, :turn, :start]` | `system_time`, `monotonic_time` | `turn`, `telemetry_span_context` |
| `[:alloy, :turn, :stop]` | `duration`, `monotonic_time` | `turn`, `status`, `telemetry_span_context` |
| `[:alloy, :turn, :exception]` | `duration`, `monotonic_time` | `turn`, `kind`, `reason`, `stacktrace` |
| `[:alloy, :provider, :request]` | `duration_ms` | `provider`, `model`, `streaming`, `attempt`, `result` |
| `[:alloy, :compaction, :cleared]` | `results_cleared`, `bytes_cleared` | `turn` |
| `[:alloy, :compaction, :done]` | `messages_before`, `messages_after` | `turn` |
| `[:alloy, :tool, :start]` | — | tool identity, correlation |
| `[:alloy, :tool, :stop]` | `duration_ms` | tool identity, result |

Each turn's stop fires when that turn ends. A turn the loop continues past
reports `status: :running`; the run's outcome is on `[:alloy, :run, :stop]`.

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
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-5-5"},
  tools: [SubmitAnswer],
  until_tool: "submit_answer"
)
```

The target tool's call has to succeed: a call that errors, is blocked by
middleware, or names an unknown tool does not satisfy `until_tool`.

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
| Anthropic | `Alloy.Provider.Anthropic` | `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` |
| Gemini | `Alloy.Provider.Gemini` | `gemini-3.8-flash`, `gemini-3.5-flash-lite` |
| OpenAI | `Alloy.Provider.OpenAI` | `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-luna` |
| xAI | `Alloy.Provider.XAI` | `grok-4.7`, `grok-4.3` |
| Codex CLI (ChatGPT subscription) | `Alloy.Provider.Codex` | any model your Codex login can use |
| Other OpenAI-compatible APIs | `Alloy.Provider.OpenAICompat` | DeepSeek `deepseek-v4-pro`, Moonshot `kimi-k2.6`, plus Ollama, OpenRouter, Mistral, Groq, Together |

The table lists current example IDs, not a built-in catalog or a live-tested
model allowlist. Models outside the built-in catalog use a 200,000-token
compaction budget; set `model_metadata_overrides` or a `model_catalog` for
them. Check [provider compatibility](docs/provider-compatibility.md) for
context overrides, adaptive thinking, and MCP version constraints.

Use `Alloy.Provider.OpenAI` for OpenAI Responses and `Alloy.Provider.XAI` for
xAI Responses. Current OpenAI models (GPT-5.4 and later) only call tools with
reasoning on through the Responses API, so use `Alloy.Provider.OpenAI` rather
than `OpenAICompat` for them. Use `Alloy.Provider.Gemini` for Gemini's native
GenerateContent API, and `Alloy.Provider.OpenAICompat` for chat-completions
compatible APIs and local runtimes: set `api_url`, `model`, and optionally
`api_key` and `chat_path`.

No built-in provider sends a default output cap except Anthropic, whose API
requires one (16,000 tokens by default). Reasoning counts against the cap on
current models, so set `:max_tokens` only when you want a hard limit; a
truncated answer completes with `result.stop_reason == :max_tokens`.

**Anthropic thinking.** Claude 4.7 and later reject the manual
`extended_thinking: [budget_tokens: ...]` option, which is deprecated; use
adaptive thinking through `extra_body`:

```elixir
{Alloy.Provider.Anthropic,
 api_key: "...",
 model: "claude-sonnet-5-5",
 extra_body: %{"thinking" => %{"type" => "adaptive", "display" => "summarized"}}}
```

**Codex.** `Alloy.Provider.Codex` drives the `codex` CLI (0.122.0 or later)
with your ChatGPT login and reports token usage. It uses your `CODEX_HOME`,
including its `AGENTS.md` and skills. For agents, log in to a dedicated home
(`CODEX_HOME=~/.codex-alloy codex login`) and pass `codex_home:` — that also
keeps concurrent agents from refreshing the same token as your interactive
Codex.

## Built-in Tools

| Tool | Module | Description |
|------|--------|-------------|
| **read** | `Alloy.Tool.Core.Read` | Read text files, paged with `offset`/`limit`; refuses binary files |
| **write** | `Alloy.Tool.Core.Write` | Write files to disk |
| **edit** | `Alloy.Tool.Core.Edit` | Exact search-and-replace; keeps CRLF line endings and BOMs |
| **bash** | `Alloy.Tool.Core.Bash` | Execute shell commands (restricted shell by default) |

Tool calls run in the order the model made them; consecutive calls to
concurrency-safe tools run in parallel. Input that is not a map, or is
missing a schema's `required` keys, is returned to the model as an error
before `execute/2` runs.

> **Bash is a guardrail, not a sandbox.** Restricted mode (`bash -r`) blocks
> `cd`, `PATH` changes, and redirection in the top-level shell only — a
> nested `bash -c` or any interpreter on `PATH` (`python3 -c`, `perl -e`)
> gives full capability, so treat it as a speed bump against accidents, not
> an isolation boundary. What bash does guarantee: on timeout it kills the
> command's whole process group; output is capped while it streams; and
> variables whose names contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or
> `CREDENTIAL` are not passed to commands (set `:bash_env` in context to
> choose the environment, or `:inherit` for all of it). For real isolation,
> supply your own `:bash_executor` in context (container, jail, firejail, or
> a remote runner). `:allowed_paths` restricts the read, write and edit
> tools to those directories (symlinks resolved); it does not restrict bash.
> Treat the agent's shell access as you would a contractor's laptop on your
> network.

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
      required: ["query"],
      additionalProperties: false
    }
  end

  @impl true
  def strict?, do: true

  @impl true
  def execute(%{"query" => query}, _context) do
    # Your implementation here
    {:ok, "Results for: #{query}"}
  end
end
```

Prefer strict mode for tools that have stable schemas. Set `strict?/0` on a
module tool, or `strict: true` on an inline tool, and include
`additionalProperties: false` in the top-level JSON Schema. Alloy validates
that requirement instead of silently rewriting your schema. OpenAI strict mode
also requires every property to be listed in `required`.

For Anthropic advanced tool use, add `input_examples/0` or `input_examples:`
with representative argument maps to improve parameter selection. Set
`defer_loading?/0` or `defer_loading: true` for tools that should be exposed
through Anthropic's deferred-loading path; other providers ignore these fields.

### Inline tools

For one-off tools, or tools discovered at runtime (an MCP server's tool
list, user-defined actions from a database), define a tool as data with
`Alloy.Tool.inline/1` — no module needed. Inline tools and tool modules
mix freely in `tools:`:

```elixir
weather =
  Alloy.Tool.inline(
    name: "get_weather",
    description: "Get current weather for a location",
    input_schema: %{
      type: "object",
      properties: %{location: %{type: "string"}},
      required: ["location"]
    },
    execute: fn %{"location" => loc}, _context ->
      {:ok, MyApp.Weather.current(loc)}
    end
  )

{:ok, result} = Alloy.run("What's the weather in Sydney?",
  provider: provider,
  tools: [weather, Alloy.Tool.Core.Read]
)
```

Optional fields mirror the behaviour's optional callbacks: `concurrent?:`,
`max_result_chars:`, `allowed_callers:`, `result_type:`. See
`Alloy.Tool.Inline` for details.

### Code execution (Anthropic)

Enable Anthropic's server-side code execution sandbox:

```elixir
{:ok, result} = Alloy.run("Calculate the first 20 Fibonacci numbers",
  provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-5-5"},
  code_execution: true
)
```

Anthropic runs server tools itself, so Alloy never answers their calls. To let
Claude call one of your tools from inside code execution (programmatic tool
calling), set `allowed_callers: [:code_execution]` on the tool; Alloy keeps
the code-execution container across turns in `provider_state`. Add other
server tools — web search, web fetch, `mcp_toolset`, tool search — with the
provider's `:server_tools` option, alongside your own tools:

```elixir
{Alloy.Provider.Anthropic,
 api_key: "...",
 model: "claude-sonnet-5-5",
 server_tools: [%{type: "web_search_20260209", name: "web_search", max_uses: 5}]}
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
When `ALLOY_WEBSITE_SYNC_TOKEN` is configured, successful publishes also
dispatch the landing-site version sync workflow. The token needs Contents:
write on `alloy-ex/alloy-ex.github.io`; without it the dispatch is skipped
with a warning. GitHub Release entries are separate from Hex publishing.
Check [Hex](https://hex.pm/packages/alloy) for published package versions.
