defmodule Alloy.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Supports parallel execution via `Task.async_stream` -
  multiple tool calls in a single assistant response are
  executed concurrently.
  """

  alias Alloy.Message
  alias Alloy.Agent.State
  alias Alloy.Middleware

  @doc """
  Execute all tool calls and return a list of tool_result content blocks
  wrapped in a single user message.

  Runs `:before_tool_call` middleware before each tool. If middleware
  returns `{:block, reason}`, that tool's result is an error block and
  the tool is not executed.
  """
  @spec execute_all([map()], %{String.t() => module()}, State.t()) :: Message.t()
  def execute_all(tool_calls, tool_fns, %State{} = state) do
    context = build_context(state)

    # Check middleware before execution — tag each call
    tagged =
      Enum.map(tool_calls, fn call ->
        case Middleware.run_before_tool_call(state, call) do
          :ok -> {:execute, call}
          {:block, reason} -> {:blocked, call, reason}
        end
      end)

    results =
      tagged
      |> Task.async_stream(
        fn
          {:execute, call} -> execute_one(call, tool_fns, context)
          {:blocked, call, reason} -> error_result(call[:id], "Blocked: #{reason}")
        end,
        timeout: 120_000,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> error_result("unknown", "Tool execution crashed: #{inspect(reason)}")
      end)

    Message.tool_results(results)
  end

  defp execute_one(call, tool_fns, context) do
    tool_name = call[:name]
    tool_use_id = call[:id]
    input = call[:input] || %{}

    case Map.fetch(tool_fns, tool_name) do
      {:ok, module} ->
        try do
          case module.execute(input, context) do
            {:ok, result} ->
              Message.tool_result_block(tool_use_id, result)

            {:error, reason} ->
              Message.tool_result_block(tool_use_id, reason, true)
          end
        rescue
          e ->
            Message.tool_result_block(
              tool_use_id,
              "Tool crashed: #{Exception.message(e)}",
              true
            )
        end

      :error ->
        error_result(tool_use_id, "Unknown tool: #{tool_name}")
    end
  end

  defp error_result(tool_use_id, message) do
    Message.tool_result_block(tool_use_id, message, true)
  end

  defp build_context(%State{} = state) do
    Map.merge(state.config.context, %{
      working_directory: state.config.working_directory,
      config: state.config,
      scratchpad_pid: state.scratchpad
    })
  end
end
