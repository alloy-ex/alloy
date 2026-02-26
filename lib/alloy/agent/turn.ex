defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  ~80 lines of actual logic.
  """

  alias Alloy.Agent.State
  alias Alloy.{Message, Middleware}
  alias Alloy.Context.Compactor
  alias Alloy.Tool.Executor

  @doc """
  Run the agent loop until completion, error, or max turns.

  Takes an initialized `State` with messages and returns the
  final state with status set to `:completed`, `:error`, or `:max_turns`.
  """
  @spec run_loop(State.t()) :: State.t()
  def run_loop(%State{} = state) do
    do_turn(state)
  end

  defp do_turn(%State{turn: turn, config: config} = state) when turn >= config.max_turns do
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state) do
    state = Compactor.maybe_compact(state)
    state = Middleware.run(:before_completion, state)

    provider = state.config.provider
    provider_config = build_provider_config(state)

    streaming? = state.config.streaming && function_exported?(provider, :stream, 4)
    on_chunk = Map.get(state.config.context, :on_chunk) || fn _chunk -> :ok end

    result =
      if streaming? do
        provider.stream(state.messages, state.tool_defs, provider_config, on_chunk)
      else
        provider.complete(state.messages, state.tool_defs, provider_config)
      end

    case result do
      {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage}} ->
        state =
          state
          |> State.append_messages(new_msgs)
          |> State.increment_turn()
          |> State.merge_usage(usage)
          |> then(&Middleware.run(:after_completion, &1))

        tool_calls = extract_tool_calls(new_msgs)
        result_msg = Executor.execute_all(tool_calls, state.tool_fns, state)

        state =
          state
          |> State.append_messages(result_msg)
          |> then(&Middleware.run(:after_tool_execution, &1))

        do_turn(state)

      {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage}} ->
        state
        |> State.append_messages(new_msgs)
        |> State.increment_turn()
        |> State.merge_usage(usage)
        |> then(&Middleware.run(:after_completion, &1))
        |> then(&%{&1 | status: :completed})

      {:error, reason} ->
        state = %{state | status: :error, error: reason}
        Middleware.run(:on_error, state)
    end
  end

  defp build_provider_config(%State{config: config}) do
    Map.put(config.provider_config, :system_prompt, config.system_prompt)
  end

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end
end
