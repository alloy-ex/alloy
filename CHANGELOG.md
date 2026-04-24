# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.1] - 2026-04-24

### Deprecated

- **`Alloy.Agent.Server`**, **`Alloy.Session`**, and **`Alloy.Agent.Events`** are now documented as deprecated in HexDocs (warning admonitions on each `@moduledoc`). These modules moved to the new [`alloy_agent`](https://hex.pm/packages/alloy_agent) package as `AlloyAgent.Server`, `AlloyAgent.Session`, and `AlloyAgent.Events`. The copies in Alloy continue to work unchanged in 0.12.x and will be **removed in 0.13.0**.

> **No `@deprecated` attribute / compile-time warnings yet.** The protocol loop (`Alloy.Agent.Turn`) still calls `Alloy.Agent.Events` internally, so adding `@deprecated` would break `mix compile --warnings-as-errors` for Alloy itself. The protocol/runtime split for events will be tightened in a follow-up patch ahead of 0.13.0; in the meantime, the HexDocs admonitions and the migration table below are the migration signal.

### Why

Alloy is refocusing as a protocol library: the loop, providers, tools, memory behaviour, message types. Runtime concerns (supervised processes, sessions, async dispatch, PubSub, backpressure, default memory stores) belong in the application layer, where OTP already gives you the primitives. `alloy_agent` is the opt-in runtime wrapper for users who want a supervised agent without wiring a GenServer themselves.

Elixir's value proposition here is stronger than in Python or TypeScript: the BEAM already is the runtime. A protocol library that composes *with* OTP beats a runtime library that competes with it.

### Migration

Add `{:alloy_agent, "~> 0.1"}` to your deps, then:

| Before (Alloy 0.12.0) | After (alloy_agent 0.1.0) |
|---|---|
| `alias Alloy.Agent.Server` | `alias AlloyAgent.Server` (or just `alias AlloyAgent`) |
| `%Alloy.Session{}` | `%AlloyAgent.Session{}` |
| `Alloy.Session.new/1` | `AlloyAgent.Session.new/1` |
| `Alloy.send_message/3` | `AlloyAgent.send_message/3` |
| `Alloy.cancel_request/2` | `AlloyAgent.cancel_request/2` |

Code that uses only `Alloy.run/2`, `Alloy.stream/3`, tools, providers, messages, or the memory behaviour needs **no changes**.

### Not changed

- No runtime behaviour change in this release. The deprecated modules work exactly as they did in 0.12.0. This is a soft-migration patch — you have until Alloy 0.13.0 to move your imports.

## [0.12.0] - 2026-04-24

### Added

- **`Alloy.Memory` behaviour** — first-class protocol for Anthropic's `memory_20250818` tool. Six callbacks (`view`, `create`, `str_replace`, `insert`, `delete`, `rename`) that any store can implement, matching the split used by Anthropic's own Python SDK (`BetaAbstractMemoryTool`). Memory is a protocol-level primitive with application-level storage — Alloy ships the behaviour, wire format, and path validation; user code (or future `alloy_agent`) ships the backing store.
- **Anthropic provider memory wiring** — passing `memory: {StoreModule, store_opts}` to `Alloy.run/2` when using `Alloy.Provider.Anthropic` now injects the `memory_20250818` tool into the request and adds the `context-management-2025-06-27` beta header. Memory tool calls are routed through `Alloy.Memory.Router` rather than the generic tool executor, keeping the pipelines clean.
- **`Alloy.run/2` `:memory` option** — validates at entry that memory requires `Alloy.Provider.Anthropic` (raises `ArgumentError` otherwise, with a clear migration path). Other providers will be wired as they ship their own memory primitives.
- **Model catalog** — added context-window entries for:
  - Kimi K2.5, K2.6 (Moonshot AI, 256K) — via `OpenAICompat` at `api.moonshot.ai`
  - Gemma 4 (Google open-weight, 256K) — via `Gemini` provider
  - GLM-4.6 (Zhipu AI, 200K) — via `OpenAICompat` at `open.bigmodel.cn`
  - Qwen 3 family — `qwen3-max`/`qwen3-coder-plus` (up to 1M context), `qwen3-vl-plus`, `qwen3-omni-flash`, `qwen3.5-397b-a17b` — via `OpenAICompat` at DashScope
  - Mistral Large 3 (`mistral-large-2512`, 256K) — via `OpenAICompat` at `api.mistral.ai`

### Notes

- Memory is non-breaking: existing callers who do not pass `:memory` see zero behavioural change.
- The `context-management-2025-06-27` beta header is injected **only** when memory is configured. Accounts without beta access continue to see requests exactly as before.
- The 1M-context Qwen 3 entries (`qwen3-coder-plus`, `qwen3.5-397b-a17b`) are notable — they offer a larger window than the current OpenAI/Anthropic ceilings and slot into Alloy through the generic `OpenAICompat` provider with no new code.

## [0.11.0] - 2026-04-21

### Added

- **grok-4.20 family in the model catalog** — `grok-4.20-0309-reasoning`, `grok-4.20-0309-non-reasoning`, and `grok-4.20-multi-agent-0309` now register their real 2M-token context window in `Alloy.ModelMetadata`. Users who explicitly pass one of these model IDs to `Alloy.Provider.XAI` no longer hit the generic 200K fallback in the Compactor. Suffix patterns use regex so future `-MMDD` snapshots on the same family don't need a catalog update.
- **Provider typespec parity** — every provider that implements the `Alloy.Provider` behaviour now exposes a `@type config` and `@spec` on `complete/3` and `stream/4`. Users who run dialyzer get type-checking at call sites for all six providers (previously only `Codex`). No runtime change — this is purely a tooling-visibility improvement.

### Changed

- **`Alloy.Provider.XAI` docstring example** — now uses `grok-4.20-0309-reasoning` as the default-suggestion model (was `grok-4`) to reflect the current xAI API frontier.

## [0.10.2] - 2026-04-18

### Fixed

- **Codex subprocess leak on timeout** — `Alloy.Provider.Codex` now spawns codex via `Port.open` and explicitly kills the OS process (SIGTERM → 100ms grace → SIGKILL) when `:timeout_ms` trips. Previously `Task.shutdown(:brutal_kill)` closed the BEAM task but left the `/bin/sh` + `codex` subprocess tree running, leaking one OS process per timeout.
- **Codex temp-dir leak** — `prepare_paths/1` now cleans up `base_dir` when `prepare_codex_home/2` fails mid-setup. Previously the directory was orphaned on disk because the `try/after` cleanup in `complete/3` never ran.
- **Codex `arguments_json` decode** — falls back to a backslash-escape repair pass for invalid JSON escapes (`\d`, `\s`, `\p`, `\A`) that Codex occasionally emits from regex-containing code payloads. Decodes that previously failed with `Jason.DecodeError` now retry cleanly.
- **UTF-8-safe truncation** — `response_metadata.command_output` (and other truncated fields) no longer splits multi-byte codepoints mid-sequence. `truncate/2` now uses `String.slice/3` (character budget) rather than `binary_part/3` (byte budget).

### Changed

- **Codex provider typespecs** — added `@type config` and `@spec` to `complete/3` and `stream/4`; corrected invalid `Path.t()` references to `String.t()` (Elixir's `Path` module defines no `t/0` type).
- **Codex provider internals** — module attribute constants replace scattered magic numbers; `Enum.reduce_while/3` replaces two-pass tool-block parsing; `with`-guards and pattern-matching replace awkward conditional chains; catchall `emit_chunks/2` clause prevents `stream/4` crashes on unknown result shapes. Observable behaviour unchanged.

## [0.10.1] - 2026-04-13

### Fixed

- **Tool result truncation** — `max_result_chars` guard now uses character count (`String.length`) instead of byte count (`byte_size`). Multi-byte UTF-8 content (CJK, emoji) was triggering truncation earlier than intended.
- **Codex provider timeout** — `run_codex` now wraps `System.cmd` in a `Task` with a configurable timeout (default 120s). Previously a hung `codex exec` process could block the turn loop indefinitely.
- **Symlink path traversal** — `allowed_paths` validation now resolves symlinks recursively via `resolve_real_path`, preventing symlink-based escapes from allowed directories.
- **OpenAICompat nil guard** — added pattern match on `tc["function"]` before accessing arguments. Malformed tool call responses now return a graceful error instead of crashing the turn loop.
- **Testing helper** — `assert_tool_called` no longer raises `ArgumentError` when matching string keys against atom-keyed input maps. Uses `safe_atom_get` with rescue fallback.
- **Gemini streaming performance** — `parse_stream_parts` uses prepend+reverse instead of `++` accumulation, eliminating O(n²) behavior on large streaming responses.
- **Terminate ordering** — `State.cleanup` now runs after `on_shutdown` callback and `:session_end` middleware, ensuring consumers can access state before resources are freed.
- **Middleware docs** — documented that `{:edit, ...}`, `{:block, ...}`, and `{:halt, ...}` all stop the middleware chain immediately (first responder wins).

## [0.10.0] - 2026-04-12

### Added

- **Gemini provider** — `Alloy.Provider.Gemini` adds native Google Gemini support via the GenerateContent API, including streaming and tool calling.
- **xAI provider** — `Alloy.Provider.XAI` wraps the OpenAI Responses API with xAI defaults. Use `{Alloy.Provider.XAI, api_key: key, model: "grok-4"}` instead of manually setting `api_url`. Supports `web_search: true` and `x_search: true` for Grok's native search tools.
- **Codex provider** — `Alloy.Provider.Codex` adds OpenAI Codex support with ChatGPT authentication and session management.
- **Tool concurrency control** — tools can implement `concurrent?/0` to declare whether they are safe to run in parallel. The executor runs non-concurrent tools sequentially first, then concurrent tools in parallel. Default: `true`.
- **Tool result truncation** — tools can implement `max_result_chars/0` to cap output length. The executor truncates results that exceed the limit, keeping head and tail. Default: `:unlimited`.
- **Prompt-too-long recovery** — when a provider returns a "prompt is too long" error, Alloy forces context compaction and retries the turn once before failing.
- **`until_tool` option** — `Alloy.run("question", until_tool: "submit")` forces the loop to continue until the model calls the named tool. If the model signals `:end_turn` without calling it, the loop injects a continuation prompt and keeps going. Useful for structured output enforcement via tool schemas.
- **HITL `:edit` variant** — middleware can return `{:edit, modified_call}` from `:before_tool_call` to rewrite tool arguments before execution. The modified call must preserve the original `:id` and `:name`. This enables human-in-the-loop argument correction, policy-based input rewriting, and tool-call sanitization.

### Fixed

- **Duplicate `prompt_too_long?/1` clause** — removed dead code (identical function clause).

## [0.9.0] - 2026-03-22

### Breaking

- **`Compactor.maybe_compact/1` return type** — now returns `{:compacted | :unchanged, State.t()}` instead of a bare `State.t()`.
- **`Alloy.Context.TokenCounter` removed** — token estimation logic inlined into `Compactor`. Users who called `TokenCounter` directly should use `Compactor` functions instead.

### Added

- **`:after_compaction` middleware hook** — fires after context compaction occurs, allowing middleware to inspect or modify state post-compaction.
- **Reasoning/thinking block parsing in OpenAICompat** — DeepSeek and xAI reasoning models that return `reasoning_content` now produce `%{type: "thinking", thinking: text}` blocks instead of silently dropping the reasoning data. Works in both `complete/3` and streaming.
- **`extra_body` config for OpenAICompat** — pass `extra_body: %{"response_format" => ..., "temperature" => 0.7}` to inject arbitrary provider-specific parameters into the request. Merges last so it can override defaults.
- **Anthropic prompt caching** — pass `cache: true` in Anthropic provider config to automatically add `cache_control` breakpoints to the system prompt and last tool definition. Enables 60-90% input token cost savings. Default: `false` (no behavior change).
- **6 new telemetry events** — `[:alloy, :run, :start]`, `[:alloy, :run, :stop]`, `[:alloy, :turn, :start]`, `[:alloy, :turn, :stop]`, `[:alloy, :provider, :request]`, `[:alloy, :compaction, :done]` provide full lifecycle observability for OTEL, logging, or custom metrics.
- **xAI grok-4.1-fast model family** — dot-notation models (`grok-4.1-fast`, `grok-4.1-fast-reasoning`, `grok-4.1-fast-non-reasoning`) added to the model catalog.

### Fixed

- **grok-4 context window** — corrected from 256K to 2M tokens per xAI documentation.

## [0.8.0] - 2026-03-21

### Added

- **Cost guard** — `Alloy.run/2` now accepts `max_budget_cents: N` to cap agent spend. The loop halts with `:budget_exceeded` status when cumulative `estimated_cost_cents` exceeds the threshold. Default is `nil` (no limit).
- **One-shot streaming helper** — `Alloy.stream/3` provides a simpler API for streaming agent responses without managing a GenServer.

### Changed

- **Summary-first context compaction** — `Alloy.Context.Compactor` now preserves the first message, keeps a recent token-budgeted verbatim window, and replaces older context with a single structured handoff summary generated through the configured provider. Falls back to deterministic truncation if summary generation fails.
- **Grouped compaction settings** — `compaction: [reserve_tokens: N, keep_recent_tokens: N, fallback: :truncate]` makes context compaction behavior configurable.
- **Reserve-based compaction trigger** — compaction now starts when the conversation exceeds `max_tokens - reserve_tokens` instead of the previous fixed 90% threshold.

### Fixed

- **Bash tool timeout** — fixed timeout override not being respected when passed via tool input.

## [0.7.6] - 2026-03-19

### Added

- **Grouped compaction settings** — `Alloy.run/2` now accepts `compaction: [...]` with `reserve_tokens`, `keep_recent_tokens`, and `fallback`, making context compaction behavior configurable without replacing `max_tokens`.

### Changed

- **Summary-first context compaction** — `Alloy.Context.Compactor` now preserves the first message, keeps a recent token-budgeted verbatim window, and replaces older context with a single structured handoff summary generated through the configured provider.
- **Reserve-based compaction trigger** — compaction now starts when the conversation exceeds `max_tokens - reserve_tokens` instead of relying on the previous fixed 90% threshold.
- **Repeated compactions reuse the handoff summary** — Alloy updates the existing synthetic summary message on later compactions instead of stacking multiple summaries, while still falling back to deterministic truncation if summary generation fails.

## [0.7.5] - 2026-03-13

### Fixed

- **EchoTool test crashes (7 warnings)** — `EchoTool.execute/2` now accepts both string and atom key maps, fixing pattern-match failures when the test provider sends atom-keyed tool inputs.
- **Anthropic double-timeout** — removed the `Task.Supervisor` wrapper from `Anthropic.complete/3`. Req's `receive_timeout` (injected by `Retry.inject_receive_timeout`) already enforces the deadline — the Task added a redundant `yield + 5s` buffer. `complete/3` now calls `Req.request` directly, matching the OpenAI and OpenAICompat providers.
- **6 Dialyzer warnings resolved** — changed `pending_requests` typespec from `:queue.queue()` (opaque in OTP 28) to `term()` in `State`, replaced `when value == %{}` guard with `map_size/1` in `Result`, and removed unreachable `nil` clause in `maybe_put_metadata/3`.
- **`stringify_keys/1` safety** — added explicit `is_binary(k)` clause and `raise ArgumentError` for unexpected (non-atom, non-string) map keys instead of silent pass-through.

## [0.7.4] - 2026-03-06

### Added

- **Config-level model metadata overrides** — `Alloy.run/2` now accepts `:model_metadata_overrides`, allowing applications to override or extend model context windows used to derive compaction budgets without waiting for a library release.

### Changed

- **`max_tokens` defaults now follow provider models** — `Alloy.Agent.Config` derives the compaction budget from the configured provider `:model` when the catalog knows that model, re-derives it when models change via `Server.set_model/2`, and falls back to `200_000` only when no model metadata is available or when no model is configured.

## [0.7.3] - 2026-03-06

### Fixed

- **Hex publish workflow validation** — the release workflow no longer references `secrets.*` directly in step `if:` guards, so tag-triggered publish jobs can run again and dispatch the landing-site sync correctly.

### Changed

- **Release version bump** — republishes the provider/model refresh from `0.7.2` as a valid Hex release candidate after fixing the GitHub Actions publish workflow.

## [0.7.2] - 2026-03-06

### Added

- **xAI Responses path documented and tested** — `Alloy.Provider.OpenAI` now explicitly documents `api_url: "https://api.x.ai"` usage, and tests verify custom Responses API routing.
- **Current xAI model budgeting** — `TokenCounter` now recognizes current public xAI API model names including `grok-4`, `grok-4-fast-reasoning`, `grok-4-fast-non-reasoning`, `grok-4-1-fast-reasoning`, `grok-4-1-fast-non-reasoning`, and `grok-code-fast-1`.

### Changed

- **Provider/model docs refreshed** — README and provider moduledocs now point to current Anthropic 4.6, OpenAI GPT-5.4, Gemini 2.5/3 preview, and xAI model setups.
- **Anthropic code execution integration updated** — provider now uses `code_execution_20250825` and automatically merges required `anthropic-beta` headers with caller-supplied beta flags.
- **Publish workflow aligned with CI strictness** — release pipeline now runs `mix credo --strict` before publishing to Hex.pm.

### Fixed

- **OpenAI token budgets corrected** — `gpt-5`, `gpt-5.1`, and `gpt-5.2` context limits were updated to current published limits, preventing stale compaction thresholds.
- **xAI token budgets corrected** — `grok-4` now uses the documented 256k window, while Grok 4 fast and Grok 4.1 fast variants use the documented 2M window.
- **Anthropic model drift removed** — stale Anthropic alias examples were replaced with current `claude-opus-4-6`, `claude-sonnet-4-6`, and `claude-haiku-4-5` references.

## [0.7.1] - 2026-03-04

### Added

- **`Alloy.Result` struct** — typed, `Access`-compatible return value from `Alloy.run/2` and `Server.chat/3`. Single source of truth for the 8-field result contract. Implements `Access` behaviour for bracket-syntax backwards compatibility (`result[:text]`).
- **`Alloy.Result` in hex docs** — added to the Core group in the sidebar.

## [0.7.0] - 2026-03-04

### Added

- **Anthropic code execution support** — configure `code_execution: true` to enable Anthropic's server-side Python sandbox. Alloy handles `server_tool_use` / `server_tool_result` round-trips across Message, Executor, and Anthropic provider layers. The `code_execution_20250522` tool type is appended to the request body when enabled.
- **Optional tool callbacks** — `Alloy.Tool` behaviour gains `allowed_callers/0` and `result_type/0` as `@optional_callbacks`. Tools that don't implement them compile and work as before. Registry uses `function_exported?/3` to conditionally include metadata in tool definitions.
- **Structured tool results** — tools can return `{:ok, text, data}` 3-tuples. Text goes into the result block (what the model sees), structured data goes into `meta.structured_data` for programmatic consumption (e.g., by a code execution sandbox).
- **`allowed_callers` forwarding** — Anthropic provider includes `allowed_callers` in the tool definition sent to the API when present, enabling tools to declare whether they can be invoked from a code execution sandbox.
- **`server_tool_use`/`server_tool_result` token counting** — `TokenCounter` now estimates tokens for server tool blocks, preventing compaction from underestimating context size when code execution is in use.
- **Thinking block truncation in compactor** — thinking blocks exceeding the truncation length are sliced during compaction, reducing context size for extended thinking conversations.
- **`Testing.last_text/1` accepts `%State{}`** — delegates to `State.last_assistant_text/1` when given a `%State{}` struct, avoiding redundant reverse-search logic.

### Changed

- **`pending_requests` migrated to `:queue`** — `State.pending_requests` changed from a plain list to an Erlang `:queue` for O(1) enqueue/dequeue. All Server functions (`enqueue_pending_request`, `maybe_start_next_pending`, `remove_pending_request`, `health`) updated accordingly.
- **`agent_event` handler now async** — `handle_info({:agent_event, message})` now dispatches via `start_async_turn/3` (supervised Task) instead of running the Turn synchronously in the GenServer process. Prevents blocking the GenServer mailbox during long-running turns.
- **`handle_info` catchall logs unexpected messages** — the catch-all `handle_info/2` now logs via `Logger.debug/1` instead of silently discarding unknown messages.
- **`on_shutdown` crash logging** — `terminate/2` now logs `Logger.warning` with the exception and stacktrace when `on_shutdown` callbacks crash, instead of silently swallowing.
- **`:after_tool_request` middleware hook** — renamed from `:after_completion` in the tool-use code path. `:after_completion` now fires only on `:end_turn` (final response). `:after_tool_request` gates tool execution.
- **`within_budget?/3` accepts configurable ratio** — third parameter (default `0.9`) replaces the hardcoded 90% budget threshold.
- **SSE parser crash logging** — `SSE.parse_stream` now logs `Logger.warning` with exception message and stacktrace when an event handler crashes, instead of silently recovering.
- **Executor crash logging** — `Executor.run_tagged` now captures `__STACKTRACE__` and logs `Logger.warning` with tool name and stacktrace when a tool crashes.
- **Compactor refactor** — extracted `split_messages/2` to DRY message splitting between `compact/2` and `fire_on_compaction`. The `on_compaction` callback now receives the middle slice directly instead of the full message list + keep_recent count.
- **Executor result dispatch** — `result_block_fn/1` dispatches to `Message.tool_result_block/3` or `Message.server_tool_result_block/3` based on call type, so timeout and crash results also respect the call type.
- **`Message.tool_calls/1`** — now matches both `"tool_use"` and `"server_tool_use"` block types.
- **`Alloy.Tool.execute/2` return type** — widened to `{:ok, String.t()} | {:ok, String.t(), map()} | {:error, String.t()}`.

### Breaking

- **Middleware hook `:after_completion` no longer fires on tool-use responses** — use `:after_tool_request` for middleware that should gate tool execution. `:after_completion` now only fires on `:end_turn` (the model's final response).

## [0.6.0] - 2026-03-02

### Breaking

- **OpenAI provider migrated from Chat Completions to Responses API** — requests now use `/v1/responses` with `input` items and `output` parsing instead of `/v1/chat/completions` with `messages`/`choices`. Streaming uses native SSE handler instead of the removed `OpenAIStream` module. Tool definitions use flat `{type, name, description, parameters}` instead of nested `{type, function: {name, description, parameters}}`.

### Added

- **Fallback providers** — configure `fallback_providers: [{Provider, config}, ...]` to automatically try alternative providers when the primary fails. Respects deadline budgets and never switches mid-stream (once chunks are emitted, the turn sticks with that provider).
- **`on_compaction` callback** — configure `on_compaction: fn messages, state -> ... end` to extract facts from messages about to be compacted. Crash-safe: callback failures are logged but never prevent compaction.

### Fixed

- **Deduplicated `normalize_provider_config/1`** — removed redundant copy from `Turn` module; `Config` now handles all provider config normalization at construction time.
- **Quadratic list concatenation in OpenAI response parsing** — `parse_output_to_blocks/1` now uses O(n) prepend+reverse instead of O(n²) `acc ++ blocks`.
- **Double list traversal in compaction callback** — cached `length(rest)` to avoid traversing the message list twice.
- **Silent callback failures now logged** — `fire_on_compaction` logs `Logger.warning` on callback crashes instead of silently swallowing.

## [0.5.1] - 2026-03-01

### Added

- **Docs coverage gate** — added `mix docs.check` and wired it into CI and publish workflows to enforce `@moduledoc` and `@doc` coverage on public Alloy APIs.

### Fixed

- **Missing test helper docs** — added `@doc` for `Alloy.Testing.assert_tool_called/3` so public test helper macro docs are complete.

## [0.5.0] - 2026-03-01

### Breaking

- **`on_event` contract is now a versioned envelope map** — runtime stream/tool events are emitted as `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event:, payload:}` instead of tagged tuples.

  Migration example:
  - before: `{:text_delta, chunk}`
  - after: `%{v: 1, event: :text_delta, payload: chunk}`

### Added

- **Unified runtime event protocol** — `:text_delta`, `:thinking_delta`, `:tool_start`, and `:tool_end` now share the same event envelope with deterministic sequencing and correlation IDs.
- **Per-tool lifecycle telemetry** — added `[:alloy, :tool, :start]` and `[:alloy, :tool, :stop]` events with correlation, turn, tool identity, and timing metadata.
- **Per-run runtime telemetry envelope** — added `[:alloy, :event]` with normalized event metadata (`seq`, `event`, `correlation_id`, `turn`).
- **Async request cancellation API** — `Alloy.cancel_request/2` and `Alloy.Agent.Server.cancel_request/2` cancel both queued and in-flight async requests by `request_id`.
- **Bounded async backpressure** — `send_message/3` now supports bounded queuing via `max_pending` and explicit rejections (`:busy`, `:queue_full`).

### Changed

- **`send_message/3` result contract** — now returns `{:ok, request_id}` (instead of bare `:ok`) for robust caller correlation.
- **Async run correlation propagation** — async turns now set event correlation to the async `request_id` by default.
- **Result maps now include `tool_calls` metadata** — one-shot and server flows expose structured tool execution details (`duration_ms`, `error`, correlation and event sequence data).
- **Agent health payload** — now includes queue metrics (`pending_count`, `max_pending`).

## [0.4.3] - 2026-03-01

### Fixed

- **Jason.decode! crash on malformed tool args** — all 6 OpenAI-compatible providers now use `Jason.decode/1` instead of `Jason.decode!/1` when parsing model-produced tool call arguments. Invalid JSON returns `{:error, reason}` instead of crashing the agent GenServer.
- **Multimodal user messages silently dropped** — DeepSeek, Mistral, Ollama, OpenRouter, and XAI providers now correctly format text and image blocks in list-content user messages (previously the `_other -> nil` catch-all discarded them).
- **Tool executor preserves tool_use_id on timeout/crash** — timed-out or crashed tool calls now return the original tool_use_id (was `"unknown"`, which broke provider protocol state).
- **File.stream! on directories** — `Tool.Core.Read` now uses `File.regular?/1` instead of `File.exists?/1`, returning a clean error for directories instead of raising `File.Error`.
- **File.mkdir_p! in Write tool** — replaced with `File.mkdir_p/1` + structured error return on permission failure.
- **One-shot Alloy.run/2 status** — now sets `status: :running` before entering the turn loop, consistent with `Server.chat/3`. Middleware no longer sees `:idle` during execution.
- **Timeout floor overshoot** — `inject_receive_timeout/2` floor reduced from 5,000ms to 1,000ms to prevent HTTP requests from outliving the agent's overall deadline.
- **Scheduler stale callbacks** — `remove_job/2` no longer fires callbacks for in-flight tasks that complete after the job is removed.
- **Context.Discovery cross-platform** — `find_git_root/1` now terminates correctly on all OS filesystem roots (was hardcoded to `"/"`).
- **Message.text/1 consistency** — always returns `String.t()` (never `nil`). Empty text returns `""` instead of `nil`.
- **OpenAI missing usage key** — `parse_response` now handles responses without a `"usage"` field (zero-count fallback) instead of raising `FunctionClauseError`.
- **Google unknown part types** — `parse_parts_to_blocks` now skips unrecognised part shapes instead of raising.

### Changed

- **Credo strict + Dialyzer in CI** — `mix credo --strict` and `mix dialyzer` now run on every push/PR. All 34 pre-existing Credo violations resolved. PLT caching added.
- **Scratchpad Agent cleanup** — `State.cleanup/1` stops the scratchpad process in `terminate/2` and `try/after` blocks. Prevents process leak on crash.
- **O(1) message append** — `State` uses a prepend accumulator (`messages_new`) instead of `++` for O(1) append per turn, materialised at turn boundaries.
- **Float cost precision** — `Usage.estimate_cost/3` uses float division instead of `div/2` to avoid truncating sub-cent costs to zero.
- **Agent :idle status** — `State` default status changed from `:running` to `:idle`. Agents are only `:running` during active turn execution.

## [0.4.2] - 2026-02-28

### Added

- **Extended thinking (Anthropic)** — pass `extended_thinking: [budget_tokens: N]` in provider config to enable Claude's reasoning mode. Thinking blocks are parsed and stored as first-class content (`%{type: "thinking", thinking: text, signature: sig}`) for correct round-trip. Non-Anthropic providers silently ignore this opt.
- **`on_event` streaming callback** — pass `on_event: fn {:text_delta, t} | {:thinking_delta, t} -> :ok end` alongside `on_chunk` to receive tagged stream events. `on_chunk` remains unchanged for backward compatibility. Anthropic emits both `:text_delta` and `:thinking_delta`; all other providers emit only `:text_delta`.
- **Thinking token counting** — `TokenCounter.estimate_block_tokens/1` now counts thinking blocks toward context budget. Prevents compaction from underestimating context size when extended thinking is in use.

### Fixed

- `on_event` now validated as a 1-arity function at `stream_chat/4` call site — invalid values raise `ArgumentError` before reaching the provider instead of crashing deep in the pipeline.
- `extended_thinking: [budget_tokens: nil]` now raises `ArgumentError` immediately rather than sending `null` to the Anthropic API and receiving a cryptic HTTP 400.
- `stream_opts` can no longer override internal `:streaming` and `:on_chunk` flags via `Keyword.merge/2` (previously used `++` which could theoretically be shadowed by user opts).
- `on_event` emissions (thinking deltas) now correctly mark `chunks_emitted?` in the retry guard — previously, a retryable error after a thinking delta but before any text chunk would re-emit the thinking delta on retry.

## [0.4.1] - 2026-02-28

### Added

- **Unified streaming across all 8 providers** — `Alloy.Provider.SSE` now handles all transport-level SSE framing (CRLF normalisation, event boundary splitting, cross-chunk boundary handling). Anthropic, OpenAI, Google, Ollama, OpenRouter, xAI, DeepSeek, and Mistral all stream through the same pipeline. Each provider pattern-matches on parsed events. Adding a new streaming provider is ~50 lines.
- **`send_message/2`** — async non-blocking dispatch for `Alloy.Agent.Server`. Returns `:ok` immediately; the agent runs its Turn loop in a supervised `Task` and broadcasts the result via Phoenix.PubSub when done. Returns `{:error, :busy}` if the agent is mid-turn. Designed for Phoenix LiveView and background jobs that cannot block.
- **`Alloy.Application`** — proper OTP application entry point. Starts `Alloy.TaskSupervisor` (a `Task.Supervisor`) under `Alloy.Supervisor`. Required for `send_message/2`. Add `alloy` to your `extra_applications` list if using an umbrella.
- **Persistence behaviour** — `Alloy.Persistence` defines the formal contract for session persistence backends (`save_session/1`, `load_session/1`, `delete_session/1`, `list_sessions/0`). Alloy itself remains in-memory only — this behaviour is the seam for your own Ecto/SQLite/Redis adapter.

## [0.4.0] - 2026-02-26

### Added

- **Configurable timeouts** — `Server.chat/3`, `Server.stream_chat/4`, `Team.delegate/4`, `Team.broadcast/3`, `Team.handoff/4` all accept `opts \\ []` with `:timeout` (default 120s). Removes all `:infinity` timeouts for daemon safety.
- **Provider retry with backoff** — `Config` now has `max_retries: 3` and `retry_backoff_ms: 1_000`. Retries on HTTP 429/500/502/503/504 and `:timeout` with linear backoff. Non-retryable errors (e.g. 401) fail immediately.
- **Middleware loop halting** — middleware can return `{:halt, reason}` to stop the agent loop. State status becomes `:halted`. Works at all hook points: `before_completion`, `after_completion`, `after_tool_execution`, `on_error`.
- **Cost estimation** — `Usage.estimate_cost/3` computes `estimated_cost_cents` from token counts and per-million prices. `Usage.merge/2` accumulates cost across turns.
- **Streaming as opts** — `Turn.run_loop/2` now accepts `streaming: true, on_chunk: fn` opts directly, eliminating the config mutation hack in `Server.stream_chat`. `:streaming` field removed from `Config`.
- **Export session** — `Server.export_session/1` returns a `%Alloy.Session{}` with messages, usage, and metadata. Session ID sourced from `context[:session_id]` if set.
- **Graceful shutdown** — `Config` accepts `on_shutdown: fn session -> ... end`. Called in `Server.terminate/2`. Combined with `Process.flag(:trap_exit, true)` to ensure callback fires on supervisor shutdown.
- **Pluggable bash executor** — `Alloy.Tool.Core.Bash` checks `context[:bash_executor]` for a custom `(command, working_dir) -> {output, exit_code}` function. Enables Docker sandboxing without modifying Alloy.
- **Health check API** — `Server.health/1` returns `%{status, turns, message_count, usage, uptime_ms}` cheaply without touching the message loop.
- **PubSub integration** — `Alloy.PubSub` wrapper module. Agents can subscribe to topics (`subscribe: ["tasks:new"]`) and react to `{:agent_event, message}` messages. Results broadcast to `"agent:<agent_id>:responses"` using a stable ID (from `context[:session_id]` or auto-generated). `phoenix_pubsub ~> 2.1` is an optional dependency.

### Changed

- `Turn.run_loop/1` → `Turn.run_loop/2` with `opts \\ []` (backward compatible)
- `Config` struct: removed `:streaming`, added `:max_retries`, `:retry_backoff_ms`, `:on_shutdown`, `:pubsub`, `:subscribe`
- `State.status` type: added `:halted`
- `Middleware.call_result` type: added `{:halt, String.t()}`
- `Middleware.run/2` return type: `State.t() | {:halted, String.t()}`
- `phoenix_pubsub` dependency is now optional (users add it to their own `mix.exs`)
- `Team.init/1` returns `{:stop, reason}` instead of raising on agent start failure
- PubSub response topic uses stable `agent_id` (from `context[:session_id]` or auto-generated UUID) instead of volatile PID string
- All `Team` GenServer callbacks now have `@impl GenServer` annotation
- `Executor.execute_all/3` short-circuits middleware checks on halt via `Enum.reduce_while`

### Fixed

- `retryable?/1` now matches OpenAI's native 429 shape (`"rate_limit_exceeded: ..."`) — previously OpenAI rate-limit errors were never retried
- PubSub response topic now uses `effective_session_id/1` (same as `export_session/1`) — topic and session ID no longer diverge when `:session_start` middleware injects `context[:session_id]`
- `retryable?/1` pattern clauses matched tuple shapes that no provider ever returned — rewritten to match actual string error shapes from providers
- `Middleware.run_before_tool_call/2` missing `{:halt, reason}` clause caused `CaseClauseError`
- `Executor.execute_all/3` did not propagate `{:halted, reason}` from `run_before_tool_call`
- `Team.broadcast/3` crashed on `{:exit, reason}` from `Task.async_stream`
- `Team.handoff/4` timed out immediately when called with empty agent list (`timeout * 0 = 0`)
- `Server.terminate/2` used `catch :exit, _` which missed throws — changed to `catch _, _`
- `Server.init/1` did not handle `{:halted, reason}` from `:session_start` middleware
- `Server.handle_call(:chat/:stream_chat)` treated `:halted` status as success — now returns `{:error, result}`
- `Bash` tool missing `{:exit, reason}` clause in `Task.yield` result handling
- `Usage.estimate_cost/3` used float arithmetic causing accumulation errors — converted to integer math
- `Turn.run_loop/2` streaming fallback — `function_exported?/3` returned `false` for unloaded provider modules, silently falling back to non-streaming `complete/3`. Fixed with `Code.ensure_loaded/1` before the capability check.

## [0.3.0] - 2026-02-26

### Added

- `Alloy.Testing` module — ExUnit helpers for testing agents (`run_with_responses`, `assert_tool_called`, `refute_tool_called`, `last_text`, `tool_calls`)
- Usage examples in all 8 provider `@moduledoc` sections
- Expanded `@moduledoc` for all 4 built-in tool modules
- Grouped module sidebar in hex docs (Core, Providers, Tools, Context, Middleware, Advanced, Testing)
- Dialyzer passing with 0 errors

### Fixed

- Dialyzer errors caused by missing `:mix` in PLT (`plt_add_apps: [:mix]`)
- Compile warnings from module attributes in `@moduledoc` strings

## [0.2.0] - 2026-02-26

### Added

- Test coverage for `Session`, `Tool.resolve_path/2`, and `Tool.Executor` (26 new tests)
- Automated hex.pm publish pipeline via GitHub Actions (tag-triggered)

### Changed

- Updated all provider model references to current models (Feb 2026)
- Total test suite: 298 tests

## [0.1.0] - 2026-02-26

### Added

- Core agent loop (`Alloy.run/2`) with configurable max turns
- **8 LLM providers**: Anthropic, OpenAI, Google Gemini, Ollama, OpenRouter, xAI (Grok), DeepSeek, Mistral
- **5 built-in tools**: read, write, edit, bash, scratchpad
- GenServer agent wrapper (`Alloy.Agent.Server`) with supervision support
- Multi-agent teams (`Alloy.Team`) with delegate, broadcast, and handoff
- Streaming responses with provider-level SSE support
- Mid-session model switching
- Context compaction (automatic conversation summarization when approaching token limits)
- Context file auto-discovery (`.alloy/context/*.md`, 3-tier: global/git-root/cwd)
- Skills system (frontmatter parsing, discovery, placeholder expansion)
- Cron/heartbeat scheduler with overlap protection
- Middleware pipeline with telemetry integration
- Extension events (`:before_tool_call` with blocking, `:session_start`, `:session_end`)
- Interactive REPL via `mix alloy`
- Deterministic test provider for full TDD workflows

[0.9.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.9.0
[0.8.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.8.0
[0.7.6]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.6
[0.7.5]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.5
[0.7.4]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.4
[0.7.3]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.3
[0.7.2]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.2
[0.7.1]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.1
[0.7.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.7.0
[0.6.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.6.0
[0.5.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.5.0
[0.4.3]: https://github.com/alloy-ex/alloy/releases/tag/v0.4.3
[0.4.2]: https://github.com/alloy-ex/alloy/releases/tag/v0.4.2
[0.4.1]: https://github.com/alloy-ex/alloy/releases/tag/v0.4.1
[0.4.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.4.0
[0.3.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.3.0
[0.2.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.2.0
[0.1.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.1.0
