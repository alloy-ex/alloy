# Loop controls

## Tool middleware

`:before_tool_call` receives `state.config.context.current_tool_call`. Returning
`{:edit, call}` passes that call to the next middleware module. The ID and name
must stay unchanged. A block or halt ends the chain. Validation runs on the final
arguments before the tool executes.

`:after_tool_call` receives `current_tool_call` and `current_tool_result` in the
same context. The result has `content` (text), `data` (map or nil), and `is_error`.
Return `{:result, replacement}` to replace content/data, or the state unchanged.
Replacements pass through later hooks. `is_error` cannot change. This hook runs
for successful, blocked, invalid, unknown, crashed, timed-out, and cancelled calls.

```elixir
def call(:after_tool_call, state) do
  result = state.config.context.current_tool_result
  {:result, %{result | content: MyApp.Redaction.text(result.content), data: nil}}
end

def call(_hook, state), do: state
```

Redact structured data as well as text. The hook precedes the tool-end event and
transcript publication; exceptions abort rather than publish the original
result. Hooks run in the caller process and should finish promptly. Changes to
the state struct returned from a per-tool hook are not applied to loop state.
Tool-internal logs and external side effects are outside result redaction.

## Local argument validation

By default Alloy checks that tool arguments are an object with all required
keys. Enable full schema validation by adding the optional dependency:

```elixir
{:ex_json_schema, "~> 0.11.5"}
```

Then pass `tool_validation: :schema` to `Alloy.run/2` or the agent configuration.
The adapter supports JSON Schema drafts 4, 6, and 7 (default 7), validates final
edited inputs, and returns validation errors to the model without executing the
tool. It never coerces values. Atom-keyed schemas and inputs are validated in
their JSON representation; execution receives the original input.

Only local `$ref` values are supported. No remote schemas are fetched. Invalid
or unsupported schemas are configuration errors raised before tool dispatch.
Provider `strict: true` is independent of local validation. Keep `:required`
for integrations with loose schemas until those schemas can be validated.

Resolved schemas are reused in agent state while their exact input schemas remain
unchanged. Changed schemas are resolved before execution, and removed tools are
dropped on the next validation batch. The cache is local to the state and is not
returned in results or session metadata.

## Complete after a tool succeeds

```elixir
{:ok, result} = Alloy.run(prompt,
  provider: provider,
  tools: [MyApp.SubmitAnswer],
  stop_after_tool: "submit_answer"
)

result.text
result.metadata.final_tool.structured_data
```

The whole tool round settles first, preserving every result in source order.
The first successful matching call in that order becomes the final output.
Failures and blocked calls do not trigger early completion. Other tools in the
round may have failed; inspect `result.tool_calls` when that matters to your
application. Existing `until_tool` requirements must also be satisfied.

`:after_tool_execution` can still halt the run. `:after_completion` runs when
early completion succeeds. No extra provider request or synthetic assistant
message is added. With streaming, tool output is returned in the final result;
it is not emitted as fabricated assistant text deltas. This control applies to
ordinary local tools, including memory tools, rather than provider-executed tools.

## Prepare each request

Use the existing `:before_completion` middleware hook:

```elixir
def call(:before_completion, state) do
  tools = if state.turn == 0, do: [MyApp.Search], else: [MyApp.SubmitAnswer]
  Alloy.Agent.State.prepare(state, tools: tools)
end

def call(_hook, state), do: state
```

`State.prepare/2` accepts `:tools`, `:messages`, `:system_prompt`, `:provider`,
`:output_schema`, and `:reasoning`.
Changes persist for later turns. Tool definitions and dispatch mappings change
together. A provider tuple can update the model or its request settings; derived
model limits are refreshed, while explicit context limits remain unchanged.
Changing provider configuration clears opaque provider state conservatively,
whereas updating only top-level `:reasoning` preserves live `provider_state`.
Pass `provider_state:` in the new provider configuration to supply replacement
state explicitly. Preparing unchanged provider configuration retains live state.

Run counters, usage, and deadlines are preserved. Preparation runs before
automatic compaction, which is appended after caller middleware and budgets
the prepared request. Explicitly listing `Alloy.Context.Compactor` preserves
your chosen ordering. Context-overflow
recovery may invoke the hook again; hooks should not repeat external effects or
restore context that compaction just removed. This helper does not translate
provider-specific history; follow the provider compatibility rules when switching.

## Validate imported conversations

```elixir
Alloy.Transcript.validate(messages)
# :ok or {:error, issues}

Alloy.Transcript.repair(messages)
# {:ok, repaired_messages} or {:error, ambiguous_issues}
```

These explicit utilities check local tool-call/result pairing. Repair adds an
error saying the missing outcome is unknown; it never invokes the tool. Existing
results and provider-owned server tools remain intact. Duplicate IDs within a
round, duplicate or orphaned results, and malformed IDs are rejected. IDs can be
reused in a later round. In a mixed user message, tool results must precede text.

Repair is idempotent and not automatic. Pairing validation does not validate a
provider's signed reasoning or opaque state. Preserve provider-specific history
requirements when changing a transcript.

## Bound tool concurrency

Pass `tool_concurrency: 4` to limit parallel tool execution. The default remains
`System.schedulers_online()`. Tools with `concurrent?/0 == false` still execute
alone in source order, with barriers around adjacent parallel batches. This is
a per-run execution limit; account-wide rate limits remain application policy.

## Cancellation, steering, and follow-up

- **Cooperative cancellation (`:cancel_token`):** Create a token with
  `Alloy.Cancel.new/0`, pass `cancel_token: token` to `Alloy.run/2` or
  `Alloy.stream/3`, and call `Alloy.Cancel.cancel/1` from any process.
  Cancellation aborts in-flight provider requests and tool workers, emits
  synthetic error `tool_result` blocks for interrupted or skipped tools so the
  transcript stays valid, and returns
  `{:error, %Alloy.Result{status: :cancelled, error: :cancelled}}`.
- **Mid-round steering (`:steering`):** Pass `steering: fn state -> [...] end`.
  Polled between completed tool batches (and after the last batch before
  `:stop_after_tool`); returning one or more `%Alloy.Message{}` structs skips
  any remaining unstarted tool batches with synthetic error `tool_result`
  blocks, appends the steering messages, and starts the next turn.
- **Post-turn follow-up (`:follow_up`):** Pass `follow_up: fn state -> [...] end`.
  Polled right before normal non-refusal `:end_turn` completion once
  `:until_tool` is satisfied; returning one or more `%Alloy.Message{}` structs
  appends them and continues the loop within `:max_turns`, `:timeout_ms`, and
  `:cancel_token`.
