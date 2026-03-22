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
mix test          # 533 tests, should all pass
```

## Development workflow

We use TDD. For every change:

1. Write a test that fails (`mix test path/to/test.exs`)
2. Implement the minimum code to make it pass
3. Run the full suite: `mix test`
4. Check formatting: `mix format`
5. Check style: `mix credo --strict`

All of these run automatically in CI and as pre-commit hooks.

## Pull requests

- Branch from `main`
- Keep changes focused — one feature or fix per PR
- Include tests for new functionality
- Update `CHANGELOG.md` under an `## [Unreleased]` section
- Ensure all quality gates pass before requesting review

## Quality gates

```bash
mix test                      # All tests pass
mix format --check-formatted  # No formatting issues
mix credo --strict            # No style warnings
mix dialyzer                  # No type errors
```

## Good first issues

Check the [good first issue](https://github.com/alloy-ex/alloy/labels/good%20first%20issue) label for approachable tasks.

## Questions?

Open a [discussion](https://github.com/alloy-ex/alloy/discussions) — we're happy to help with setup, architecture questions, or scoping a contribution.
