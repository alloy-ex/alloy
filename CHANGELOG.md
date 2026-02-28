# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.3.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.3.0
[0.2.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.2.0
[0.1.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.1.0
