# Minimal core and optional capabilities

Date: 2026-10-13

Status: Accepted

## Context

The Pi comparison and review of PRs #54–58 identified useful capabilities,
but copying their implementations would expand the core and bypass some
existing execution guarantees. Alloy's 0.13 work is not yet on main.

## Decision

Keep protocol correctness, bounded retries, cancellation, and ordinary tool
execution guarantees in Alloy. Apply compaction fixes within its existing
boundary. Do not pursue feature parity with Pi.

Keep scripting runtimes, output persistence, discovery policy, and durable
sessions application-owned or in optional packages. Nested tool execution
must retain validation, middleware, events, and cancellation. Any new shared
execution API requires evidence from an application experiment and a separate
decision record.

Treat CLI continuation as provider-owned, opt-in persistence. Validate it
through the 0.13 loop before adoption; diagnostic output must not enter answer
text. Do not adopt the Claude CLI adapter as a prerequisite for Codex fixes.

## Consequences

Small correctness fixes can ship independently. PRs #54–58 are not merged
wholesale. Output capture and code mode need application-level experiments;
the Claude adapter remains deferred. Releases and publishing require separate
operational execution, not an inferred consequence of a local passing suite.

## Experiment outcome

The host experiment can compose the existing executor and middleware hooks
without extracting a new core execution API. Tests demonstrate required-key
validation, blocked writes, sequential ordering, structured results, parent
events, limits and cancellation. It accepts trusted host programs only; a
production interpreter still needs its own sandbox and resource policy.

Output capture consumes a lazy producer before truncation and writes through
a private, exclusive file under a byte quota. Artifact retention, producer
supervision and external VM lifecycle remain host responsibilities.

Codex continuation is explicitly enabled with `persist_session: true`; wire
history hashes exclude loop-added provenance. Failed resumed calls return
non-retryable `:session_uncertain` rather than automatically retrying the same
thread. Configured provider fallbacks retain their existing host-selected policy,
but persistent-session hosts must leave fallbacks empty: a successful fallback
would hide a resume failure and its stale continuation state.
After any failed, cancelled or crashed turn in a persistent session, including
cancellation during Alloy tools after a successful provider reply, the host must
change `:session_generation` before continuing. In 0.13, `State.prepare/2` can do this without discarding history;
this also recovers deleted/corrupt threads. No persistent invalidation registry
or durable session service is added to core. Continuations are single-caller,
not a concurrent shared session primitive.

Streaming waits for `turn.completed` before emitting the last validated
structured answer. Earlier valid-looking preambles cannot commit the answer;
commands/commentary remain diagnostics. Partial event lines are accumulated
as iodata rather than rescanned on every port chunk. Summary-only requests do
not persist CLI sessions. Saved continuation hashes are JSON-safe hexadecimal;
all continuation keys are strings, so restored state and new updates replace
the same entry in the existing shallow state merge. Atom-keyed pre-release
continuation data is not a supported persistence format.

## References

- [Pi comparison and PR dispositions](https://github.com/alloy-ex/alloy/blob/v0.16.0/docs/archive/REVIEW-pi-2026-10-13.md)
