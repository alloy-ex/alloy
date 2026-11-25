# Upgrading to 0.14

Alloy 0.14 hardens run deadlines, worker supervision, provider wire parsing,
and tool/config validation, and adds first-class portable `:output_schema`
structured outputs. Most callers upgrade with no changes; review the breaking
contracts below before bumping.

## 1. Run-wide `:timeout_ms` enforcement (and `:infinity` opt-out)

Previously, actively streaming HTTP/SSE responses and long tool batches could
run past `:timeout_ms` (default `120_000` ms). In 0.14, `:timeout_ms` bounds the
entire run — stalled or trickling HTTP/SSE streams, retries, tool batches, and
turn boundaries.

- **Long-running agents (> 2 minutes):** Raise `:timeout_ms` or pass
  `timeout_ms: :infinity` to disable the run-level deadline. Under `:infinity`,
  per-tool `:tool_timeout`, Codex's per-invocation `:timeout_ms`, and a 60s
  retry-delay ceiling still apply, while HTTP requests default to
  `receive_timeout: :infinity` (pass `req_options: [receive_timeout: ms]` if
  you want a per-request idle/socket timeout).
- **Outer `Task.await/2` buffer:** Add ~2–5 seconds of buffer above `:timeout_ms`
  so Alloy's worker/subprocess teardown can return a clean `:timeout` result.
- **Completed answers preserved:** Already-completed `:end_turn` answers and
  `stop_after_tool` results are returned rather than discarded on timeout;
  otherwise an expired deadline fails with `:timeout` ahead of `:max_turns`.

## 2. Supervised HTTP/SSE workers (`Alloy.TaskSupervisor`)

When `:timeout_ms` is finite (the default), built-in HTTP/SSE providers execute
`Req` inside a linked worker under `Alloy.TaskSupervisor` so caller death,
cancellation, and deadlines stop requests immediately.

- Ensure the `:alloy` application is started (standard in Mix apps; in
  standalone scripts call `Application.ensure_all_started(:alloy)`).
- `Logger.metadata/0`, OpenTelemetry context (`:"$__current_otel_ctx"`), and
  `$callers` are propagated automatically. Custom `Req` test plugs that call
  `send(self(), ...)` now run inside the worker process — capture `test_pid = self()`
  in a closure before defining the plug.

## 3. New `Alloy.Provider.Error` kinds: `:protocol_error` and `:shutdown`

- `:protocol_error` (**non-retryable**) is now used for deterministic wire-schema
  contract violations (valid non-object JSON replies, malformed
  choices/candidates/content/blocks, missing required tool-call `id`/`name`,
  mismatched Anthropic SSE deltas). `:malformed_reply` (**retryable**) remains
  for transient JSON/SSE corruption and model-generated invalid tool-argument JSON.
- `:shutdown` (**non-retryable**, skips retries and fallback providers) is
  returned when a request is interrupted by supervisor shutdown (including
  resumed Codex sessions, where you should still rotate `:session_generation`).
- Update any exhaustive `case error.kind` matches to handle `:protocol_error`
  and `:shutdown`.

## 4. Custom providers & `Alloy.Provider.decode_body/1`

- When `:timeout_ms` is finite, Alloy passes internal `:alloy_request_deadline`
  in `provider_config`. When the caller sets `:output_schema`, Alloy also
  injects `:output_schema` (an `Alloy.OutputSchema.t()` struct; omitted when
  unset). Custom providers using strict validators (`Keyword.validate!/2`,
  `NimbleOptions`) should tolerate unknown `:alloy_*` keys and `:output_schema`,
  and custom providers that want to support `:output_schema` must translate
  `config.output_schema.schema` into their wire format (otherwise the run fails
  terminally at JSON decode unless the model happened to emit conforming JSON).
- `Alloy.Provider.decode_body/1` now rejects non-object JSON (`null`, arrays,
  scalars) with `{:error, %Alloy.Provider.Error{kind: :protocol_error}}` and
  invalid JSON with `{:error, %Alloy.Provider.Error{kind: :malformed_reply}}`
  instead of a bare string.

## 5. Stricter startup & tool validation

- `Alloy.Agent.Config.from_opts/1` now raises `ArgumentError` on `provider: nil`,
  boolean providers, non-positive `:max_turns`/`:max_tokens`/`:tool_timeout`,
  non-positive/non-`:infinity` `:timeout_ms`, negative `:max_retries`/`:retry_backoff_ms`,
  invalid `:context`/`:system_prompt`/`:working_directory`/`:on_compaction`/
  `:code_execution`/`:until_tool`, and invalid `:middleware`/`:fallback_providers`
  entries.
