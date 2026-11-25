# Claude Code review — 2026-10-13

Historical first review. Findings were addressed in the subsequent review loop;
see [final verification and all-clear](REVIEW-claude-final-2026-10-13.md).

Completed read-only review of the local uncommitted patch using installed Claude Code 2.1.286 (`opus`; reported model `claude-opus-5-5`). No permission denials. No tests were rerun during this review. No source edits, commits, merges or GitHub comments were made.

Maintainer triage: source inspection confirms retry reuses the same provider configuration and saved session after a retryable failure. The claimed downstream false-completion outcome depends on Codex persistence behaviour and has not been reproduced. Missing-session recovery and first-valid-message selection are code-level concerns; real CLI traces are still needed to establish the streaming scenario. Sandbox precedence is not independently verified. Treat the private Req API concern as compatibility risk, not a demonstrated current failure. The prior passing validation does not resolve these review findings. Recommendation: hold the continuation/streaming patch pending targeted regressions and fixes.

## Reviewer report (verbatim)

# Review: uncommitted Alloy patch on `release/0.12.5`

I only read files. I did not run tests, edit anything, or post comments. I read all the untracked files, the two boundary documents, and the code paths involved (`Turn`, `Retry`, `State`, `Server`, `Compactor`, `Error`, `Req.Utils`).

## Bugs

### 1. Medium: a retried, failed or cancelled resume sends the same messages into a thread that already has them

