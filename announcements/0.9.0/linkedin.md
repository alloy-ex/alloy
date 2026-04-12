Alloy 0.9.0 is out — the model-agnostic agent engine for Elixir.

This release focuses on making provider-level features first-class without adding complexity.

The headline: Anthropic prompt caching support. One config flag — cache: true — and Alloy automatically adds cache breakpoints to your system prompt and tool definitions. That's 60-90% savings on input tokens for repeat conversations. If you're running agents in production, this pays for itself immediately.

What else is new:

→ Reasoning model support — DeepSeek and xAI models that expose reasoning_content now produce thinking blocks automatically. No special handling needed — they show up in your message content alongside the text response.

→ extra_body config — need response_format, temperature, reasoning_effort, or any other provider-specific parameter? Pass extra_body: %{"temperature" => 0.3} and it merges into the request. One mechanism covers every current and future provider param.

→ Full telemetry — 6 new events covering run lifecycle, turn boundaries, provider request timing, and compaction. Attach your OTEL exporter or Logger and you have production observability out of the box.

→ xAI model refresh — grok-4 family corrected to 2M context windows. Added grok-4.1-fast model family with dot-notation matching.

The philosophy hasn't changed: Alloy is the completion-tool-call loop and nothing else. Provider wire format, tool execution, context compaction, and now telemetry — all legitimate harness concerns. Sessions, persistence, memory, and orchestration still belong in your application.

Built on Elixir/OTP. Supervised agents, parallel tool execution, real fault tolerance. ~5,000 lines.

https://hex.pm/packages/alloy
https://github.com/alloy-ex/alloy
