# Provider compatibility

Checked against official documentation on **8 October 2026**. Alloy uses Req
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
| Anthropic | `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` | `Alloy.Provider.Anthropic` uses Messages. New models use adaptive thinking; fixed `extended_thinking: [budget_tokens: ...]` sends an unsupported manual mode on Claude 4.7 and later. [Models](https://platform.claude.com/docs/en/models/overview), [manual thinking compatibility](https://platform.claude.com/docs/en/build-with-claude/extended-thinking). |
| Gemini | `gemini-3.8-flash`, `gemini-3.5-flash-lite` | `Alloy.Provider.Gemini` uses GenerateContent; `generation_config` passes native settings. `OpenAICompat` can use Google's Chat Completions endpoint. Preserve thought signatures through tool turns. 2.5 models remain served but access is restricted to prior active users. [Models](https://ai.google.dev/gemini-api/docs/models), [compatibility endpoint](https://ai.google.dev/gemini-api/docs/openai). |
| xAI | `grok-4.7` | `Alloy.Provider.XAI` wraps the Responses adapter. The model returns encrypted reasoning even without an explicit include request; preserve those items. Its documented window is 500,000 tokens. [Models](https://docs.x.ai/developers/models). |
| Other compatible endpoints | Your endpoint's supported model ID | `Alloy.Provider.OpenAICompat` implements Chat Completions. Compatibility is specific to the endpoint; tool calling, reasoning fields, and usage extensions are not universal. |
| Codex CLI | A model available to your installed CLI and login | `Alloy.Provider.Codex` delegates a structured completion to `codex exec`. It replays final text for streaming and currently reports zero usage. The CLI supports JSONL usage events; this adapter does not yet consume them. [Noninteractive mode](https://developers.openai.com/codex/noninteractive). |

For example, OpenAI documents a 1,050,000-token context window for Sol:

```elixir
Alloy.run("Summarize this repository",
  provider: {Alloy.Provider.OpenAI,
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    model: "gpt-6.1-sol"},
  model_metadata_overrides: %{"gpt-6.1-sol" => 1_050_000}
)
```

For current Claude models, use adaptive thinking through existing passthrough.
Omit the legacy `extended_thinking` option. Thinking text is omitted by default
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

`max_budget_cents` checks accumulated provider-reported monetary estimates.
The built-in HTTP providers report token counts but do not currently attach
`estimated_cost_cents`; their estimate stays zero. The built-in Codex provider
also reports zero token counts. This option therefore does not enforce an
expense cap with the built-in providers. A custom provider can supply cost
estimates; application billing controls must account for cache tiers, long
contexts, and server-tool fees. `Alloy.Usage.estimate_cost/3` is a helper, not
automatic price discovery or billing enforcement.

Hex is the package release source. GitHub tags, GitHub Release entries,
the landing site, and the main branch can differ. Unreleased main changes are
not available just by installing the latest Hex package. Check the changelog
and exact package version when reproducing a bug.
