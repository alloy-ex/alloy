# ADR 0006: v0.16 Interactive Harness & Major-Lab Parity

Date: 2026-11-26

Status: Proposed

## Context

Through v0.14.0, Alloy established a minimal, OTP-native completion-and-tool
loop with end-to-end deadlines, supervised worker isolation, secret-safe
sanitization, portable `:output_schema`, and 6 built-in providers. Comparing
Alloy against production coding-agent harnesses (such as Pi) and current
major-lab APIs (Anthropic, OpenAI Responses, Gemini, xAI) highlights concrete
gaps that belong in the protocol and loop harness layer:

1. **Uneven major-lab wire coverage:** PDF/document blocks work only as URIs on
   Gemini (emitting unsupported-media notices on Anthropic and OpenAI), image
   URLs are not portable, reasoning effort still requires vendor-specific
   `extra_body`/`generation_config`, `:thinking_delta` streams only from
   Anthropic, Gemini lacks first-class built-in tools (`:google_search`,
   `:url_context`, `:code_execution`) and `:cached_content`, and `:api_key`
   only accepts static strings (blocking rotating OAuth/ADC tokens).
2. **Limited streaming observability:** `:on_event` v1 emits only text/thinking
   deltas and tool start/end, without turn boundaries, partial tool-call JSON
   deltas, or incremental tool output updates.
3. **No cooperative mid-run control:** Runs cannot be cancelled cooperatively
   with preserved partial transcripts, nor steered between tool batches or
   extended via follow-up queues without killing the caller or restarting a
   fresh run.
4. **Nested tool execution:** ADR 0001 and ADR 0002 deferred extracting a
   single-tool execution API until host experiments demonstrated the need. Code
   mode and composite-tool hosts currently have to call `execute/2` directly,
   bypassing middleware, schema validation, deadlines, cancellation, and
   parent-linked events.
5. **Catalog metadata:** `Alloy.ModelCatalog` exposes only `context_window/1`,
   leaving callers without optional capability or pricing discovery for
   built-in families or `llm_db` adapters.

## Decision

Deliver these capabilities inside `alloy` core (targeting `v0.16.0`) with **zero
new mandatory runtime dependencies** (`req`, `mint`, `jason`, `telemetry` only)
while keeping enterprise cloud transports (AWS Bedrock, Google Vertex AI, Azure
OpenAI) deferred to a separate `alloy_cloud` package and keeping sessions,
PubSub, OAuth token storage, UI, and scripting VMs outside core.

### 1. Multimodal & Major-Lab Wire Parity
- Support portable `image` (`data:` or `url:`) and `document` (`data:` base64,
  `uri:` URL, or `file_id:`) content blocks across Anthropic, OpenAI/xAI
  Responses, and Gemini (and URL images on OpenAICompat). Origin-scoped
  `file_id` documents are dropped by `Message.normalize_for/3` on cross-origin
  switches.
- Allow `:api_key` on built-in HTTP providers to be either `String.t()` or a
  0-arity function returning `String.t() | {:ok, String.t()} | {:error, term()}`
  resolved per HTTP attempt; arbitrary callback failures map to non-retryable
  `%Alloy.Provider.Error{kind: :auth}` with sanitized messages, while explicit
  `{:error, %Alloy.Provider.Error{}}` returns preserve allowlisted kinds
  (`:auth`, `:timeout`, `:rate_limited`, `:overloaded`, `:server_error`,
  `:network`, `:invalid_request`, `:quota`) with redacted diagnostic fields.
  Origin hashing never invokes the callback.
- Add first-class caching and native tool options: Anthropic `:cache` TTL
  (`"5m" | "1h"`) and `:web_search` shorthand; OpenAI/xAI `:prompt_cache_key`
  and `:prompt_cache_retention`; Gemini `:cached_content`, `:google_search`,
  `:url_context`, and `:code_execution` (all stripped on compaction summary
  requests).