- `Alloy.Testing.run_with_responses/3` now validates options through
  `Alloy.Agent.Config.from_opts/1` (defaulting `compaction: false`).
- `Alloy.Tool.Executor` rejects explicit `input: nil` as a non-object tool input
  (omit `:input` or pass `%{}` for no-arg calls).
- `Alloy.Tool.resolve_path/2` now expands relative `:allowed_paths` entries
  against `:working_directory` rather than the BEAM process CWD, and rejects
  non-string paths, NUL bytes, and non-list `:allowed_paths`.
- `Alloy.Tool.Core.Edit` rejects binary files, files over 10 MiB, and
  non-boolean `replace_all` values; `Alloy.Memory.tool/1` caps results at
  50,000 characters and rejects `create`/`str_replace`/`insert` on `/memories`.
- `Alloy.Provider.Codex` launches via non-login `sh -c` with explicit `:env`
  (set `:codex_bin` if `codex` is only on a login-shell `PATH`) and treats
  non-zero exits under `persist_session: true` as errors even when `last_message`
  exists.
- `tool_validation: :schema` converts unsupported `$schema` dialects (e.g. Draft
  2020-12) into a descriptive `ArgumentError`.
- **Tool & custom `:bash_executor` exception redaction:** Raised exceptions
  other than `RuntimeError` (capped to 500 bytes), standard `:badarg`, and
  atom-key `KeyError` now report only their exception module in `tool_result`
  blocks, `result.tool_calls[].error`, `[:alloy, :tool, :stop]`, and logs so
  captured `context` or credential maps cannot leak. Return `{:error, message}`
  or `raise "..."` for errors the model or telemetry should see.
- **Strict middleware halt/block/edit validation:** `{:halt, reason}`,
  `{:halt, reason, state}`, and `{:block, reason}` now require `reason` to be a
  string (`String.t()`), and `{:edit, modified_call}` requires a plain map;
  passing any other value (such as `{:halt, state}` or `{:block, state}`) raises
  `ArgumentError`.

## 6. Portable structured outputs (`:output_schema`)

You can now pass a single JSON Schema across Anthropic, OpenAI, xAI,
OpenAICompat, Gemini, and Codex:

```elixir
schema = %{
  type: "object",
  properties: %{summary: %{type: "string"}, score: %{type: "integer"}},
  required: ["summary", "score"],
  additionalProperties: false
}

{:ok, result} =
  Alloy.run("Score this PR.",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-5-5"},
    output_schema: schema
  )

result.output
#=> %{"summary" => "...", "score" => 9}
```

Alloy translates `:output_schema` into each provider's native structured-output
field (`output_config.format`, `text.format`, `response_format`,
`generationConfig.responseJsonSchema`, or Codex prompt instructions), forwards
it to fallback providers, omits it (and drops raw `extra_body` `output_config`,
`text`, `response_format`, and Gemini schema/thinking containers, including
sibling keys such as `output_config.effort` and `text.verbosity`) during
compaction summaries, and decodes/validates the final JSON into `result.output`
before `:after_completion`.

Key highlights (see `Alloy.OutputSchema` for the full failure, refusal,
validation-tier, and Gemini conflict contract):

- **Top-level option only:** Pass `:output_schema` to `Alloy.run/2`,
  `Alloy.stream/3`, or `Alloy.Agent.State.prepare/2` (passing it inside provider
  config raises `ArgumentError`). Wrapper keys `:name` (default `"alloy_output"`)
  and `:strict` (default `true`) apply to OpenAI, xAI, and OpenAICompat and are
  ignored on Anthropic, Gemini, and Codex.
- **Validation tiers:** Full Draft 4/6/7 validation runs when optional
  `:ex_json_schema` is installed; without it (or for Draft 2019-09/2020-12),
  Alloy falls back to top-level JSON `"type"` and `"required"` checks only.
- **Terminal failures:** Invalid JSON, `:max_tokens` truncation, refusals,
  missing/whitespace text, and schema mismatches return `{:error, result}` with
  `output: nil` and machine-readable `result.metadata.run.output_error` (no
  automatic repair turn). When `:stop_after_tool` completes or
  `:after_completion` returns `{:halt, reason}` / `{:halt, reason, state}`,
  `result.output` is `nil`.
- **Tools + schema compatibility:** Gemini models prior to Gemini 3 and some
  OpenAICompat servers reject combining `tools` with JSON Schema output; use
  Gemini 3+ (`gemini-3.8-flash`), `:until_tool` / `:stop_after_tool`, or a
  separate follow-up no-tools turn.
