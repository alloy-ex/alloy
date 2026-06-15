# Recipe: Sub-agents as tools

Alloy has no sub-agent primitive, on purpose. An agent's "self" is just
`Alloy.run/2` — a function call — so a sub-agent is a tool whose `execute/2`
runs another agent. The whole pattern is ~30 lines, and on the BEAM it comes
with properties most frameworks charge a runtime for: each delegation runs in
a supervised task, crashes are isolated to the tool call, and when the model
requests several delegations in one turn the executor fans them out in
parallel (`concurrent?/0`).

This mirrors how the leanest coding agents handle delegation: they spawn
another copy of themselves via a shell command rather than shipping a
sub-agent subsystem. Alloy's translation: spawn yourself via function call.

> The module below is tested verbatim in
> `test/alloy/recipes/sub_agent_recipe_test.exs`. If the API drifts, that
> test fails before this doc lies to you.

## The tool

```elixir
defmodule MyApp.Tools.Delegate do
  @behaviour Alloy.Tool

  @impl true
  def name, do: "delegate"

  @impl true
  def description do
    "Delegate a self-contained task to a focused sub-agent. " <>
      "The sub-agent has read-only file access and returns its final " <>
      "answer as text. Provide the full task description — the " <>
      "sub-agent cannot see this conversation."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        task: %{
          type: "string",
          description: "Complete, self-contained task for the sub-agent"
        }
      },
      required: ["task"]
    }
  end

  # Sub-agents are independent — let the executor fan them out in
  # parallel when the model requests several delegations in one turn.
  @impl true
  def concurrent?, do: true

  @impl true
  def execute(%{"task" => task}, context) do
    case Alloy.run(task,
           provider: Map.fetch!(context, :delegate_provider),
           tools: [Alloy.Tool.Core.Read],
           max_turns: 8,
           timeout_ms: 60_000,
           max_budget_cents: 25
         ) do
      {:ok, result} ->
        {:ok, result.text || ""}

      {:error, result} ->
        {:error, "Sub-agent stopped (#{result.status}): #{inspect(result.error)}"}
    end
  end
end
```

## Using it

Pass the sub-agent's provider through `context:` — typically a cheaper or
faster model than the parent's:

```elixir
{:ok, result} =
  Alloy.run("Compare the error handling in lib/foo.ex and lib/bar.ex",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-opus-4-6"},
    tools: [MyApp.Tools.Delegate, Alloy.Tool.Core.Read],
    context: %{
      delegate_provider:
        {Alloy.Provider.Anthropic, api_key: key, model: "claude-haiku-4-5"}
    }
  )
```

## Design notes

**Give the sub-agent a narrower toolset than the parent.** The example grants
only `Read`. A sub-agent with `Bash` or `Write` multiplies your blast radius;
delegation should reduce capability, not forward it.

**Cap everything explicitly.** The child run knows nothing about its parent —
parent budget, deadline, and correlation IDs do **not** propagate. Treat
`max_turns`, `timeout_ms`, and `max_budget_cents` on the child as mandatory,
and remember the parent's own `max_budget_cents` cannot see tokens spent
inside the child. If you need combined accounting, return `result.usage` in a
structured tool result and sum in your application.

**Recursion.** If you give the sub-agent the `delegate` tool too, you have
unbounded recursion at the model's discretion. Don't — or thread a depth
counter through `context:` and refuse below zero.

**Don't fake a team.** One level of delegation with explicit caps covers most
real uses (research, review, summarization of large inputs). If you find
yourself wanting routing, shared state, and inter-agent messaging, you've
outgrown this recipe — build that layer in your application where it belongs.
