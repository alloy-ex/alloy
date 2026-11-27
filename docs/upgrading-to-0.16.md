# Upgrading to 0.16

Alloy 0.16 adds major-lab wire parity (multimodal PDFs/documents, image URLs,
dynamic `:api_key` callbacks, provider caching, Gemini native tools, portable
`:reasoning`), uniform v1 streaming events, cooperative cancellation
(`Alloy.Cancel`), mid-run `:steering` and completion `:follow_up` callbacks,
`Alloy.Tool.Executor.run_tool/3`, and optional `Alloy.ModelCatalog` capability
and pricing metadata — all with zero new mandatory runtime dependencies.

Most v0.14 callers upgrade cleanly; review the contract additions and stricter
checks below before bumping.

## 1. Cooperative cancellation (`:cancelled` status and error kind)

Runs given a `:cancel_token` (`Alloy.Cancel.new/0`) return
`{:error, %Alloy.Result{status: :cancelled, error: :cancelled}}` when cancelled
cooperatively.

- **Exhaustive pattern matches:** `Alloy.Agent.State.status()`,
  `Alloy.Result.status`, and `Alloy.Provider.Error.kind()` now include
  `:cancelled`. Update any exhaustive `case` matches on run status, `:turn_end`
  event status, `[:alloy, :run, :stop]` telemetry status, or `error.kind`.
- **Fail-closed middleware check:** `Alloy.Middleware.run_before_tool_call/2`
  now returns `:cancelled` when `state.config.cancel_token` is cancelled (while
  preserving explicit `{:block, reason}` verdicts). Callers invoking
  `run_before_tool_call/2` directly must handle `:cancelled`.
- **Runtime provider config key:** When `:cancel_token` is set, Alloy injects
  `:alloy_cancel_token` into the `provider_config` map passed to providers
  (alongside `:alloy_request_deadline`). Custom providers using strict option
  validators should tolerate unknown `:alloy_*` keys.

## 2. Dynamic `:api_key` callbacks & required `:origin_key`

Built-in HTTP providers (`Anthropic`, `OpenAI`, `XAI`, `Gemini`, `OpenAICompat`)
now accept a 0-arity `:api_key` callback returning
`String.t() | {:ok, String.t()} | {:error, term()}` resolved per HTTP attempt.

- **Required `:origin_key`:** Using a function `:api_key` OR
  `auth_scheme: :bearer` now **requires** a non-empty string `:origin_key` so
  rotating credentials preserve account provenance across turns and
  origin-scoped file attachments (`file_id` / Gemini File API URIs). Passing
  either without `:origin_key` raises `ArgumentError` at startup.
- **Key validation:** Resolved API keys must be printable ASCII without CR/LF
  characters; arbitrary callback failures map to non-retryable
  `%Alloy.Provider.Error{kind: :auth}` with sanitized messages (explicit
  `{:error, %Alloy.Provider.Error{}}` returns preserve allowlisted kinds,
  including `:cancelled`, with diagnostic fields redacted).

## 3. Portable `:reasoning` option

Pass `:reasoning` at the top level (`Alloy.run/2`, `Alloy.stream/3`,
`Alloy.Agent.State.prepare/2`) or inside provider config:
`nil | :off | :low | :medium | :high | :xhigh | %{effort: ..., display: ...}`.

- **Anthropic `reasoning: :off`:** Explicitly sends
  `%{"thinking" => %{"type" => "disabled"}}` (whereas `reasoning: nil` omits
  `"thinking"` as in v0.14). Explicit `"thinking"` inside `extra_body` still
  takes precedence.
- **Compaction summary stripping:** `:reasoning` (along with
  `:prompt_cache_key`, `:prompt_cache_retention`, `:cached_content`,
  `:google_search`, `:url_context`, and Gemini `:code_execution`) is stripped
  automatically on compaction summary requests.

## 4. Uniform v1 streaming events (`docs/events.md`)

`Alloy.Events` v1 adds five additive event types:

- `:turn_start` (`%{turn:}`) and `:turn_end`
  (`%{turn:, status:, stop_reason:, usage:}`)
- `:thinking_delta` across Anthropic, OpenAI/xAI Responses, Gemini, and
  OpenAICompat
- `:tool_call_delta` (`%{id:, index:, name:, arguments_delta:}`)
- `:tool_update` (`%{id:, name:, chunk:, start_event_seq:}`), marshalled to the
  caller process and wired to `Alloy.Tool.Core.Bash`
- Optional `:parent_call_id` on `:tool_start`, `:tool_update`, and `:tool_end`
  when emitted for nested calls via `Alloy.Tool.Executor.run_tool/3` or
  `execute_all/4`

Subscribers matching on v1 envelopes should keep a catch-all clause for unknown
event atoms. Note that `:thinking_delta`, `:tool_call_delta`, and
`:tool_update` are emitted only when `:on_event` is subscribed so unsubscribed
`Alloy.stream/3` callers preserve retry/fallback resilience across non-text
deltas.

## 5. Stricter `OpenAIStream` tool-call validation & `Events.build_correlation_id/1`

- `Alloy.Provider.OpenAIStream` and `Alloy.Provider.OpenAI` now enforce
  stricter tool-call stream invariants: negative tool-call indices, conflicting
  tool identities (`id` / `name` changes on the same slot), and contradictory
  terminal tool arguments return non-retryable `:protocol_error` (or retryable
  `:malformed_reply` on incomplete/corrupted argument JSON) rather than
  silently corrupting tool calls.
- `Alloy.Events.build_correlation_id/1` now requires non-empty valid UTF-8
  strings for `context[:request_id]` and `context[:correlation_id]`; empty
  strings (`""`) or invalid UTF-8 fall back cleanly to a generated correlation
  ID instead of propagating invalid IDs to `Alloy.Tool.Executor`.

## 6. Mid-run `:steering` and completion `:follow_up`

- `:steering` (`(State.t() -> [Message.t()])`) is polled between completed tool
  batches; non-empty messages skip remaining unstarted batches with synthetic
  error `tool_result` blocks, append the steering messages, and advance to the
  next turn (bypassing `:stop_after_tool`).
- `:follow_up` (`(State.t() -> [Message.t()])`) is polled right before normal
  non-refusal `:end_turn` completion once `:until_tool` is satisfied, bounded
  by `:max_turns`, `:timeout_ms`, and `:cancel_token`.
- Both callbacks strictly validate returned `[%Alloy.Message{}]` lists (roles,
  UTF-8, JSON-compatible block fields, and `Alloy.Transcript.validate/1 == :ok`)
  and sanitize exceptions/throws/exits with `:redact`.

## 7. Reusable single-tool execution & optional `Alloy.ModelCatalog` metadata

- `Alloy.Tool.Executor.run_tool/3` executes a single tool call through the same
  middleware, schema validation, supervised worker, deadline clamping,
  composed cancellation, and event/telemetry pipeline as `execute_all/4`, with
  native `:parent_call_id` support.
- `Alloy.ModelCatalog` keeps `c:Alloy.ModelCatalog.context_window/1` as the sole
  required callback and adds optional `c:Alloy.ModelCatalog.max_output_tokens/1`,
  `c:Alloy.ModelCatalog.capabilities/1`, and `c:Alloy.ModelCatalog.pricing/1`
  callbacks plus `Alloy.ModelCatalog.info/1,2`. Minimal v0.14
  catalogs implementing only `context_window/1` continue to work unchanged (the
  optional fields return `nil`). See `docs/recipes/llm-db-catalog.md` for a
  provider-scoped `LLMDB` adapter.
