# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.2.0
[0.1.0]: https://github.com/alloy-ex/alloy/releases/tag/v0.1.0