- **Where:** `lib/alloy/provider/codex.ex:183-188`, `codex.ex:237-240`, `lib/alloy/provider/retry.ex:181-206`, `lib/alloy/provider/error.ex:52`, `lib/alloy/agent/turn.ex:191`, `lib/alloy/agent/server.ex:592-599`
- **What happens:** `provider_state` only changes when a call succeeds. A failed resume therefore leaves state pointing at the same thread with the same `count`. Codex has probably already saved the attempt to disk: the new user turn, and possibly a reply. I'm inferring this from how Codex records sessions; I didn't check it against Codex source.
- **Failure scenario:** with `persist_session: true`, a resumed call returns `tool_use` with `text: "Done"` and no tool calls. That gives `:malformed_reply`, which is now retryable. `Retry.do_provider_call` repeats the call with the same config, so it resumes the same thread. Codex now sees the same new messages twice, plus its own rejected "Done" reply. That nudges the model towards `end_turn "Done"`, which Alloy accepts as finished. This is exactly the false completion that the #55 fix is meant to stop.
- **Other triggers:** the same thing happens with `:timeout` retries. It also happens after a `Server` async cancel or crash: the pre-turn snapshot keeps user message U1, so the next chat resumes with U1 and U2 even though U1 is already in the thread.
- **Docs conflict:** this contradicts the ADR ("Uncertain resume failures are returned rather than automatically issuing a second request"). The CHANGELOG wording is only accurate in the narrow sense of not resending the *full* transcript.
- **Fix:** turn retryable errors from resumed calls into non-retryable ones (or a distinct kind). Alternatively, give the provider a way to invalidate the session when a call fails.
- **Missing test:** the test at `codex_test.exs:173` only covers exit status 1 (`:unknown`, which isn't retried). Add a loop-level test: persistent session, then a resumed call returning empty `tool_use`, then a valid reply, with `max_retries: 1`. Assert that the second call is not `exec resume <same id>` with the same delta, or that the error is surfaced.

### 2. Medium: once the saved thread is gone, a long-lived agent can never recover

- **Where:** `codex.ex:223-233`, `codex_session.ex:7-17`, `turn.ex:191`, `server.ex:430-435`
- **Failure scenario:** the host prunes old sessions in the persistent `CODEX_HOME`, as the moduledoc tells them to ("The caller owns retention"). Codex upgrades or corrupted saved sessions would have the same effect. From then on, every `Server.chat` resumes the missing thread and fails with `:unknown`.
  - The stored history prefix still matches, so the plan never falls back to a fresh session.
  - `provider_state` is never cleared on error.
  - `reset/1` clears messages but not `provider_state`. Recovery only works because the history becomes too short, and the conversation is lost.
- **Fix:** a "thread not found" failure is safe to retry, because Codex processed nothing. Detect it and either start fresh or return a typed error that clears the session. At minimum, document a recovery path.
- **Missing test:** a `Server` or loop run whose resume fails with "thread not found", followed by another chat. Assert that the next call isn't stuck retrying the dead thread.

### 3. Medium (depends on Codex behaviour): streaming commits to the *first* schema-valid answer, not the final one

- **Where:** `codex.ex:586-609` (scanning stops once `streamed_text` is set, at lines 587 and 595), `codex.ex:296-311`
- **Failure scenario:** a turn produces two `agent_message` items that both match the schema. For example, a short preamble before Codex's own read-only shell command, then the real answer.
  - The preamble is streamed to the user.
  - The final last message differs, so the call returns `:malformed_reply`.
  - Chunks were already emitted, so it isn't retried. The run fails.
  - `complete/3`, and streaming before this patch, would have succeeded with the final answer.
- **Scope:** this also affects default ephemeral streaming, not just `persist_session`. The test fake assumes that commentary is plain text ("Working..."). Whether Codex applies `--output-schema` to every response in a turn is not established either way.
- **Fix:** keep the last valid `agent_message` and emit it on `turn.completed`. That event still arrives before the process exits, and it removes the mismatch case entirely.
- **Missing test:** two valid `agent_message` events, the second matching the last message, then `turn.completed`. Expect exactly one chunk, holding the final text, and `{:ok, _}`.

### 4. Low: on resume, the caller's config overrides can override the read-only sandbox

- **Where:** `codex.ex:1007-1010` together with `codex.ex:994-998`
- **What happens:**
  - On a fresh call, `--sandbox read-only` is a command-line flag. In Codex it should take precedence over any `-c` setting.
  - On resume, read-only is set with `-c sandbox_mode="read-only"`, placed *before* the user's `config_overrides`. A later `-c` for the same key wins.
- **Result:** with `config_overrides: [~s(sandbox_mode="workspace-write")]`, a session would run read-only on the first call and writable on later ones. The overrides come from the host, not the model, so this is an inconsistency rather than an exploit.
- **Fix:** put the sandbox `-c` last, or reject `sandbox_mode` in overrides.
- **Missing test:** an argument-order assertion for the resume path.

### 5. Low: stream buffering is quadratic in line length

- **Where:** `codex.ex:589-592`
- **What happens:** each port chunk does `stream_buffer <> data` and then splits the whole buffer again.
- **Example:** in read-only mode Codex can still run commands like `cat` or `rg`. A multi-MB `command_execution` event line arriving in roughly 64 KB chunks gets re-copied and re-scanned O(n²/chunk) times in the task before the answer arrives. The timeout limits how long this can go on, but it's wasted CPU and doubled memory.
- **Fix:** split only the new `data` and keep the partial line as iodata.
- **Missing test:** none needed beyond a large-line stream.

### 6. Low: `Error` now depends on a private Req function

- **Where:** `error.ex:242`
- **What happens:** `Req.Utils` is marked `@moduledoc false`, so it's internal to Req. Alloy allows `req >= 0.6.1 and < 0.8.0`. If a minor Req release renames that function, any 429 or 503 with a date-form `Retry-After` header would raise `UndefinedFunctionError` while classifying the error.
- **Fix:** add a small local IMF-fixdate parser. The tests already pin the expected behaviour.

## Suggestions (optional, not bugs)

- **`provider_state` doesn't survive JSON:** `codex_session.ex:40-41` stores raw SHA-256 bytes under atom keys. A host saving `result.metadata.provider_state` as JSON gets a `Jason.EncodeError`. After a string-keyed round-trip, continuation silently falls back to fresh every time. Hex-encoding the hashes and accepting string keys would fix both.
- **Compaction creates unused saved transcripts:** the compactor's summary request goes through Retry with `persist_session: true` still set (`compactor.ex:590-593`). Each summary, and each fresh retry, writes a full-history Codex session to disk that will never be resumed. Forcing the summary request to stay ephemeral would avoid that.
- **Misleading metadata:** `{:fresh, :history_or_config_changed}` is also reported on the very first call, when there's no saved state (`codex_session.ex:15`). A separate `:no_session` reason would be clearer.
- **Untested fresh-session triggers:** the test at `codex_test.exs:111` checks that changing model, system prompt, home or overrides starts fresh. Changing `workdir`, the tool list or `codex_bin` is not tested, though `session_scope` covers them.

## Checked and found correct

- **Compactor:** atom- and string-keyed thinking and redacted-thinking blocks are filtered before serialization; visible text and tool evidence are kept.
- **Error and retry:** subscription-sharing exhaustion is classified as `:quota`. HTTP-date `Retry-After` works, past dates become 0, and a delay past the deadline is refused.
- **Empty `tool_use`:** `:malformed_reply` is retried within the attempt limit when nothing has streamed, and never retried after chunks were emitted.
- **Streaming cancellation and timeouts:** callbacks run in the caller. A throw or exit shuts the task down; the task's exit trap stops the process group and `in_temp_dir` cleans up. Chunk messages are flushed on timeout and cancel, and message ordering guarantees chunks are handled before the reply or the task's exit.
- **History fingerprint (0.13):** it ignores loop-added provenance because it hashes only role and content.
- **Session id validation:** `valid_id?` rejects ids starting with `-`, so an id can't be read as a command-line option.
- **Host examples:** they stay out of the Hex package (`files: lib …`), and there are no new runtime dependencies. Output capture uses exclusive, random, 0600 files and removes partial output on errors.
- **Release workflow:** the tag guard and `mix ci` gate are sound.

## Merge verdict

**Request changes.** The compaction, error-classification, `:malformed_reply`, workflow and example changes look ready to merge as they are.

`persist_session` continuation should not ship until #1 is fixed and #2 is fixed or documented with a recovery path. Fix #3 or verify it against a real Codex trace first, because it affects default streaming users. #4–#6 can follow later.

## Coverage limitations

- I didn't run `mix ci`, the 0.13 check script, or any real Codex CLI.
- Several points rest on my understanding of Codex, not on reading its source:
  - when sessions are written to disk (#1)
  - whether `--output-schema` applies to every response in a turn (#3)
  - `-c` versus `--sandbox` precedence (#4)
  - whether `exec resume` accepts these flags
- I didn't inspect the 0.13 snapshot (`32447cd`). `checks/codex_013.exs` isn't run in CI, so 0.13 compatibility is backed only by the local run described in the verification doc.
- I didn't verify that `Task.ignore/1` removes the task's leftover exit notification after a reply is received manually (`codex.ex:404`).
- I didn't review `Executor` internals beyond what the code-mode example relies on.
