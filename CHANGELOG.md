# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
