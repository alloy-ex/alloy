# Host-owned code mode

Code mode is an application capability, not a second execution system inside
Alloy. The executable experiment is `examples/minimal_host/code_mode.exs`, with
regressions in `test/examples/minimal_host_test.exs`.

The experiment accepts a **trusted host program**, a configured agent state,
and explicit timeout/call limits. The program receives a dispatch function:

```elixir
program = fn dispatch ->
  dispatch.([%{name: "read", input: %{"file_path" => "README.md"}}])
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

The dispatcher uses `Alloy.Tool.Executor.execute_all/4`, rather than invoking
individual tools' `execute/2` functions. It preserves Alloy's required-key
validation, per-call middleware, sequential-tool ordering, supervised tasks,
structured results, and cancellation. It also runs the request/execution
middleware hooks and annotates emitted child events with the parent call ID.
The executor does not claim full JSON Schema validation; neither does this
recipe. No new public core API is needed for this experiment.

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
mix test test/examples/minimal_host_test.exs
```

Tests cover blocked writes, missing required input, structured results,
after-execution hooks, parent events, sequential calls, recursion exclusion,
call budgets, timeout, and cancellation of active/pending child calls.
