# Pi-inspired Alloy implementation verification

Date: 2026-10-13. Working branch: `release/0.12.5`, based on `b1cd68c`.
This records the pre-PR validation snapshot. No PR was merged, tag pushed, package
published, production app changed, or live Alloy provider request made in this work.
Claude Code was invoked separately for read-only patch reviews.
The [completed Claude review loop](REVIEW-claude-final-2026-10-13.md) records
the findings, regression fixes and final all-clear confirmation.

## Completion matrix

| Requirement | Implementation and evidence |
|---|---|
| Exclude reasoning from summary input | `Compactor` filters thinking/redacted-thinking before serialization. Regression covers atom/string keys and preserves visible text, tool calls and tool results. Existing live-history/signature tests remain. |
| Narrow retry improvements | `Error` recognizes subscription-sharing quota and HTTP-date retry delays. Tests distinguish quota from rate-limit type, reject invalid dates, clamp past dates, and exercise deadline refusal through `Retry`. |
| #55 malformed replies | Codex reports typed `:malformed_reply` for empty `tool_use`, even with nonempty text. Tests prove bounded retries and no false completion or streamed text. Host-specific tool discovery guidance is not embedded in core. |
| #56 continuation | Explicit `persist_session: true`, with an existing stable `workdir`; default/profile/copied-auth calls remain ephemeral. SHA-256 fingerprints of JSON-normalized wire history exclude provenance. Execution-scope/history changes invalidate continuation. Tests include a complete tool round through the 0.13 loop. |
| #56 streaming | The last validated structured answer is emitted at `turn.completed`; commands/commentary remain metadata. Real fake-executable tests split event bytes, require a callback before exit, detect final-response disagreement, stop subprocess children on callback cancellation, and prove no retry after emitted text followed by timeout. Failed resumes return non-retryable `:session_uncertain`. |
| #54 output capture | Optional lazy producer collector under `examples/minimal_host`, before truncation. Tests cover preserved middle output, byte quotas, synchronous writes, bounded display previews, unique private artifacts, binary data, failure cleanup and directory restrictions. No file-store subsystem added to core. |
| #57 code-mode experiment | Trusted host-program experiment reuses existing executor and middleware. Tests cover authority checks, required inputs, structured results, hooks, parent events, ordering, recursion exclusion, call limits, timeout, and active/pending child cancellation. No new core execution API or scripting dependency. |
| #58 | Deferred deliberately. No Claude CLI adapter added. |
| Minimal architecture | ADR `0001-minimal-core-and-optional-capabilities.md`; runtime dependencies unchanged. Examples are not in the Hex package. |
| Release readiness | Publication workflow now uses full CI, warning-free docs, matched primary toolchain, and a tested version/tag guard. Local Hex build includes the new provider helper and excludes host examples. External release gaps are recorded below. |

## Reproducible validation

Results after the Claude review fixes (including the strict-JSON state regression):

- `mix ci`: **994 tests passed**, **90.88%** library coverage, exit **0**;
  strict Credo found no issues and Dialyzer reported zero errors.
- Exported 0.13 compatibility run: **65 tests passed**, exit **0**.
- Warning-free docs, workflow lint, version/tag positive and negative checks,
  package build/content checks, and `git diff --check`: passed.
- The built package's Codex provider/helper match the working-tree files byte
  for byte, and the host examples are not shipped as core runtime modules.

Running the two suites concurrently initially revealed a shared ExUnit
temporary-directory collision. The compatibility harness now runs its tests
inside the exported snapshot; both concurrent suites then passed. No test was
disabled and the coverage floor was not lowered.

Local evidence logs: `/tmp/alloy-review-final-ci.log`,
`/tmp/alloy-review-013.log`, `/tmp/alloy-review-final-docs.log`, and
`/tmp/alloy-review-final-package.log`. Temporary logs are not durable artifacts; the
commands and regression tests below are the reproducible record.

```sh
mix ci
MIX_ENV=dev mix docs --warnings-as-errors
actionlint .github/workflows/publish.yml
mix hex.build --unpack --output /tmp/alloy-release-check
git diff --check
```

