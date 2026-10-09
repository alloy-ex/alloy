# Provider compatibility

Checked against official documentation on **9 October 2026**. Alloy uses Req
and provider REST wire formats; it does not depend on the Python or JavaScript
provider SDKs. A new SDK release alone does not require an Alloy dependency
upgrade. Model access and deployment settings still depend on your account.

## Current model families

The adapters accept model IDs without a catalog allowlist. The built-in
context catalog is separate and intentionally small. Unknown IDs currently
use a 200,000-token fallback; use `model_metadata_overrides` or your own
`Alloy.ModelCatalog` for a newer model's documented window.

| Provider | Current examples | Alloy route and constraints |
| --- | --- | --- |
| OpenAI | `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6-luna` | `Alloy.Provider.OpenAI` uses Responses and preserves opaque reasoning items. Sol requires Responses for tool calls; Luna's Chat Completions tool support requires reasoning disabled. Check each model's allowed effort values. [Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna). |
| Anthropic | `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` | `Alloy.Provider.Anthropic` uses Messages. New models use adaptive thinking; manual budgets are rejected on Claude 4.7 and later. [Models](https://platform.claude.com/docs/en/models/overview), [manual thinking compatibility](https://platform.claude.com/docs/en/build-with-claude/extended-thinking). |
| Gemini | `gemini-3.8-flash`, `gemini-3.5-flash-lite` | `Alloy.Provider.Gemini` uses GenerateContent; `generation_config` passes native settings. `OpenAICompat` can use Google's Chat Completions endpoint. Preserve thought signatures through tool turns. 2.5 models remain served but access is restricted to prior active users. [Models](https://ai.google.dev/gemini-api/docs/models), [compatibility endpoint](https://ai.google.dev/gemini-api/docs/openai). |
| xAI | `grok-4.7` | `Alloy.Provider.XAI` wraps the Responses adapter. The model returns encrypted reasoning even without an explicit include request; preserve those items. Its documented window is 500,000 tokens. [Models](https://docs.x.ai/developers/models). |
| Other compatible endpoints | Your endpoint's supported model ID | `Alloy.Provider.OpenAICompat` implements Chat Completions. Compatibility is specific to the endpoint; tool calling, reasoning fields, and usage extensions are not universal. |
| Codex CLI | A model available to your installed CLI and login | `Alloy.Provider.Codex` delegates a structured completion to `codex exec --json` (CLI 0.122.0 or later) against your `CODEX_HOME`, or `:codex_home`. It replays final text for streaming and reports usage from the CLI's `turn.completed` events. Use a dedicated home for agents so they don't share a refresh token with interactive Codex. [Noninteractive mode](https://developers.openai.com/codex/noninteractive). |

Budget with the most **input** a model accepts, not its advertised window:
OpenAI's 1,050,000-token windows include output, and the API rejects input
above 922,000 tokens, so the built-in catalog lists 922,000 for those
models. An override that is too large is the dangerous mistake — compaction
then fires only after the API has started rejecting requests. For a model
the catalog doesn't know yet:

```elixir
Alloy.run("Summarize this repository",
  provider: {Alloy.Provider.OpenAI,
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    model: "gpt-6.2-example"},
  model_metadata_overrides: %{"gpt-6.2-example" => 922_000}
)
```

For current Claude models, use adaptive thinking through existing passthrough
(the `extended_thinking` option was removed in 0.13). Thinking text is omitted by default
on several new models; request summarized display when your UI needs it.
Do not carry old sampling or forced-tool-choice settings into a new model
without checking its contract. [Thinking configuration](https://platform.claude.com/docs/en/build-with-claude/thinking).

```elixir
provider = {Alloy.Provider.Anthropic,
  api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
  model: "claude-sonnet-5-5",
  extra_body: %{"thinking" => %{"type" => "adaptive", "display" => "summarized"}}
}
```

### Preserved thinking and compaction

Claude Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5 accept a replayed
thinking block only while the `system` prompt, `tools` and earlier messages
are unchanged. Accounts created on or after 31 August 2026 get a 400
otherwise. Alloy keeps `system` and `tools` fixed for a run and only appends
to `messages`, except when it compacts. After compaction it removes every
thinking block it keeps, which is the documented valid change, so no beta
header is needed. If you edit history yourself, either do the same or opt
into the API dropping stale blocks:

```elixir
extra_headers: [{"anthropic-beta", "thinking-binding-controls-2026-08-01"}],
extra_body: %{
  "thinking" => %{
    "type" => "adaptive",
    "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
  }
}
```

[Preserved thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking).

### Switching provider mid-conversation

Each assistant message records its provider, model and origin: a hash of
the provider module, `:api_url` and `:api_key`. Before every request,
including to a fallback provider, `Alloy.Message.normalize_for/3` rewrites
messages from a different origin, meaning another provider, endpoint or
account:

- thinking becomes plain text, with signatures removed;
- redacted thinking, raw OpenAI and xAI reasoning items, and Anthropic
  server-tool records are dropped;
- tool-call ids outside `[a-zA-Z0-9_-]{1,64}` are rewritten.

Gemini receives Google's placeholder thought signature on the first tool
call of each step it did not produce.

Switching models on one origin keeps everything. Anthropic and OpenAI drop
reasoning the new model can't use themselves, and Gemini says to resend it.
Encrypted reasoning only ever goes back to the endpoint and credentials
that issued it, since OpenAI ties it to the issuing organisation. Rotating
an API key counts as a new origin, so earlier reasoning is then sent as
text. Messages saved without their `origin` are sent unchanged.

Known limits:

- **DeepSeek thinking mode with tools** requires `reasoning_content` on
  every earlier assistant turn. Turns written by another provider have
  none, so switching to DeepSeek in the middle of a tool conversation can
  be rejected. Start a new conversation, or turn thinking off for it.
- **Anthropic manual thinking** (`"type" => "enabled"`, Claude 4.6 and
  earlier) requires the turn in progress to start with a thinking block,
  which a turn written by another provider lacks. Adaptive thinking, the
  only mode on current models, has no such rule.
- **`OpenAICompat`** is one provider module for many vendors, so switching
  vendors behind it counts as the same provider. Reasoning there is plain
  text, which every vendor accepts.

The provider tests check serialization, stream parsing, and opaque state
round-trips using fixtures. Those checks do not certify every current model
against a live API. Validate a new model on your application's evals before
changing production defaults.

## MCP compatibility

Alloy delegates local MCP transport, negotiation, and authentication to the
application's client library; see the [MCP recipe](recipes/mcp-tools.md).
The recipe's 2025 protocol version is explicit. The
[2026-07-28 protocol](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
changes sessions, initialization, notifications, and per-request metadata.
Changing a version string is insufficient.

[Anubis 2.1 documents support through 2025-11-25](https://anubis-mcp.hexdocs.pm/readme.html).
Its 2.x upgrade also removes the old HTTP+SSE transport. Neither its version
number nor Alloy's gateway establishes 2026 protocol support. Choose a client
and server with compatible protocol versions, and test that pair separately.
Tasks, MCP Apps, and Skills-over-MCP are optional extensions; they are not
required to keep Alloy's ordinary tool loop working. Discovery refresh,
allowlists, authorization, and extension handling remain application concerns.

Anthropic's remote connector uses `mcp_servers` plus `mcp_toolset` entries in
`tools`, through `extra_body`. Use the `mcp-client-2025-11-20` beta header;
the older April header is deprecated. A newer September beta adds optional
tool-list pinning. The connector handles remote tool calls, not local stdio or
all MCP features, and is not eligible for zero data retention. See the
[official connector contract](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector).

## Usage and releases

Every built-in provider, including Codex, reports token counts with the same
meaning: `input_tokens` is uncached input, cache reads and writes are in
`cache_read_input_tokens` and `cache_creation_input_tokens`, and
`output_tokens` includes reasoning or thinking tokens. Total prompt tokens
are the sum of the three input fields.

No built-in provider attaches a monetary cost, which is why the
`max_budget_cents` option was removed in 0.13; enforce a budget with `:before_completion` middleware that prices
`state.usage` (see "Budget limits" in the README). Application billing
controls must still account for cache tiers, long-context surcharges and
server-tool fees. `Alloy.Usage.estimate_cost/3` is a helper, not price
discovery.

Hex is the package release source. GitHub tags, GitHub Release entries,
the landing site, and the main branch can differ. Unreleased main changes are
not available just by installing the latest Hex package. Check the changelog
and exact package version when reproducing a bug.
