# Claude Code review, round 3 — 2026-10-13

Completed read-only review, exit 0, `is_error: false`, 20 turns, no permission denials. Verdict: all-clear with one nonblocking timeout-test concern. That timeout will be widened before final confirmation. Structured error causes remain an optional API expansion, not required for correctness. The latest independent compatibility run includes the new State/Turn strict-JSON regression and passed 65 tests against exported 0.13 sources.

## Reviewer report (verbatim)

## Round 3 verdict: all-clear

I found no bugs above Low. The round-2 duplicate-key bug is fixed, and none of the six original findings has come back. I only read files: I made no edits, ran no commands and ran no tests. Your CI and compatibility runs are the only execution evidence.

## Round-2 fix checked

- **Only string keys:**
  - `CodexSession.remember/3` (`codex_session.ex:31-40`) writes only `"codex_session"`, and `plan/3` (`:8`) reads only `"codex_session"`.
  - A search of `lib/`, `test/`, `examples/`, `checks/` and `docs/` finds no atom `:codex_session` outside the round-2 review text.
  - Ephemeral calls also write the string key (`codex.ex:287`). So `Map.merge` in `State.merge_provider_state` (`state.ex:111`) always replaces a restored entry rather than adding a second one.
- **Full loop path:** state flows `State.init` (`state.ex:75`) → `Turn.build_provider_config` (`turn.ex:370`) → `Codex` → `account_response` merge (`turn.ex:191`). The `:req_options` and `:on_event` that Turn injects are not part of the session scope, so they can't cause a needless fresh start.
- **Test coverage:** the test at `codex_test.exs:88` does what round 2 asked: it restores state from JSON, resumes through the loop, saves with `maps: :strict`, checks the count, resumes with only the new messages, then clears the state on an ephemeral call through the real merge.
- **Restored count:** the saved count of `length(history) + 1` matches `remember_session` hashing `messages ++ result.messages`.

## Other areas checked and found correct

- **Every resume failure becomes `:session_uncertain`:** this includes errors from `finish_stream` and timeouts. `:session_uncertain` is not retryable (`error.ex:53`), and the loop doesn't treat it as a context overflow.
- **Losing state after a turn is safe:** this covers refusals (state is merged but the messages are dropped), compaction and middleware that rewrites history. In every case the prefix hash no longer matches, so the next call starts fresh. None of these paths can resume and resend turns the thread already has.
- **Recovery after cancelling a fresh persistent call:** the stale state points to an older thread that doesn't contain the cancelled turn, so resuming it with the new messages is correct.
- **Streaming:**
  - Chunks are sent from the task process itself, so they always arrive before the task's reply.
  - The partial-line buffer is reversed into the right order (`codex.ex:627-632`).
  - If a later message is invalid, it clears the earlier candidate, so only the last valid reply streams.
  - Once a chunk has been emitted, `Retry` neither retries nor falls back (`retry.ex:45,182`).
- **Recovery docs:** the moduledoc (`codex.ex:76-92`) and the ADR (`0001…md:51-56`) now say the same thing: after any failed, cancelled or crashed turn, including cancellation during tools, rotate the generation, and leave fallbacks empty. `test/alloy/agent/codex_recovery_test.exs` tests the `Server.set_model` recovery.
- **Timeout test:** the first call gets 5 s, and only the resumed call drops to 500 ms.
- **Retry-After tests:** they use `Calendar.strftime` and no longer call `Req.Utils`.
- **Compactor:** it drops `:persist_session` and filters thinking blocks in both atom- and string-keyed forms.
- **Examples:** `output_capture.exs` and `code_mode.exs` still only use public host APIs and handle cleanup and limits correctly.

## Low and optional notes (none block release)

1. **Low, possible flaky test (`codex_test.exs:1201`):** `timeout_ms: 2_000` covers the `/bin/sh -lc` login-shell startup as well as the script. If startup on a loaded runner takes more than 2 s, the first attempt times out before it emits anything. The loop then retries, because a timeout is retryable when no chunk has been emitted, and the test fails at `invocations == "x"`. It's the same kind of flake that b1cd68c fixed, though the margin here is wider than the 500 ms one from round 2. One possible fix is to raise the timeout to around 5 s, since the script ends in `sleep 30`.
2. **Optional, `codex.ex:215-221`:** `:session_uncertain` keeps the underlying error only as text in the message. A host can't tell a lost thread from an auth, quota or missing-binary failure without parsing that string. That's harmless today, because rotating the generation is the right move in every case, but a structured field such as `:cause` would make telemetry and host decisions easier.
3. **Not verified by me:** `checks/codex_013.exs:27` loads `codex_test.exs`, which now includes the new `State.init`/`Turn.run_loop` merge test, against the 0.13 snapshot. Please confirm your latest independent batch included that compatibility check, not just `mix ci`. Also, `File.cd!(snapshot, …)` means tests tagged `@tag :tmp_dir` write into `<snapshot>/tmp`.

These still depend on how the real Codex CLI behaves, which I couldn't check: whether `exec resume` accepts `--output-schema` and `-c sandbox_mode`, and whether resume emits `thread.started` (the code falls back to the previous thread id if it doesn't).