`mix ci` includes formatting, unused dependency detection, Hex security audit,
warning-free forced compilation, compile-cycle detection, strict Credo,
the full test suite with a 90% coverage floor, and Dialyzer. New example and
compatibility-check sources are included in formatting and linting. Host
experiment tests run in the ordinary suite.

The release-tag guard was exercised with matching `v0.12.5` and intentionally
mismatched `v0.0.0`: the former passed and the latter failed. `actionlint`
accepted the workflow. This does not claim that GitHub Actions was dispatched.

To verify Codex and the host experiments against the actual 0.13 source snapshot:

```sh
snapshot=$(mktemp -d)
git archive 32447cdc807ea491b124aa7861f34e3c7f369577 | tar -x -C "$snapshot"
ALLOY_013_SNAPSHOT="$snapshot" elixir -pa '_build/test/lib/*/ebin' checks/codex_013.exs
```

The check removes the current Alloy beam path, compiles exported 0.13 sources
with the current Codex provider/helper and error module, and runs real tests,
including a full tool round through 0.13 normalization/provenance stamping.
It does not replace or modify the user's separate 0.13 worktree. This is
targeted forward-compatibility evidence, not a claim to have run all of 0.13's
own test suite or removed 0.12's deprecated provider options.
The long-lived `Server` recovery regression runs in the main 0.12 suite under
`test/alloy/agent/codex_recovery_test.exs`; 0.13 removes `Alloy.Agent.Server`, so
that test is not part of the provider-only compatibility harness.

Local validation uses Elixir 1.20.2 / OTP 29.0.3. The remote CI matrix and real
provider/account behavior have not been exercised by these local fake-backend
tests. CLI argument support was checked against installed Codex 0.162.1.

## Intentional boundaries

- Code mode remains an experiment for trusted host code, **not a sandbox for
  model-generated Elixir**. A production interpreter needs its own isolation,
  memory/instruction limits and external-process cancellation protocol.
- Output capture does not launch shell processes or own tenant storage. Hosts
  must provide bounded producer chunks, process supervision, retrieval policy,
  retention, aggregate quotas and cleanup after abrupt termination.
- Persistent Codex sessions retain transcripts on disk. Hosts must isolate
  account homes and own retention. No silent retry-as-fresh after resume failure.
  Any failed, cancelled or crashed persistent-session turn requires a new host `:session_generation` before
  continuing; this recovers missing threads without discarding Alloy history.
  Persistent-session hosts must leave fallbacks empty so failures stay visible. Continuations
  must not be shared between concurrent callers.
- Streaming is structured-reply event delivery, not speculative token-by-token
  JSON decoding. The final reply must agree with text already emitted.
- No generic gateway-message regex, silent strict-tool downgrade, implicit
  image removal, durable session service, or interpreter runtime was added.

## External release reconciliation

Live GitHub/Hex checks during this work confirmed:

- [PR #51](https://github.com/alloy-ex/alloy/pull/51) brought the 0.12.5 baseline
  to main (`844b1cf7531b3425abab55862134ad5e6e557c83`).
- [PR #52](https://github.com/alloy-ex/alloy/pull/52) merged into
  **`release/0.12.5`**, not main. The 0.13 snapshot is
  `32447cdc807ea491b124aa7861f34e3c7f369577`.
- [Hex Alloy](https://hex.pm/packages/alloy) remains at **0.12.4**.
- [alloy_agent PR #2](https://github.com/alloy-ex/alloy_agent/pull/2) is open
  and draft; the `alloy_agent` Hex package lookup returns 404. Its stated
  prerequisites include publishing Alloy 0.12.5, refreshing the lockfile,
  dating its changelog and configuring the publishing secret.

Required external sequence: review/commit this patch, reconcile the 0.13
branch with main, choose the intended release version/date and target commit,
run the remote supported-runtime matrix, then authorize tagging/publication
and complete alloy_agent's prerequisites. Do not infer release completion
from a merged PR badge or from this local package build. These external
operations have not been executed or represented as complete.
