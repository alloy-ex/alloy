## Alloy 0.9.0 — prompt caching, reasoning blocks, telemetry

[Alloy](https://hex.pm/packages/alloy) is a minimal, model-agnostic agent loop for Elixir. Completion → tool calls → loop until done. This release adds provider-level features that were identified as concrete gaps.

### Anthropic prompt caching

Pass `cache: true` and Alloy adds `cache_control` breakpoints to the system prompt and last tool definition — Anthropic's recommended pattern. Saves 60-90% on input tokens for conversations that reuse the same system prompt and tools.

```elixir
{:ok, result} = Alloy.run("Explain this codebase",
  provider: {Alloy.Provider.Anthropic,
    api_key: key, model: "claude-sonnet-4-6",
    cache: true
  },
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
  system_prompt: "You are a senior Elixir developer."
)

result.usage.cache_creation_input_tokens  #=> 1500 (first call)
result.usage.cache_read_input_tokens      #=> 1500 (subsequent calls)
```

### Reasoning model support (DeepSeek, xAI)

OpenAI-compatible reasoning models that return `reasoning_content` (e.g. DeepSeek-R1) now produce `%{type: "thinking", thinking: text}` blocks instead of silently dropping the reasoning data. Works in both `complete/3` and streaming.

```elixir
{:ok, result} = Alloy.run("Solve this step by step",
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://api.deepseek.com",
    api_key: key, model: "deepseek-reasoner"
  }
)

# Thinking blocks appear before text blocks
[thinking, text] = hd(result.messages).content
thinking.type     #=> "thinking"
thinking.thinking #=> "Step 1: ..."
```

### Provider-specific parameters (extra_body)

Instead of adding individual config keys for every provider parameter, `extra_body` is a single map merge at the end of request building. It handles any current or future param:

```elixir
Alloy.run("Return JSON",
  provider: {Alloy.Provider.OpenAICompat,
    api_url: "https://api.x.ai",
    api_key: key, model: "grok-4",
    extra_body: %{
      "response_format" => %{"type" => "json_object"},
      "temperature" => 0.3
    }
  }
)
```

### Telemetry

6 new events for production observability:

| Event | What |
|-------|------|
| `[:alloy, :run, :start/stop]` | Full run lifecycle with duration, status, turn count |
| `[:alloy, :turn, :start/stop]` | Per-turn boundaries |
| `[:alloy, :provider, :request]` | Provider call duration, model, attempt number |
| `[:alloy, :compaction, :done]` | When compaction fires, message count before/after |

Plus the existing `[:alloy, :tool, :start/stop]` and `[:alloy, :event]`. Attach your OTEL exporter or a Logger handler and you have full visibility.

### Model metadata

- grok-4 context window corrected from 256K to 2M
- Added grok-4.1-fast model family (dot notation matching actual xAI API model IDs)
- Both `grok-4-1-fast-*` (dash) and `grok-4.1-fast-*` (dot) notations supported

### Bug fix

- xAI returns error responses as `{"error": "plain string"}` instead of OpenAI's `{"error": {"type": ..., "message": ...}}`. OpenAICompat now handles both formats.

### Links

- Hex: https://hex.pm/packages/alloy
- GitHub: https://github.com/alloy-ex/alloy
- Docs: https://hexdocs.pm/alloy
- Changelog: https://github.com/alloy-ex/alloy/blob/main/CHANGELOG.md

Feedback and questions welcome. The [design boundary](https://github.com/alloy-ex/alloy#design-boundary) section in the README explains what belongs in Alloy vs your application layer if you're wondering about scope.
