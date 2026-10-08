# Contributing to Alloy

Thanks for your interest in contributing! Alloy is a small, focused project and we want to keep it that way.

## Design boundary

Before proposing a feature, check the [design boundary](https://github.com/alloy-ex/alloy#design-boundary) in the README. Alloy owns the agent loop — provider wire formats, tool execution, context compaction, and telemetry. Sessions, persistence, memory, orchestration, and UI belong in your application layer.

Rule of thumb: if it needs a database table, product defaults, or tenancy logic, it doesn't belong here.

## Getting started

```bash
git clone https://github.com/alloy-ex/alloy.git
cd alloy
mix deps.get
mix test          # All tests should pass
```

The dev toolchain is pinned in `.tool-versions` (works with mise and asdf) to
match CI's primary matrix leg — Elixir 1.20 brings the gradual type checker,
so `mix compile --warnings-as-errors` locally catches what CI would. The
library itself still supports `~> 1.17`; the pin is for contributors, not
consumers.

Use a patched runtime for development and production: Elixir 1.18.5,
1.19.6, or 1.20.4 (or a later patch in those supported lines). The 1.17 CI
leg checks source compatibility; it is not a security-maintained runtime
recommendation. CI also covers OTP 29 and audits locked Hex dependencies.

## Development workflow

We use TDD. For every change:

1. Write a test that fails (`mix test path/to/test.exs`)
2. Implement the minimum code to make it pass
3. Run every gate: `mix ci`

`mix ci` is the same command CI runs on its lint legs. Format, compile and
Credo also run as pre-commit hooks.

## Pull requests

- Branch from `main`
- Keep changes focused — one feature or fix per PR
- Include tests for new functionality
- Update `CHANGELOG.md` under an `## [Unreleased]` section
- Ensure all quality gates pass before requesting review

## Quality gates

`mix ci` runs, in order:

```bash
mix format --check-formatted   # No formatting drift
mix deps.unlock --check-unused # No stale lockfile entries
mix hex.audit                  # No retired packages or security advisories
mix compile --warnings-as-errors --force  # Includes Elixir 1.20 type warnings
mix xref graph --format cycles --label compile-connected --fail-above 0
mix credo                      # strict: true, see .credo.exs for the policy
mix test --warnings-as-errors --cover    # Coverage floor in mix.exs
mix dialyzer                   # With :unmatched_returns, :missing_return, ...
```

Docs must also build cleanly: `MIX_ENV=dev mix docs --warnings-as-errors`.

Fix what a gate reports rather than suppressing it. If an exception is truly
needed, configure it in `.credo.exs` (or the relevant config) with a comment
explaining why, and mention it in the PR.

## Good first issues

Check the [good first issue](https://github.com/alloy-ex/alloy/labels/good%20first%20issue) label for approachable tasks.

## Questions?

Open a [discussion](https://github.com/alloy-ex/alloy/discussions) — we're happy to help with setup, architecture questions, or scoping a contribution.
