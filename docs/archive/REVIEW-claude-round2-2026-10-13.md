# Claude Code review, round 2 — 2026-10-13

Completed read-only review, `is_error: false`, 40 turns, no permission denials. The shell wrapper failed after Claude returned because `status` is a read-only zsh variable; the complete successful Claude JSON result was inspected independently. Subsequent wrappers use `result`.

The duplicate-key finding was reproduced by a regression through `State.init` and `Turn.run_loop`: `Jason.encode!(..., maps: :strict)` raised `duplicate key: codex_session`. Canonical string-key state fixes this without changing the generic state merge. Recovery wording and timeout setup were corrected. The separate server regression is an intentional tracked-in-the-final-patch addition, not part of the 0.13 provider harness (0.13 removes Server). No staging/commit was authorized.

## Reviewer report (verbatim)

**Verdict: request changes.** I found one new Medium bug. It breaks one of the claimed fixes (JSON-safe continuation state) in a common way of storing that state. Every other finding from the earlier review is fixed or covered by the documented host recovery. Everything else is Low or optional.

I only read files: no edits, no commands, no tests run.

## Actionable findings

### 1. Medium: restoring state from JSON leaves two `codex_session` keys, and a stale one can resume the wrong turn

- **Where:**
  - `lib/alloy/provider/codex.ex:298` writes the state under an atom key, via `CodexSession.remember/3` at `codex_session.ex:39-46`.
  - `codex_session.ex:8` reads the atom key first, then the string key.
  - `lib/alloy/agent/state.ex:111` combines old and new state with `Map.merge`.
- **What happens:** a host restores `%{"codex_session" => s1}` from JSON. The next successful call merges in `%{codex_session: s2}`, so `provider_state` now holds both keys. In memory this is fine, because the atom key wins at `codex_session.ex:8`.
- **Why it breaks on save:**
  - The map is small, so the atom key is iterated first and the string key last.
  - Jason's default (naive) encoder writes both keys, with no duplicate check (`deps/jason/lib/encode.ex:186-200`). The result is `{"codex_session":S2,"codex_session":S1}`.
  - Postgres `jsonb` keeps the **last** duplicate key. Ecto `:map` fields are stored as `jsonb`, so it keeps the stale S1.
  - JS and Python parsers also keep the last value. Jason with `maps: :strict` raises instead.
  - Jason's own decoder happens to keep the first value (`decoder.ex:337-339`), which is why a pure Jason round trip hides this.
- **Concrete scenario:**
  1. Restart, then restore S1. Run one chat; the state now holds S2 under the atom key and S1 under the string key.
  2. Persist to a `jsonb` column, restart again, and S1 comes back.
  3. History is append-only, so S1's prefix hash still matches. Alloy runs `exec resume thread-1` and sends `messages[c1..]` again, but that thread already contains them.
- **Result:** the same silent duplicated-turn corruption that finding #1 of the earlier review was meant to prevent.
- **Fix:** write and read a single string key, `"codex_session"`. Fall back to the atom key only when the string key is absent. `Map.merge` then always replaces the restored entry. This also covers the `%{codex_session: nil}` written by ephemeral calls.
- **Missing test:** `codex_session_test.exs:6-15` only round-trips `CodexSession` on its own. Add a test that:
  1. starts `State.init` with a Jason-decoded `provider_state`;
  2. runs one resumed call through `Turn`;
  3. asserts `Jason.encode!(state.provider_state, maps: :strict)` succeeds;
  4. asserts the decoded state plans a resume at the **new** message count.

### 2. Low: the ADR describes the recovery rule more narrowly than the Server needs

- **Where:** ADR line 52 says the host must act "after a failed or cancelled resume". The relevant Server paths are `server.ex:497-512` (cancel) and `server.ex:592-602` (crash).
- **Scenario:**
  1. A resume succeeds and returns `tool_use`.
  2. The host calls `cancel_request` while tools run, or the async turn crashes.
  3. The Server keeps the pre-turn snapshot: user message U1 plus the old `provider_state`. Codex's thread, though, already holds U1 and the reply A1.
  4. A host following the ADR literally doesn't rotate the generation, since the resume itself succeeded. The next message resumes with `[U1, U2]`.
- **Fix:** the moduledoc at `codex.ex:78` ("any resume failure or cancellation") is closer. Align both documents on "after any failed, cancelled or crashed turn in a persistent session".

### 3. Low: possible flaky test at `test/alloy/provider/codex_test.exs:298-308`

- `timeout_ms: 500` also applies to the first call, which must **succeed** through `/bin/sh -lc`. That is a login shell (`codex.ex:576`), and on macOS it runs `/etc/profile` and `path_helper`.
- On a loaded CI runner, startup plus the script can exceed 500 ms. The test would then fail at `assert {:ok, first}`. Commit b1cd68c already fixed this kind of flake in two other tests.
- **Fix:** run the first call with the default timeout and use 500 ms only for the resumed call's config.

