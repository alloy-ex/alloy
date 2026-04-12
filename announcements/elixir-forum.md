## Alloy 0.8.0 — model-agnostic agent engine for Elixir

[Alloy](https://hex.pm/packages/alloy) is a minimal agent loop for building AI agents on the BEAM. Think of it as the completion-tool-call loop and nothing else — no opinions on sessions, persistence, or UI.

### What's new in 0.8.0

**Cost guard** — pass `max_budget_cents: 50` to `Alloy.run/2` and the loop halts with `:budget_exceeded` status before your agent overspends. The check runs at the start of each turn alongside `max_turns`.

```elixir
{:ok, result} = Alloy.run("Research this codebase",
  provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  max_budget_cents: 50
)
# result.status => :budget_exceeded | :completed
```

**Summary-based context compaction** — when conversations approach the token limit, Alloy generates a structured handoff summary of older context instead of truncating. The summary preserves progress, key decisions, constraints, and next steps. Falls back to deterministic truncation if summary generation fails.

Compaction is now configurable:

```elixir
Alloy.run(input,
  provider: provider,
  compaction: [
    reserve_tokens: 12_000,       # Room for the next response
    keep_recent_tokens: 8_000,    # Recent messages kept verbatim
    fallback: :truncate           # When summary fails
  ]
)
```

**One-shot streaming** — `Alloy.stream/3` gives you token-by-token output without managing a GenServer:

```elixir
{:ok, result} = Alloy.stream("Explain OTP", fn chunk ->
  IO.write(chunk)
end, provider: {Alloy.Provider.OpenAI, api_key: key, model: "gpt-5.4"})
```

### Why model-agnostic matters

Alloy works with Anthropic, OpenAI (Responses API), xAI/Grok, Gemini, and any OpenAI-compatible endpoint (Ollama, OpenRouter, DeepSeek, Mistral, Groq). Swap providers by changing one line — your tools, prompts, and agent logic stay the same.

Today's best model might not be tomorrow's. Building on Alloy means you can switch without rewriting your agent.

### The philosophy

Inspired by [Pi Agent](https://github.com/badlogic/pi-mono)'s minimalism: 4 built-in tools (read, write, edit, bash), a good prompt, and a loop. That's the framework. ~5,000 lines, small enough to read and understand in an afternoon.

OTP gives us the rest for free: supervision trees for fault tolerance, `Task.Supervisor` for parallel tool execution, PubSub for event streaming, GenServer for stateful agents.

### Links

- Hex: https://hex.pm/packages/alloy
- GitHub: https://github.com/alloy-ex/alloy
- Docs: https://hexdocs.pm/alloy
- Changelog: https://github.com/alloy-ex/alloy/blob/main/CHANGELOG.md

Feedback, issues, and PRs welcome. Happy to answer questions about the architecture.
