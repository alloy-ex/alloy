# Proposal: Fugu-style multi-model orchestration on Alloy

Status: Draft for discussion
Date: 2026-06-22
Branch: `claude/fugu-project-approach-31fjcm`

## Summary

[Sakana's Fugu](https://sakana.ai/fugu/) coordinates a *pool of diverse models*
— assigning roles (Thinker / Worker / Verifier, per TRINITY), routing work to
the right model per task (per Conductor), and exposing the whole thing behind a
single OpenAI-compatible endpoint — so that a team of models beats any single
frontier model.

This document proposes **building a Fugu-style coordinator as a new project on
top of Alloy, not inside `alloy` or `alloy_agent`.** It maps each Fugu
capability to the layer that should own it, sketches the module boundaries and
public API of the new package, and lays out a phased plan.

## Decision: new project, layered on the existing packages

Orchestration is explicitly out of scope for the existing packages — by their
own stated boundaries:

- **`alloy`** README, Design Boundary: lists *"multi-agent orchestration"* among
  the things Alloy refuses to be, and states coordination *"belong[s] in your
  application layer."*
- **`alloy_agent`** README: it is *"the supervised process wrapper around
  `Alloy.run/2`"* — the runtime for **one** conversation's state, not a
  coordinator of a heterogeneous pool.
- **`docs/recipes/sub-agents.md`** ends with the verdict: *"If you find yourself
  wanting routing, shared state, and inter-agent messaging, you've outgrown this
  recipe — build that layer in your application where it belongs."* Fugu **is**
  routing + shared state + inter-agent messaging.

Putting Fugu into `alloy` would reintroduce the "everything framework" the
package exists to reject. Putting it into `alloy_agent` would re-expand the
single-session runtime along a second axis (member coordination) the split was
designed to keep apart. So: a **new package** — working name `alloy_orchestra`
— that *consumes* both.

This mirrors the existing ecosystem shape: **Anvil** is the reference Phoenix
*application* on Alloy; orchestration is likewise an application/library layer,
not the harness.

## Execution model: subscription-backed CLI by default, metered API opt-in

A coordinator that fans a task out across a pool multiplies token spend by the
number of members and turns. Billing that against metered provider **APIs** is
the expensive way to run Fugu. The cheap way — and the **default** for this
design — is to back pool members with **coding-agent CLIs running in
programmatic / headless mode**, which execute against the operator's
**subscription plan** (ChatGPT, Claude, Gemini) rather than per-token API
billing.

Alloy already proves the pattern: **`Alloy.Provider.Codex`** drives
`codex exec` against a ChatGPT plan, treating the CLI as a structured
completion backend while Alloy keeps the tool loop. The same shape extends to a
**`claude` CLI** provider (`claude -p`, Claude plan) and a **Gemini CLI**
provider — each is just *provider wire-format translation*, which by Alloy's
own boundary belongs **in `alloy`**, not the orchestrator.

**Principle:** pool members default to a subscription-backed CLI backend.
A member only talks to a metered API when **explicitly flagged**
(`api: true`, or by naming an API provider directly). This keeps fan-out cheap
by default and makes every paid-API member a deliberate, visible choice.

Consequences the design must carry:

- **`backend: :cli` is the default** on `Orchestra.Member`; `backend: :api`
  (or an explicit `api: true`) is opt-in per member.
- **Rate limits replace dollar budgets for CLI members.** `codex exec` reports
  zero structured token usage, so `max_budget_cents` is meaningless for CLI
  backends — they're bounded by the subscription's request/rate limits, not
  cents. The coordinator must treat concurrency limits and retry/backoff (not
  cost caps) as the governing constraint for CLI members, and reserve
  `max_budget_cents` accounting for the explicitly-flagged API members.
- **Auth is local CLI login state**, not keys in config (Codex reads
  `~/.codex/auth.json`; the others their own login state). The pool config
  references a backend + model, not an `api_key`, unless a member is flagged
  for API use.

## Capability → layer mapping

| Fugu capability | Owning layer | Mechanism it reuses |
|---|---|---|
| Subscription-backed CLI member (default) | `alloy` | `Alloy.Provider.Codex` (`codex exec`); proposed `claude`/Gemini CLI providers |
| Metered API member (opt-in, explicitly flagged) | `alloy` | API providers (`Anthropic`, `OpenAI`, `Gemini`, `xAI`, `OpenAICompat`) |
| Diverse provider/model pool, one-line swap | `alloy` (done) | uniform `Alloy.Provider` behaviour across CLI + API backends |
| Each pool member as a supervised, stateful agent | `alloy_agent` | `AlloyAgent.Server` (one per member); `max_budget_cents` for API members only |
| Parallel fan-out of members in a turn | `alloy` | `Task.Supervisor` + tool `concurrent?/0` (bounded by CLI rate limits) |
| Model selection / routing (Conductor) | **new** | `Orchestra.Router` behaviour |
| Role assignment + multi-turn coordination (TRINITY) | **new** | `Orchestra.Coordinator` GenServer |
| Shared scratch state between members | **new** | coordinator-owned blackboard |
| OpenAI-compatible `/v1/chat/completions` endpoint | **new** (Plug/Phoenix) | thin serving layer, like Anvil |
| Learned/evolved coordination policy (RL/evo) | **separate** (out of scope) | offline training pipeline |

Note the last row: TRINITY/Conductor's quality comes from a **learned** policy
(evolution + RL). This proposal delivers the *mechanism* to run a coordinator
with hand-written or heuristic policies. Reproducing Fugu's benchmark claims
additionally requires the training side, which is a much larger, separate
effort and is explicitly **not** in scope here.

## Proposed package: `alloy_orchestra`

### Dependencies

```elixir
{:alloy, "~> 0.13"},
{:alloy_agent, "~> 0.1"}
```

### Core abstractions

1. **`Orchestra.Member`** — a named entry in the pool: a role, a backend
   (CLI by default), a model, a system prompt, a toolset, and caps. The
   `provider` it resolves to is a normal `Alloy.Provider` tuple either way —
   the `backend` flag just selects CLI vs. API.

   ```elixir
   # Default: subscription-backed CLI member (no api_key, login state is local)
   %Orchestra.Member{
     id: :verifier,
     role: :verifier,                  # :thinker | :worker | :verifier | custom
     backend: :cli,                    # default — resolves to Alloy.Provider.Codex / claude CLI / etc.
     model: "gpt-5.4",
     tools: [Alloy.Tool.Core.Read],
     system_prompt: "You verify candidate answers. ...",
     caps: [max_turns: 6, timeout_ms: 60_000]   # rate-limited, not cost-capped
   }

   # Opt-in: explicitly-flagged metered API member
   %Orchestra.Member{
     id: :worker,
     role: :worker,
     backend: :api,                    # explicit flag — this member bills the API
     provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-opus-4-6"},
     tools: [Alloy.Tool.Core.Read],
     caps: [max_turns: 6, timeout_ms: 60_000, max_budget_cents: 25]
   }
   ```

2. **`Orchestra.Router`** (behaviour) — the Conductor seam. Given a task and the
   pool, decide which members activate and in what role. Default
   implementations: `Router.Static` (fixed roster) and `Router.Heuristic`
   (cheap classifier → roster). A learned router can implement the same
   behaviour later without touching the coordinator.

   ```elixir
   @callback select(task :: Orchestra.Task.t(), pool :: [Orchestra.Member.t()]) ::
               {:ok, [Orchestra.Assignment.t()]} | {:error, term()}
   ```

3. **`Orchestra.Coordinator`** (GenServer) — the TRINITY seam. Owns a run:
   asks the router for assignments, drives members across turns, holds the
   shared blackboard, applies a `Strategy`, and produces the final answer.
   Members are executed as either `Alloy.run/2` calls (stateless, fanned out
   via `Task.Supervisor`) or `AlloyAgent.Server` processes (stateful, when a
   member must persist across turns).

4. **`Orchestra.Strategy`** (behaviour) — the coordination pattern: e.g.
   `Strategy.ThinkWorkVerify` (TRINITY-shaped), `Strategy.Debate`,
   `Strategy.BestOfN`. Strategies are pure orchestration over members +
   blackboard; they hold no provider logic.

5. **`Orchestra.run/2`** — convenience entry mirroring `Alloy.run/2`:

   ```elixir
   {:ok, result} =
     Orchestra.run("Refactor lib/foo.ex and prove the change is safe",
       pool: pool,
       router: Orchestra.Router.Heuristic,
       strategy: Orchestra.Strategy.ThinkWorkVerify,
       max_budget_cents: 200       # applies only to explicitly-flagged API members
     )

   result.text          # final coordinated answer
   result.transcript    # per-member messages/usage for observability
   result.usage         # summed across members
   ```

### Why this is a strong fit for Alloy

The hard parts of a Fugu clone elsewhere — N providers behind one interface,
parallel execution, crash isolation, per-member cost caps — are already
primitives here: `OpenAICompat`, `Task.Supervisor` fan-out, supervised
processes, and `max_budget_cents`. The coordinator is mostly policy glue on top
of those. It is close to an ideal showcase of Alloy's "harness, not framework"
thesis.

### Budget & rate-limit accounting note

Two regimes, because members run on two kinds of backend:

- **CLI members (default)** bill against a subscription, not tokens. `codex
  exec` reports zero structured usage, so `max_budget_cents` is meaningless
  here — the binding constraint is the subscription's **rate/request limits**.
  The coordinator governs CLI members with concurrency limits and
  retry/backoff, not dollar caps.
- **API members (opt-in)** are metered. Per `docs/recipes/sub-agents.md`, a
  parent's `max_budget_cents` does **not** see tokens spent inside a child
  `Alloy.run/2`, so the coordinator does **combined accounting itself**: cap
  each API member individually and sum `result.usage` to enforce the team
  budget. This is a first-class coordinator responsibility, not inherited for
  free.

Mixing the two in one pool is expected (e.g. cheap CLI thinkers + one flagged
API verifier); the coordinator applies whichever regime each member declares.

## OpenAI-compatible endpoint (Phase 4)

A thin Plug app exposing `POST /v1/chat/completions` that maps an incoming
request to `Orchestra.run/2` and serializes the result back into OpenAI
response shape (including a streaming `text/event-stream` variant backed by
`Alloy.stream/3` on the final-answer member). This is the "single API
interface" Fugu advertises. It is a serving/application concern (config, auth,
observability) and stays in the new package — never in `alloy`.