### 4. Low: `test/alloy/agent/codex_recovery_test.exs` may be left out of the commit

This file holds the tested `Server.set_model` recovery. It is not in the session-start git status, and `checks/codex_013.exs:27-29` doesn't load it either. Confirm it gets staged. The pasted diff shows this test inside `codex_test.exs`, but in the working tree it lives only in this separate file.

## Earlier findings: what happened to each

| Earlier finding | Status | Evidence |
|---|---|---|
| #1 failed resume retried into the same thread | **Fixed** | `codex.ex:204,209-217`. `:session_uncertain` is not in `@retryable` (`error.ex:53`). Tests: `codex_test.exs:181,206,285`. Server cancellation is left to the host, as documented at `codex.ex:76-86` (but see finding 2). |
| #2 no recovery after a lost thread | **Fixed (host action)** | The generation is part of the session scope (`codex.ex:227`). Tests: `codex_recovery_test.exs:7-52`, `codex_test.exs:244`. |
| #3 streaming committed to the first valid answer | **Fixed** | The last candidate is buffered and emitted on `turn.completed` (`codex.ex:631-643`); the final file is compared afterwards (`codex.ex:323-339`). Tests: `codex_test.exs:1121,1142,1234`. |
| #4 host overrides could beat the read-only sandbox on resume | **Fixed** | The sandbox `-c` comes after the overrides (`codex.ex:1043-1044,1057`). Test: `codex_test.exs:265`. |
| #5 quadratic line buffering | **Fixed** | Only the new data is split; the partial line is kept as iodata (`codex.ex:617-627`). Test: `codex_test.exs:1099`. |
| #6 dependency on private `Req.Utils` | **Fixed in library code** | Local IMF-fixdate parser at `error.ex:242-268`, with strict validation tests. The tests themselves still call `Req.Utils.format_http_date` (`error_test.exs:145`, `retry_test.exs:229`). |
| Suggestion: JSON-safe state | **Partly fixed** | The hashes are now hex and string keys are restored, but see finding 1. |
| Suggestion: summary calls saved sessions | **Fixed** | `compactor.ex:594`, with an assertion in the compactor test. |
| Suggestion: `:no_session` reason | **Fixed** | `codex_session.ex:12,14`. |
| Suggestion: untested fresh-session triggers | **Fixed** | Workdir, `codex_bin` and tool changes are now tested at `codex_test.exs:111-143`. |

I also checked these and found them correct:

- `String.Chars` is implemented for `%Error{}`, so interpolating it at `codex.ex:213` is safe.
- Chunk ordering, flushing and `Task.ignore` in `await_task` are correct.
- Thinking and redacted-thinking blocks are filtered from compaction summaries, for both key styles.
- Subscription-sharing exhaustion is classified as quota.
- The examples remain host-only, and the release workflow gate is sound.

## Optional suggestions

- **Thread growth on resume:** every resumed call resends the full instructions and every tool schema (`codex.ex:264-267`, `969-996`). Tools are part of the session fingerprint, so they never change within a session. With many tools, Codex's thread can grow much faster than Alloy's history. A context overflow on a resumed call then comes back as `:session_uncertain` (`codex.ex:209`) instead of triggering compaction. The documented generation rotation recovers from this, but worth noting or trimming.
- **Fallback providers can hide a failed resume:** fallbacks are your stated policy, so this is a documentation point only. If a fallback succeeds after a `:session_uncertain` (`retry.ex:48-49`), the host never sees the failure and can't know to rotate the generation.
- **Test name:** rename `codex_test.exs:265`. Read-only is applied *after* the host override and wins; "follows host overrides" reads as if the host override wins.
- **Tests and private API:** replace `Req.Utils.format_http_date` in the tests with `Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")`.
- **Default calls:** ephemeral calls now always return `provider_state: %{codex_session: nil}`, so `result.metadata.provider_state` appears for all default Codex users. You could return no state when `persist_session` is off.
- **Cheaper stream scan:** `stream_event` decodes every complete line, including multi-MB command output (`codex.ex:632`). A cheap substring check before decoding would avoid that.

## What this review did not cover

- I ran no tests, `mix ci` or `checks/codex_013.exs`, and used no real Codex CLI. Your independent CI run is the only current execution check.
- These depend on real Codex behaviour I couldn't verify:
  - whether `exec resume` accepts `--output-schema`, `--ignore-user-config` and `-` (prompt from stdin);
  - whether `-c sandbox_mode` takes effect on resume;
  - whether resume emits `thread.started` or replays earlier events;
  - whether `--output-schema` applies to intermediate agent messages.
- The Postgres `jsonb`, JS and Python last-key-wins behaviour in finding 1 comes from their documented semantics, not from a reproduction. The Jason encode and decode behaviour was confirmed by reading `deps/jason`.
- I didn't inspect the 0.13 snapshot. The checks script doesn't exercise Server recovery or the `State` merge path.
