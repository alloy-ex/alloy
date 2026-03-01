defmodule Alloy.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Supports parallel execution via `Task.async_stream` -
  multiple tool calls in a single assistant response are
  executed concurrently.
  """

  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Middleware

  @doc """
  Execute all tool calls and return a list of tool_result content blocks
  wrapped in a single user message.

  Runs `:before_tool_call` middleware before each tool. If middleware
  returns `{:block, reason}`, that tool's result is an error block and
  the tool is not executed. If middleware returns `{:halt, reason}`,
  the entire execute_all call returns `{:halted, reason}` immediately
  without executing any tools.
  """
  @spec execute_all([map()], %{String.t() => module()}, State.t()) ::
          Message.t() | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state) do
    case execute_all(tool_calls, tool_fns, state, on_event: fn _event -> :ok end) do
      {:ok, result_msg, _tool_calls} -> result_msg
      {:halted, _reason} = halted -> halted
    end
  end

  @doc """
  Execute all tool calls and return:

  - tool result message (`Alloy.Message.tool_results/1`)
  - per-tool execution metadata

  Options:

  - `:on_event` - callback called with `{:tool_start, payload}` and
    `{:tool_end, payload}` events.
  - `:event_seq_ref` - shared atomics counter for ordered tool events.
  - `:event_correlation_id` - correlation id attached to tool events.
  - `:event_turn` - turn number used in telemetry metadata.
  """
  @spec execute_all([map()], %{String.t() => module()}, State.t(), keyword()) ::
          {:ok, Message.t(), [map()]} | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state, opts) when is_list(opts) do
    context = build_context(state)
    tool_timeout = state.config.tool_timeout
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    event_seq_ref = Keyword.get(opts, :event_seq_ref, :atomics.new(1, signed: false))

    event_correlation_id =
      Keyword.get(opts, :event_correlation_id, default_event_correlation_id())

    event_turn = Keyword.get(opts, :event_turn, state.turn)

    # Check middleware before execution — short-circuit on halt
    case tag_tool_calls(state, tool_calls) do
      {:halted, reason} ->
        {:halted, reason}

      {:ok, tagged} ->
        {results, tool_call_meta} =
          tagged
          |> Task.async_stream(
            fn
              {:execute, call} ->
                execute_one(
                  call,
                  tool_fns,
                  context,
                  on_event,
                  event_seq_ref,
                  event_correlation_id,
                  event_turn
                )

              {:blocked, call, reason} ->
                blocked_result(
                  call,
                  reason,
                  on_event,
                  event_seq_ref,
                  event_correlation_id,
                  event_turn
                )
            end,
            timeout: tool_timeout,
            ordered: true,
            on_timeout: :kill_task
          )
          |> Enum.zip(tagged)
          |> Enum.map(fn
            {{:ok, {result, meta}}, _tag} ->
              {result, meta}

            {{:exit, reason}, tag} ->
              call = call_from_tag(tag)

              crashed_result(
                call,
                reason,
                on_event,
                event_seq_ref,
                event_correlation_id,
                event_turn
              )
          end)
          |> Enum.unzip()

        {:ok, Message.tool_results(results), tool_call_meta}
    end
  end

  defp tag_tool_calls(state, tool_calls) do
    result =
      Enum.reduce_while(tool_calls, {:ok, []}, fn call, {:ok, acc} ->
        case Middleware.run_before_tool_call(state, call) do
          :ok -> {:cont, {:ok, [{:execute, call} | acc]}}
          {:block, reason} -> {:cont, {:ok, [{:blocked, call, reason} | acc]}}
          {:halted, reason} -> {:halt, {:halted, reason}}
        end
      end)

    case result do
      {:ok, tagged} -> {:ok, Enum.reverse(tagged)}
      {:halted, _} = halted -> halted
    end
  end

  defp execute_one(
         call,
         tool_fns,
         context,
         on_event,
         event_seq_ref,
         event_correlation_id,
         event_turn
       ) do
    started_at = System.monotonic_time(:millisecond)

    start_event_seq =
      emit_tool_start(on_event, call, event_seq_ref, event_correlation_id, event_turn)

    tool_name = call[:name]
    tool_use_id = call[:id]
    input = call[:input] || %{}

    {result, error} =
      case Map.fetch(tool_fns, tool_name) do
        {:ok, module} ->
          try do
            case module.execute(input, context) do
              {:ok, result} ->
                {Message.tool_result_block(tool_use_id, result), nil}

              {:error, reason} ->
                {Message.tool_result_block(tool_use_id, reason, true), reason}
            end
          rescue
            e ->
              error = "Tool crashed: #{Exception.message(e)}"
              {Message.tool_result_block(tool_use_id, error, true), error}
          end

        :error ->
          error = "Unknown tool: #{tool_name}"
          {error_result(tool_use_id, error), error}
      end

    duration_ms = elapsed_ms(started_at)
    base_meta = tool_call_metadata(call, duration_ms, error)

    end_event_seq =
      emit_tool_end(
        on_event,
        base_meta,
        event_seq_ref,
        event_correlation_id,
        event_turn,
        start_event_seq
      )

    meta =
      Map.merge(base_meta, %{
        correlation_id: event_correlation_id,
        start_event_seq: start_event_seq,
        end_event_seq: end_event_seq
      })

    {result, meta}
  end

  defp blocked_result(call, reason, on_event, event_seq_ref, event_correlation_id, event_turn) do
    started_at = System.monotonic_time(:millisecond)

    start_event_seq =
      emit_tool_start(on_event, call, event_seq_ref, event_correlation_id, event_turn)

    error = "Blocked: #{reason}"
    duration_ms = elapsed_ms(started_at)
    base_meta = tool_call_metadata(call, duration_ms, error)

    end_event_seq =
      emit_tool_end(
        on_event,
        base_meta,
        event_seq_ref,
        event_correlation_id,
        event_turn,
        start_event_seq
      )

    meta =
      Map.merge(base_meta, %{
        correlation_id: event_correlation_id,
        start_event_seq: start_event_seq,
        end_event_seq: end_event_seq
      })

    {error_result(call[:id], error), meta}
  end

  defp crashed_result(call, reason, on_event, event_seq_ref, event_correlation_id, event_turn) do
    error = "Tool execution crashed: #{inspect(reason)}"
    base_meta = tool_call_metadata(call, 0, error)

    end_event_seq =
      emit_tool_end(
        on_event,
        base_meta,
        event_seq_ref,
        event_correlation_id,
        event_turn,
        nil
      )

    meta =
      Map.merge(base_meta, %{
        correlation_id: event_correlation_id,
        start_event_seq: nil,
        end_event_seq: end_event_seq
      })

    {error_result(call[:id], error), meta}
  end

  defp call_from_tag({:execute, call}), do: call
  defp call_from_tag({:blocked, call, _reason}), do: call

  defp tool_call_metadata(call, duration_ms, error) do
    %{
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{},
      duration_ms: duration_ms,
      error: error
    }
  end

  defp emit_tool_start(on_event, call, event_seq_ref, correlation_id, turn) do
    event_seq = next_event_seq(event_seq_ref)

    payload = %{
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{},
      event_seq: event_seq,
      correlation_id: correlation_id
    }

    on_event.({:tool_start, payload})

    :telemetry.execute(
      [:alloy, :tool, :start],
      %{event_seq: event_seq},
      %{
        correlation_id: correlation_id,
        turn: turn,
        tool_id: call[:id],
        tool_name: call[:name]
      }
    )

    event_seq
  end

  defp emit_tool_end(on_event, meta, event_seq_ref, correlation_id, turn, start_event_seq) do
    event_seq = next_event_seq(event_seq_ref)

    payload =
      Map.merge(meta, %{
        event_seq: event_seq,
        correlation_id: correlation_id,
        start_event_seq: start_event_seq
      })

    on_event.({:tool_end, payload})

    :telemetry.execute(
      [:alloy, :tool, :stop],
      %{event_seq: event_seq, duration_ms: meta.duration_ms || 0},
      %{
        correlation_id: correlation_id,
        turn: turn,
        tool_id: meta.id,
        tool_name: meta.name,
        error: meta.error,
        start_event_seq: start_event_seq
      }
    )

    event_seq
  end

  defp next_event_seq(ref) do
    :atomics.add_get(ref, 1, 1)
  end

  defp default_event_correlation_id do
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp elapsed_ms(started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    max(elapsed, 0)
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