## Phased plan

- **Phase 0 — Spike (this proposal).** Validate the layering against the
  existing design boundaries. ✅ captured here. *Deliverable: this doc + draft PR.*

- **Phase 1 — Core skeleton.** New `alloy_orchestra` package (umbrella sibling
  or standalone repo). Define `Member` (`backend: :cli` default), `Assignment`,
  `Task`, `Result` structs; `Router` and `Strategy` behaviours; `Router.Static`;
  `Strategy.BestOfN` (the simplest fan-out-and-pick strategy). `Orchestra.run/2`
  executing members via `Alloy.run/2` with `Task.Supervisor` fan-out, resolving
  CLI members to `Alloy.Provider.Codex`. Per-regime accounting (rate limits for
  CLI, summed budget for flagged API members).
  *Acceptance: a 3-member best-of-N run on CLI backends returns a coordinated
  answer; an API-flagged member enforces its `max_budget_cents`.*

- **Phase 1b — CLI providers (lands in `alloy`, not the orchestrator).** The
  default execution model needs more than the existing `Codex` provider. Add a
  `claude` CLI provider (`claude -p`) and a Gemini CLI provider following the
  `Alloy.Provider.Codex` shape — CLI as a structured completion backend, Alloy
  keeps the loop. This is *provider wire-format translation*, which Alloy's
  Design Boundary explicitly places **in `alloy`**. The orchestrator stays
  provider-agnostic; it just selects among them. *Acceptance: each CLI provider
  satisfies the `Alloy.Provider` behaviour and round-trips a tool call against
  local login state.*

