# Composable loop controls

Date: 2026-10-13

Status: Accepted

## Context

Pi 1.x and other agent loops expose request preparation, tool validation,
and successful completion controls. Alloy needs these ordinary loop capabilities
without taking on the persistence and scheduling of a durable runtime.

## Decision

- Tool argument edits continue through later middleware. Block and halt remain
  terminal. A per-call result hook may replace content and structured data before
  publication, but cannot turn an execution failure into success.
- Keep required-key validation as the default. Opt-in schema validation uses the
  optional `ex_json_schema` adapter (drafts 4/6/7), without coercion or remote
  schema fetching. Invalid schemas are configuration errors. Resolved schemas
  are preflighted and cached in agent state before the first provider request
  (and refreshed before execution if middleware changes tools), reused only when
  their exact input schemas match. Each refresh retains only current tools;
  disabled validation clears the cache. No global cache, persistence or service
  is introduced. The cache is excluded from results and session metadata.
- `stop_after_tool` completes successfully after a selected successful tool,
  once the entire round settles. The first matching success in source order is
  the final output. Existing `until_tool` requirements still apply.
- `State.prepare/2` updates request inputs through existing `:before_completion`
  middleware, rebuilding tools and deriving model limits together. Explicit
  provider changes clear incompatible opaque provider state conservatively.
  Default compaction middleware is appended after caller middleware so it
  budgets prepared inputs. Explicit compactor placement remains respected.
- Transcript validation and missing-result repair are explicit utilities.
  Repair never executes tools and refuses ambiguous/orphaned results.
- `tool_concurrency` caps parallel execution per run, retaining the existing
  scheduler-count default and sequential tool barriers.
- `Alloy.Agent.Turn` owns the run's absolute monotonic deadline (`run_deadline = started + timeout_ms`)
  and passes it into `Alloy.Provider.Retry` (`:alloy_request_deadline`, kept
  outside `:req_options`), built-in HTTP/SSE and Codex runners, and
  `Alloy.Tool.Executor`. Termination precedence is: an already-completed final
  answer (`:end_turn` or successful `stop_after_tool`) is returned rather than
  discarded; otherwise an expired `run_deadline` fails the run with
  `%Alloy.Provider.Error{kind: :timeout}` ahead of `:max_turns`. Tool batches
  that have not started before `run_deadline` expires still emit matching error
  `tool_result` blocks (preserving `:before_tool_call` block reasons) so the
  transcript stays valid, without dispatching tools, emitting
  `:tool_start`/`:tool_end`, running `:after_tool_call`, or recording unstarted
  calls in `result.tool_calls`.

## Consequences

Argument-edit composition is an intentional behaviour change and must be called
out in release notes. Existing tuple tool results, ordinary completion, and
validation defaults remain supported. Schema validation adds no mandatory
runtime dependency. No new public step scheduler or single-tool execution API
is extracted. Durable recovery and multi-agent coordination remain outside core.

## References

- [Minimal core](0001-minimal-core-and-optional-capabilities.md)
- [Pi agent loop](https://github.com/earendil-works/pi/blob/a3a2ee8ec2cbdd41ce8994c570cc6707116d077a/packages/agent/src/agent-loop.ts)
- [AI SDK loop control](https://ai-sdk.dev/docs/agents/loop-control)
