# Claude review loop — final verification

Date: 2026-10-13. Review baseline: `release/0.12.5` at `b1cd68c`.
The validation and review records below describe the pre-PR snapshot; the
reviewed changes are submitted from `codex/minimal-provider-hardening` against
`main`, whose `844b1cf` merge commit has the same baseline tree.

## Outcome

Claude Code's final verdict: **All-clear. I found nothing left to fix.**
Three full-patch read-only reviews (including the original review) were followed
by a focused fourth confirmation of the last test-only change. All completed
with successful Claude results and no tool permission denials. No source edits
were delegated to Claude. Findings were checked independently before fixing.

## Fixes and regression evidence

- Failed resumed calls return non-retryable `:session_uncertain`; malformed replies and real subprocess timeouts do not repeat the same resume.
- A host `:session_generation` change starts fresh without losing Alloy history. The 0.12 Server recovery test covers a missing thread. Documentation covers any failed, cancelled or crashed persistent turn, including cancellation during tools. Persistent-session hosts must leave fallback providers empty so failures remain visible.
- Streaming waits for `turn.completed` and emits only the last validated candidate. Regressions cover two schema-valid replies, missing completion events, final-file disagreements, cancellation and timeout after emission.
- Resume's read-only configuration follows host overrides. Partial event lines use iodata; a multi-megabyte diagnostic regression verifies answer isolation.
- HTTP-date retry parsing no longer depends on private Req APIs, including in tests.
- Continuation state has canonical string keys and hexadecimal hashes. The round-2 bug was reproduced as `Jason.EncodeError: duplicate key: codex_session` through the real State/Turn merge; strict JSON saving, subsequent resume deltas and ephemeral clearing now pass.
- Summary calls do not persist Codex sessions. Scope invalidation tests cover model, home, workdir, executable, prompt, overrides and tools.
- Startup-sensitive timeout tests retain all assertions with wider startup margins.

The first regression run reproduced six original failures; the second reproduced
the strict-JSON duplicate-key failure. These tests now pass. Optional structured
error causes remain deferred rather than expanding the shared API unnecessarily.

## Final validation

- `mix ci`: exit 0; **994 tests passed**, **90.88% coverage**; formatting, dependency/security audit, warning-free compilation, compile-cycle checks, strict Credo and Dialyzer passed.
- Exported 0.13 provider/host compatibility check: exit 0; **65 tests passed**, including the new State/Turn JSON regression. The separate 0.12 Server recovery test runs in the main suite because 0.13 removes Server.
- Warning-free docs, `actionlint`, `git diff --check`, and Hex package build passed. Packaged Codex modules match the working tree byte-for-byte.
- Both test suites were rerun after the final timeout-only change.

Execution logs: `/tmp/alloy-review-final-ci.log`, `/tmp/alloy-review-013.log`,
`/tmp/alloy-review-final-docs.log`, `/tmp/alloy-review-final-package.log`.
Reproduction commands and release boundaries are in
[implementation verification](VERIFICATION-pi-implementation.md).

## Scope and limits

This is local validation plus independent static review, not proof of live
Codex service behaviour or a successful remote release. Codex provider tests
use fake executables/runners; installed CLI argument help was inspected, but no
live Alloy model request or persisted service-side thread was exercised. The
remote CI toolchain matrix had not been run at review completion. No merge,
publication, deployment or GitHub comment was made during validation. PR
creation is a subsequent, separately authorized action.

## Review records

- [Original full review](REVIEW-claude-2026-10-13.md)
- [Second full review](REVIEW-claude-round2-2026-10-13.md)
- [Third full review](REVIEW-claude-round3-2026-10-13.md)

## Final Claude confirmation (verbatim)

**All-clear. I found nothing left to fix.**

**The round-3 Low finding is fixed** (`test/alloy/provider/codex_test.exs:1201-1231`):
- `timeout_ms` is now `5_000` (line 1222). That's the same value as the other startup-sensitive tests at lines 344 and 1259.
- The script still runs `sleep 30` (line 1209) after emitting the answer and `turn.completed`, so the timeout is still what ends the call.
- Every assertion is still there: `{:error, _}`, `assert_receive {:answer, "fake ok"}`, `refute_received {:answer, _}`, and `invocations == "x"` (lines 1227-1230). `max_retries: 2` and `retry_backoff_ms: 1` are unchanged, so the test would still catch a retry if one happened.

**The new timeout fits within the other limits:**
- **Turn timeout:** the test doesn't set `Alloy.stream`'s turn timeout, so it uses the 120 s default (`lib/alloy/agent/config.ex:163`). The turn deadline injected into `req_options` therefore can't cut the 5 s provider timeout short.
- **ExUnit limit:** nothing in `test_helper.exs` or the module overrides the per-test timeout, so it stays at the 60 s default. A passing run takes about 5 s. If the loop wrongly retried, the worst case is about 3 × 5 s ≈ 15 s, which is still well under 60 s, so the `invocations` assertion fails cleanly rather than the test timing out.
- **Mailbox check:** `assert_receive` has its default 100 ms window, but the answer is already in the mailbox before `Alloy.stream` returns, so that window doesn't matter.
- **Async:** the test is `async: true` with its own `tmp_dir`, so it doesn't share state with other tests.

**Deferred and not blocking:** the structured `:cause` on `:session_uncertain` (round-3 note 2) is an optional API addition, and leaving it out doesn't affect correctness.

**What this confirmation does and doesn't cover:**
- **Reading only:** I ran nothing. The `mix ci` result (994 tests, 90.88% coverage), the 65-test 0.13 compatibility run including the State/Turn strict-JSON test, the docs/lints/Dialyzer/package checks, and the reruns after this change are your reported results. I didn't see them myself.
- **No live Codex CLI:** every Codex test uses a fake shell script. Nothing here exercises the real `codex` binary, its event format, or real `resume` behaviour against a live thread.
- **Load not reproduced:** I didn't recreate a loaded runner. The 5 s margin follows the same reasoning as b1cd68c, but it hasn't been proven under load.