- **Phase 2 — TRINITY-shaped strategy.** `Strategy.ThinkWorkVerify`: thinker
  drafts, worker executes (tools), verifier critiques, loop until verifier
  passes or turn cap. Shared blackboard. Stateful members via
  `AlloyAgent.Server` where persistence across turns matters.
  *Acceptance: verify loop demonstrably catches and revises a wrong first
  answer on a fixture task.*

- **Phase 3 — Routing (Conductor seam).** `Router.Heuristic` — a cheap
  classifier (small/fast model via Alloy) picks roster + roles per task type
  (coding / reasoning / scientific). Pluggable so a learned router can drop in
  later. *Acceptance: router measurably changes the roster across task classes;
  behaviour is swappable without coordinator changes.*

- **Phase 4 — OpenAI-compatible endpoint.** Plug app, non-streaming then
  streaming. Member-pool config + provider exclusion (Fugu's privacy/compliance
  "exclude providers" feature is just filtering the pool). *Acceptance: an
  OpenAI client library can call the endpoint and get a coordinated completion.*

- **Phase 5 — Telemetry & evaluation harness.** Per-member + per-run telemetry
  (reuse Alloy's `[:alloy, ...]` events; add `[:orchestra, ...]`). A small
  benchmark runner to compare coordinated vs. single-model on a fixture suite —
  the honest measuring stick for whether coordination is paying for itself.

- **Out of scope (separate effort): learned policies.** Evolution/RL training of
  routers and strategies (the actual TRINITY/Conductor research). The behaviours
  above are the integration seam for it; the training pipeline is its own
  project.

## Open questions

1. **Repo shape** — standalone `alloy_orchestra` repo, or a package inside an
   umbrella alongside Anvil? (Lean: standalone, published to Hex, to keep the
   layering legible.)
2. **Stateless vs. stateful members by default** — `Alloy.run/2` per turn
   (simple, cheap, no cross-turn memory) vs. one `AlloyAgent.Server` per member
   (persistent, supervised). Proposal: stateless by default, opt into stateful
   per member when a role needs continuity.
3. **Endpoint framework** — bare Plug vs. Phoenix. (Lean: Plug; the endpoint is
   thin and Phoenix pulls in more than the serving layer needs.)
4. **Which CLI providers to add to `alloy`** — `codex` exists; `claude -p` and
   Gemini CLI are the obvious next two. Any others (e.g. open-weight runners)?
5. **CLI rate-limit governance** — where the concurrency/backoff policy for
   subscription backends lives: per-member caps in the orchestrator, or a shared
   limiter. (Lean: a coordinator-level limiter keyed by backend identity.)
6. **Naming** — `alloy_orchestra` vs. `alloy_ensemble` vs. `conductor`.

## Next step

If the layering and package shape are agreed, Phase 1 is a self-contained chunk
I can scaffold (package skeleton, structs, behaviours, `Router.Static`,
`Strategy.BestOfN`, `Orchestra.run/2`, tests) on this branch.
