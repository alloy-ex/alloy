# Portable structured output (`:output_schema`)

Date: 2026-11-24

Status: Accepted

## Context

Alloy already supports tool-enforced structured outputs via `:until_tool` and
`:stop_after_tool`, which remain the right fit when structured output is one
step inside a tool-using workflow. However, every major model provider now
exposes a native JSON Schema output field (`output_config.format` on Anthropic,
`text.format` on OpenAI and xAI, `response_format` on OpenAI-compatible Chat
Completions, and `generationConfig.responseJsonSchema` on Gemini). Asking host
applications to translate the same schema into provider-specific `extra_body`
shapes — and to remember to strip it during compaction summaries and preserve
sibling `extra_body` keys like `output_config.effort` — duplicates wire-protocol
translation that belongs in Alloy (ADR-0001).

## Decision

Add a top-level `:output_schema` option to `Alloy.run/2`, `Alloy.stream/3`, and
`Alloy.Agent.State.prepare/2`, normalized once into `%Alloy.OutputSchema{}` and
decoded into `Alloy.Result.output`:

1. **Top-level ownership:** `:output_schema` is validated at startup in
   `Alloy.Agent.Config.from_opts/1` (and rejected inside provider config tuples
   so `Turn` always owns decoding and `State.prepare(state, output_schema: nil)`
   clears it cleanly). Providers consume the already-validated struct through an
   O(1) wire helper without re-encoding or re-resolving per request.
2. **Provider wire translation & `extra_body` preservation:** Each built-in
   HTTP provider translates `:output_schema` into its native wire field and
   merges one level deep on the enclosing container (`output_config`, `text`,
   `generationConfig`) so sibling caller `extra_body` keys (e.g.
   `output_config.effort`, `text.verbosity`, `generationConfig.temperature`) are
   preserved while explicit caller overrides for the schema key still win.
   `Codex` already uses `--output-schema` for its outer loop envelope, so it
   injects explicit JSON Schema instructions into its prompt and includes
   non-nil `:output_schema` in its session scope fingerprint (omitting it when
   `nil` to preserve 0.13 persisted sessions).
3. **Fallback & compaction integration:** `Alloy.Provider.Retry` forwards
   `:output_schema` into fallback provider configs so fallback calls still carry
   the schema. Compaction summary requests never carry `:output_schema` by
   construction: `Config.from_opts/1` rejects `:output_schema` in
   `provider_config`, and only `Turn.build_provider_config/1` injects
   `config.output_schema` on main completion turns (while `Compactor` strips
   raw `extra_body` schema keys and the Compactor test acts as a structural
   regression guard).
4. **Decoding, validation tiers, and terminal failure:** In `Turn.finish/1`
   (before `:after_completion`, skipped when `:stop_after_tool` finishes a run),
   Alloy concatenates the final assistant message's text blocks with `""` (not
   `"\n"`), decodes JSON, and validates it:
   - When optional `:ex_json_schema` is loaded and the schema uses Draft 4/6/7,
     full validation runs with the same local-only `$ref` SSRF guard used by
     `tool_validation: :schema`. Validation error output is bounded (first 10
     errors, capped at 1,000 bytes).
   - When `:ex_json_schema` is absent or the schema declares a newer dialect
     (Draft 2019-09 / 2020-12), Alloy falls back to **top-level `type` and
     `required` checks only**.
   - Invalid JSON, `:max_tokens`-truncated JSON (reported with an explicit
     truncation message), or schema violations fail the run terminally
     (`{:error, result}` with `status: :error`, `output: nil`, raw reply kept
     in `result.text`). Alloy does not run an automatic repair turn.
5. **Portability limits:** `:output_schema` is sent on every completion turn.
   Gemini models prior to Gemini 3 and some OpenAI-compatible servers reject
   combining tool declarations with native JSON Schema output; hosts targeting
   those endpoints should use `:until_tool` / `:stop_after_tool`, or drive a
   separate follow-up no-tools `Alloy.run/2` turn with `:output_schema`.
   OpenAI/xAI `strict: true` (the default) requires all properties in
   `"required"` and `"additionalProperties" => false` on every object; pass
   `%{schema: schema, strict: false}` to opt out.

## Consequences

- Hosts get portable structured outputs with zero new mandatory dependencies.
- `Alloy.OutputSchema` is a small public data struct in `Core` so middleware
  inspecting `state.config.output_schema` has a documented type.
- Repair loops, retry-on-schema-mismatch policies, and domain-specific struct
  casting remain application concerns.
