# Host-owned code mode

Code mode is an application capability, not a second execution system inside
Alloy. The executable experiment is `examples/minimal_host/code_mode.exs`, with
regressions in `test/examples/minimal_host_test.exs`.

The experiment accepts a **trusted host program**, a configured agent state,
and explicit timeout/call limits. The program receives a dispatch function that
accepts either a single tool call map or a list of tool calls:

```elixir
program = fn dispatch ->
  # Single nested call (routed through Alloy.Tool.Executor.run_tool/3)
  %{result: readme} = dispatch.(%{name: "read", input: %{"file_path" => "README.md"}})

  # Batch nested calls (routed through Alloy.Tool.Executor.execute_all/4)
  dispatch.([
    %{name: "read", input: %{"file_path" => "mix.exs"}},
    %{name: "read", input: %{"file_path" => "CHANGELOG.md"}}
  ])
end

MinimalHost.CodeMode.run(program, state,
  parent_call_id: "outer-call-id",
  max_calls: 8,
  timeout: 5_000
)
```

Supply the real outer call ID from the host. Configure `state` with only the
tools and authority granted to that job. The state and limits must not come
from model-supplied arguments. When exposed as a script tool, use
`concurrent?: false` and exclude that tool from its own callable set.

The dispatcher routes single calls through `Alloy.Tool.Executor.run_tool/3` and
multi-call batches through `Alloy.Tool.Executor.execute_all/4`, rather than
invoking individual tools' `execute/2` functions directly. Both share the exact
same internal pipeline:

- `:before_tool_call` and `:after_tool_call` middleware
- required-key and optional JSON Schema validation (`:tool_validation`)
- sequential-tool ordering (`concurrent?: false`)
- supervised worker tasks bounded by `:tool_timeout` and `:run_deadline`
  (clamped to the outer `state.run_deadline`)
- cooperative cancellation via `:cancel_token`
- structured results, redaction/truncation, and caller-process events
- native `:parent_call_id` tagging on `:tool_start`, `:tool_update`,
  `:tool_end`, tool telemetry, and returned metadata

## Direct single-tool execution

Composite tools and custom hosts that don't need batching can call
`Alloy.Tool.Executor.run_tool/3` directly:

```elixir
{:ok, result_block, meta} =
  Alloy.Tool.Executor.run_tool(
    %{id: "outer-1-sub-1", name: "read", input: %{"file_path" => "README.md"}},
    state,
    parent_call_id: "outer-1",
    on_event: on_event
  )
```

## Interpreter boundary

This example **is not a sandbox**. Never pass model-generated Elixir to
`Code.eval_string/1` or convert it into a trusted program. A production host
must supply a sandboxed interpreter with bounded memory/instructions, no
ambient filesystem/network/process access, and only the dispatch capability.
It must forward cancellation to any external VM. Cross-process dispatch is
rejected by this in-process experiment; an external interpreter needs an
explicit host-owned request protocol instead.

The test program establishes the execution-boundary pattern without adding a
Lua or JavaScript runtime dependency to Alloy. Runtime selection and production
deployment are deliberately not part of this experiment.

## Verification

```sh
mix test test/examples/minimal_host_test.exs test/alloy/tool/run_tool_test.exs
```

Tests cover blocked writes, missing required input, structured results,
after-execution hooks, native `:parent_call_id` events, single-call `run_tool/3`
dispatch, sequential calls, recursion exclusion, call budgets, timeout, and
cancellation of active/pending child calls.
