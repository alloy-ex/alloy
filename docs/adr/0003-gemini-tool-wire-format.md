# Gemini tool wire format

Date: 2026-10-14

Status: Accepted

## Context

The paired Pi/Alloy live benchmark reproduced HTTP 400 when Alloy sent
`additionalProperties` through Gemini's OpenAPI-shaped `parameters` field.
Pi uses `parametersJsonSchema` for this API.

Alloy also decoded JSON-looking tool text into arbitrary function-response
fields. In a controlled development-case ablation, retaining that text under
an `output` envelope produced the expected next tool call in 3/3 attempts;
the original representation failed 3/3. Removing generated IDs or adjusting
system/auto fields alone did not fix that case. Both response shapes are legal
Google API inputs; this is a consistency and model-behavior choice, not a claim
that Google's API forbids arbitrary result fields.

## Decision

- Send tool input schemas using `parametersJsonSchema`.
- Preserve original tool-result text under `output` for success and `error`
  for failure. Do not reinterpret JSON-looking tool text.
- Keep public transcript content, structured tool metadata, call IDs, signatures,
  local validation, supervision and cancellation unchanged.
- Keep available-key enums and stop-after-final-tool policy application-owned.
  The benchmark tests those settings without making them global defaults.

## Consequences

Gemini request bodies change intentionally; the public tool contract does not.
This matches Pi's text-result envelope and reduces adapter code without adding
options, dependencies, persistence or orchestration. Release notes and native
provider regression tests document the behavior change. Final live confirmation
covered both task sets: 24/24 correct answers and clean executions for each engine. Evidence remains limited to the measured model and
task families; confirmation followed development and is not another blind holdout.

## References

- [Google FunctionDeclaration and FunctionResponse](https://ai.google.dev/api/generate-content)
- [Live benchmark protocol](https://github.com/alloy-ex/alloy/blob/v0.16.0/benchmarks/pi-agent/live/README.md)
- [Controlled ablation](https://github.com/alloy-ex/alloy/blob/v0.16.0/benchmarks/pi-agent/live/ablation-results/runs.json)
