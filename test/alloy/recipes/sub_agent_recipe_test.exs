defmodule Alloy.Recipes.SubAgentTest do
  @moduledoc """
  Verifies the sub-agent recipe in `docs/recipes/sub-agents.md` verbatim.

  If this test breaks, the recipe doc is wrong — fix both together.
  """
  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider

  # ── Recipe module (keep in sync with docs/recipes/sub-agents.md) ────────

  defmodule Delegate do
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

  # ── Tests ────────────────────────────────────────────────────────────────

  test "parent delegates to a sub-agent and uses its answer" do
    {:ok, child} = TestProvider.start_link([TestProvider.text_response("42")])

    {:ok, parent} =
      TestProvider.start_link([
        TestProvider.tool_use_response([
          %{
            type: "tool_use",
            id: "call_1",
            name: "delegate",
            input: %{"task" => "Compute the answer to everything"}
          }
        ]),
        TestProvider.text_response("The sub-agent says: 42")
      ])

    {:ok, result} =
      Alloy.run("Find the answer",
        provider: {TestProvider, agent_pid: parent},
        tools: [Delegate],
        context: %{delegate_provider: {TestProvider, agent_pid: child}}
      )

    assert result.status == :completed
    assert result.text == "The sub-agent says: 42"

    # The child's answer was fed back to the parent as a tool result.
    tool_result_text =
      result.messages
      |> Enum.flat_map(fn
        %{content: blocks} when is_list(blocks) -> blocks
        _ -> []
      end)
      |> Enum.find_value(fn
        %{type: "tool_result", content: content} -> content
        _ -> nil
      end)

    assert tool_result_text =~ "42"
  end

  test "sub-agent failure surfaces as a tool error, not a crash" do
    {:ok, child} =
      TestProvider.start_link(List.duplicate(TestProvider.error_response("HTTP 500"), 5))

    {:ok, parent} =
      TestProvider.start_link([
        TestProvider.tool_use_response([
          %{
            type: "tool_use",
            id: "call_1",
            name: "delegate",
            input: %{"task" => "Doomed task"}
          }
        ]),
        TestProvider.text_response("Could not delegate.")
      ])

    {:ok, result} =
      Alloy.run("Find the answer",
        provider: {TestProvider, agent_pid: parent},
        tools: [Delegate],
        context: %{delegate_provider: {TestProvider, agent_pid: child}}
      )

    # Parent loop survives the failed delegation and completes.
    assert result.status == :completed
    assert result.text == "Could not delegate."
  end
end
