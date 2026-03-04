defmodule Alloy.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Supports parallel execution via `Task.Supervisor.async_stream` -
  multiple tool calls in a single assistant response are
  executed concurrently under `Alloy.TaskSupervisor`.
  """

  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Middleware

  require Logger

  @spec execute_all([map()], %{String.t() => module()}, State.t()) ::
          Message.t() | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state) do
    case execute_all(tool_calls, tool_fns, state, []) do
      {:ok, msg, _meta} -> msg
      {:halted, _} = h -> h
    end
  end

  @spec execute_all([map()], %{String.t() => module()}, State.t(), keyword()) ::
          {:ok, Message.t(), [map()]} | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state, opts) when is_list(opts) do
    context = build_context(state)
    tool_timeout = state.config.tool_timeout
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    seq_ref = Keyword.get(opts, :event_seq_ref, :atomics.new(1, signed: false))
    corr_id = Keyword.get(opts, :event_correlation_id, random_id())
    turn = Keyword.get(opts, :event_turn, state.turn)

    case tag_tool_calls(state, tool_calls) do
      {:halted, _} = h ->
        h

      {:ok, tagged} ->
        {results, meta} =
          Task.Supervisor.async_stream(
            Alloy.TaskSupervisor,
            tagged,
            &run_tagged(&1, tool_fns, context, on_event, seq_ref, corr_id, turn),
            timeout: tool_timeout,
            ordered: true,
            on_timeout: :kill_task
          )
          |> Enum.zip(tagged)
          |> Enum.map(fn
            {{:ok, pair}, _} ->
              pair

            {{:exit, reason}, tag} ->
              crashed(call_from(tag), reason, on_event, seq_ref, corr_id, turn)
          end)
          |> Enum.unzip()

        {:ok, Message.tool_results(results), meta}
    end
  end

  defp tag_tool_calls(state, calls) do
    result =
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
        case Middleware.run_before_tool_call(state, call) do
          :ok -> {:cont, {:ok, [{:execute, call} | acc]}}
          {:block, reason} -> {:cont, {:ok, [{:blocked, call, reason} | acc]}}
          {:halted, reason} -> {:halt, {:halted, reason}}
        end
      end)

    case result do
      {:ok, tagged} -> {:ok, Enum.reverse(tagged)}
      other -> other
    end
  end

  defp run_tagged({:execute, call}, fns, ctx, on_event, seq_ref, corr_id, turn) do
    t0 = System.monotonic_time(:millisecond)
    sseq = emit_start(on_event, call, seq_ref, corr_id, turn)
    block_fn = result_block_fn(call[:type])

    {result, error, structured_data} =
      case Map.fetch(fns, call[:name]) do
        {:ok, mod} ->
          try do
            case mod.execute(call[:input] || %{}, ctx) do
              {:ok, text, data} when is_map(data) ->
                {block_fn.(call[:id], text, false), nil, data}

              {:ok, r} ->
                {block_fn.(call[:id], r, false), nil, nil}

              {:error, r} ->
                {block_fn.(call[:id], r, true), r, nil}
            end
          rescue
            e ->
              stacktrace = __STACKTRACE__
              err = "Tool crashed: #{Exception.message(e)}"

              Logger.warning(
                "Tool #{call[:name]} crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(stacktrace)}"
              )

              {block_fn.(call[:id], err, true), err, nil}
          end

        :error ->
          err = "Unknown tool: #{call[:name]}"
          {block_fn.(call[:id], err, true), err, nil}
      end

    ms = max(System.monotonic_time(:millisecond) - t0, 0)

    meta =
      %{
        id: call[:id],
        name: call[:name],
        input: call[:input] || %{},
        duration_ms: ms,
        error: error
      }

    eseq = emit_end(on_event, meta, seq_ref, corr_id, turn, sseq)

    meta =
      meta
      |> Map.merge(%{correlation_id: corr_id, start_event_seq: sseq, end_event_seq: eseq})
      |> maybe_put_structured_data(structured_data)

    {result, meta}
  end

  defp run_tagged({:blocked, call, reason}, _, _, on_event, seq_ref, corr_id, turn) do
    sseq = emit_start(on_event, call, seq_ref, corr_id, turn)
    error = "Blocked: #{reason}"

    meta = %{
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{},
      duration_ms: 0,
      error: error
    }

    eseq = emit_end(on_event, meta, seq_ref, corr_id, turn, sseq)

    {result_block_fn(call[:type]).(call[:id], error, true),
     Map.merge(meta, %{correlation_id: corr_id, start_event_seq: sseq, end_event_seq: eseq})}
  end

  defp crashed(call, reason, on_event, seq_ref, corr_id, turn) do
    error = "Tool execution crashed: #{inspect(reason)}"

    meta = %{
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{},
      duration_ms: 0,
      error: error
    }

    eseq = emit_end(on_event, meta, seq_ref, corr_id, turn, nil)

    {result_block_fn(call[:type]).(call[:id], error, true),
     Map.merge(meta, %{correlation_id: corr_id, start_event_seq: nil, end_event_seq: eseq})}
  end

  defp call_from({:execute, c}), do: c
  defp call_from({:blocked, c, _}), do: c

  defp emit_start(on_event, call, seq_ref, corr_id, turn) do
    seq = :atomics.add_get(seq_ref, 1, 1)

    on_event.(
      {:tool_start,
       %{
         id: call[:id],
         name: call[:name],
         input: call[:input] || %{},
         event_seq: seq,
         correlation_id: corr_id
       }}
    )

    :telemetry.execute([:alloy, :tool, :start], %{event_seq: seq}, %{
      correlation_id: corr_id,
      turn: turn,
      tool_id: call[:id],
      tool_name: call[:name]
    })

    seq
  end

  defp emit_end(on_event, meta, seq_ref, corr_id, turn, start_seq) do
    seq = :atomics.add_get(seq_ref, 1, 1)

    on_event.(
      {:tool_end,
       Map.merge(meta, %{
         event_seq: seq,
         correlation_id: corr_id,
         start_event_seq: start_seq
       })}
    )

    :telemetry.execute(
      [:alloy, :tool, :stop],
      %{event_seq: seq, duration_ms: meta.duration_ms},
      %{
        correlation_id: corr_id,
        turn: turn,
        tool_id: meta.id,
        tool_name: meta.name,
        error: meta.error,
        start_event_seq: start_seq
      }
    )

    seq
  end

  defp result_block_fn("server_tool_use"), do: &Message.server_tool_result_block/3
  defp result_block_fn(_), do: &Message.tool_result_block/3

  defp maybe_put_structured_data(meta, nil), do: meta
  defp maybe_put_structured_data(meta, data), do: Map.put(meta, :structured_data, data)

  defp random_id, do: "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp build_context(%State{} = state) do
    Map.merge(state.config.context, %{
      working_directory: state.config.working_directory
    })
  end
end