### 2. Portable `:reasoning` & Uniform v1 Streaming Events
- Add a top-level (and provider-overridable) `:reasoning` option accepting
  `nil | :off | :low | :medium | :high | :xhigh | %{effort: ..., display: ...}`,
  updatable via `State.prepare/2`, forwarded to fallback providers, stripped on
  compaction summaries, and overridable by explicit `extra_body` /
  `generation_config`.
- Extend `:on_event` v1 (backwards-compatibly) with:
  - uniform `:thinking_delta` across Anthropic, OpenAI/xAI, Gemini, and
    OpenAICompat/OpenAIStream;
  - `:tool_call_delta` (`%{id:, index:, name:, arguments_delta:}`);
  - `:turn_start` (`%{turn:}`) and `:turn_end` (`%{turn:, status:, stop_reason:, usage:}`);
  - `:tool_update` (`%{id:, name:, chunk:, start_event_seq:}`) delivered back to
    the caller process so `:on_event` remains strictly single-process, wired to
    `Core.Bash` alongside an optional `:bash_on_output` producer callback.

### 3. Cooperative Cancellation, Steering & Follow-Up
- Introduce `Alloy.Cancel` backed by a lock-free `:atomics` flag (zero
  processes, zero ETS tables, zero leaks). When `:cancel_token` is supplied,
  `Turn`, `Retry`, `OwnedWorker`, `CodexRunner`, and `Executor` observe
  cancellation promptly (within `<= 50ms` inside worker waits), tear down
  in-flight workers/subprocesses cleanly, emit matching synthetic error
  `tool_result` blocks for unstarted/aborted tool calls so
  `Transcript.validate/1` remains `:ok`, and return
  `{:error, %Result{status: :cancelled, error: :cancelled}}`.
- Add optional `:steering` (`(State.t() -> [Message.t()])`) and `:follow_up`
  (`(State.t() -> [Message.t()])`) callbacks:
  - `:steering` is polled between tool batches; non-empty messages skip
    remaining unstarted batches with synthetic error `tool_result` blocks,
    append the steering messages, and start the next turn.
  - `:follow_up` is polled right before normal `:end_turn` completion; non-empty
    messages append and continue the loop (still bounded by `:max_turns`,
    `:timeout_ms`, and `:cancel_token`).

### 4. Reusable Single-Tool Execution (`Executor.run_tool/3`)
- Superseding the deferral in ADR 0001 / ADR 0002, extract
  `Alloy.Tool.Executor.run_tool/3` sharing the exact internal pipeline as
  `execute_all/4` (middleware, validation, supervised timeout/cancellation,
  redaction, and caller-process events with optional `:parent_call_id`). Update
  the Code Mode recipe to route nested calls through `Executor.run_tool/3`.

### 5. Optional `Alloy.ModelCatalog` Metadata
- Retain `c:context_window/1` as the sole required callback and add optional
  `c:max_output_tokens/1`, `c:capabilities/1`, and `c:pricing/1` callbacks
  implemented in `Alloy.ModelMetadata`, plus an `llm_db` catalog recipe.

## Consequences

- Zero new mandatory dependencies; all new event types and catalog callbacks
  are additive and backwards-compatible with v0.14 consumers.
- Callers with exhaustive matches on `State.status()` / `Result.status` or
  `Alloy.Provider.Error.kind()` must handle `:cancelled`.
- Compaction summary sanitization must strip the new `:reasoning`,
  `:prompt_cache_key`, `:cached_content`, and Gemini native tool options so
  summary turns stay cheap and schema/tool-free.
- Enterprise cloud endpoints (Bedrock, Vertex AI, Azure OpenAI) remain outside
  `alloy` core for `alloy_cloud`.

## References

- [ADR 0001: Minimal core and optional capabilities](0001-minimal-core-and-optional-capabilities.md)
- [ADR 0002: Composable loop controls](0002-composable-loop-controls.md)
- [ADR 0005: Portable output schema](0005-portable-output-schema.md)
- [Event envelope specification](../events.md)
