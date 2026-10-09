defmodule Alloy.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Calls run in the order the model made them. Consecutive calls to tools
  that are safe to run concurrently (the default; see
  `c:Alloy.Tool.concurrent?/0`) run in parallel; a call to a tool that
  returns `concurrent?: false` waits for everything before it and runs
  alone.

  Each call runs in an unlinked task under `Alloy.TaskSupervisor`, bounded
  by the agent's `:tool_timeout`. A tool that raises, exits, throws or
  times out produces an `is_error` tool result instead of crashing the
  agent.
  """

  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Middleware
  alias Alloy.Tool.Inline
  alias Alloy.Tool.Registry

  require Logger

  @spec execute_all([map()], %{String.t() => Registry.tool()}, State.t()) ::
          Message.t() | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state) do
    case execute_all(tool_calls, tool_fns, state, []) do
      {:ok, msg, _meta} -> msg
      {:halted, _} = h -> h
    end
  end

  @spec execute_all([map()], %{String.t() => Registry.tool()}, State.t(), keyword()) ::
          {:ok, Message.t(), [map()]} | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state, opts) when is_list(opts) do
    run = %{
      tool_fns: tool_fns,
      context: build_context(state),
      timeout: state.config.tool_timeout,
      on_event: Keyword.get(opts, :on_event, fn _ -> :ok end),
      seq_ref: Keyword.get(opts, :event_seq_ref, :atomics.new(1, signed: false)),
      corr_id: Keyword.get(opts, :event_correlation_id, random_id()),
      turn: Keyword.get(opts, :event_turn, state.turn)
    }

    with {:ok, tagged} <- tag_tool_calls(state, tool_calls) do
      {results, meta} =
        tagged
        |> batches(tool_fns)
        |> Enum.flat_map(&run_batch(&1, run))
        |> Enum.unzip()

      {:ok, Message.tool_results(results), meta}
    end
  end

  # Calls run in the order the model made them, so a sequential call sees
  # the effects of every call before it ([read f, edit f] reads first).
  # Consecutive concurrency-safe calls share a parallel batch; each
  # sequential call is a batch of its own.
  defp batches(tagged, tool_fns) do
    tagged
    |> Enum.chunk_by(&concurrent?(&1, tool_fns))
    |> Enum.flat_map(fn [first | _] = batch ->
      if concurrent?(first, tool_fns), do: [batch], else: Enum.map(batch, &[&1])
    end)
  end

  defp concurrent?({:execute, call}, tool_fns) do
    case Map.fetch(tool_fns, call[:name]) do
      {:ok, tool} -> not tool_sequential?(tool)
      :error -> true
    end
  end

  defp concurrent?({:blocked, _call, _reason}, _tool_fns), do: true

  # Every tool runs in an unlinked, supervised task: a tool that raises,
  # exits or throws, or overruns :tool_timeout, becomes an error result
  # instead of taking down the agent process that called the executor.
  #
  # tool_start is emitted here, before the task exists, and tool_end after
  # it finishes, so the pair matches with a real duration even when the
  # task is killed on timeout.
  defp run_batch(batch, run) do
    started = batch |> Enum.with_index() |> Enum.map(&start(&1, run))

    Alloy.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(started, &{&1, invoke(&1.tag, run)},
      timeout: run.timeout,
      on_timeout: :kill_task,
      max_concurrency: length(batch),
      ordered: false,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, {started, outcome}} -> finish(started, outcome, run)
      {:exit, {started, reason}} -> finish(started, exit_outcome(started.call, reason, run), run)
    end)
    |> Enum.sort_by(fn {index, _pair} -> index end)
    |> Enum.map(fn {_index, pair} -> pair end)
  end

  defp tag_tool_calls(state, calls) do
    result =
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
        case Middleware.run_before_tool_call(state, call) do
          :ok -> {:cont, {:ok, [{:execute, call} | acc]}}
          {:edit, modified_call} -> {:cont, {:ok, [{:execute, modified_call} | acc]}}
          {:block, reason} -> {:cont, {:ok, [{:blocked, call, reason} | acc]}}
          {:halted, reason} -> {:halt, {:halted, reason}}
        end
      end)

    case result do
      {:ok, tagged} -> {:ok, Enum.reverse(tagged)}
      other -> other
    end
  end

  defp start({tag, index}, run) do
    call = call_from(tag)
    seq = :atomics.add_get(run.seq_ref, 1, 1)

    run.on_event.(
      {:tool_start,
       %{
         id: call[:id],
         name: call[:name],
         input: call[:input] || %{},
         event_seq: seq,
         correlation_id: run.corr_id
       }}
    )

    :telemetry.execute([:alloy, :tool, :start], %{event_seq: seq}, %{
      correlation_id: run.corr_id,
      turn: run.turn,
      tool_id: call[:id],
      tool_name: call[:name]
    })

    %{
      index: index,
      tag: tag,
      call: call,
      start_seq: seq,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  # Runs inside the task. Returns {:ok, text, structured_data | nil} or
  # {:error, model_visible_message, diagnostic_message}.
  defp invoke({:blocked, _call, reason}, _run), do: {:error, "Blocked: #{reason}", nil}

  defp invoke({:execute, call}, run) do
    case Map.fetch(run.tool_fns, call[:name]) do
      {:ok, tool} -> execute_tool(tool, call, run.context)
      :error -> {:error, "Unknown tool: #{call[:name]}", nil}
    end
  end

  defp execute_tool(tool, call, context) do
    case tool_execute(tool, call[:input] || %{}, context) do
      {:ok, text, data} when is_map(data) -> {:ok, maybe_truncate(text, tool), data}
      {:ok, text} -> {:ok, maybe_truncate(text, tool), nil}
      {:error, reason} -> {:error, reason, nil}
    end
  rescue
    e ->
      stacktrace = __STACKTRACE__

      Logger.error(
        "Tool #{call[:name]} crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(stacktrace)}"
      )

      {:error, tool_crash_message(call[:name], e, stacktrace),
       Exception.format(:error, e, stacktrace)}
  end

  defp exit_outcome(call, :timeout, run) do
    {:error,
     "Tool #{call[:name]} timed out after #{run.timeout}ms. " <>
       "Try a smaller input or raise :tool_timeout.", nil}
  end

  defp exit_outcome(call, reason, _run) do
    {:error,
     "Tool #{call[:name]} crashed during execution: #{inspect(exit_reason(reason))}. " <>
       "Check the input and try again.", nil}
  end

  # The model sees the reason without the stacktrace a throw carries.
  defp exit_reason({reason, [{_mod, _fun, _arity, _location} | _]}), do: reason
  defp exit_reason(reason), do: reason

  defp finish(started, outcome, run) do
    %{call: call, start_seq: start_seq} = started

    {block, error, structured_data} =
      case outcome do
        {:ok, text, data} ->
          {Message.tool_result_block(call[:id], text, false), nil, data}

        {:error, visible, diagnostic} ->
          {Message.tool_result_block(call[:id], visible, true), diagnostic || visible, nil}
      end

    meta = %{
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{},
      duration_ms: max(System.monotonic_time(:millisecond) - started.started_at, 0),
      error: error
    }

    end_seq = emit_end(meta, start_seq, run)

    meta =
      meta
      |> Map.merge(%{
        correlation_id: run.corr_id,
        start_event_seq: start_seq,
        end_event_seq: end_seq
      })
      |> maybe_put_structured_data(structured_data)

    {started.index, {block, meta}}
  end

  defp emit_end(meta, start_seq, run) do
    seq = :atomics.add_get(run.seq_ref, 1, 1)

    event =
      Map.merge(meta, %{event_seq: seq, correlation_id: run.corr_id, start_event_seq: start_seq})

    run.on_event.({:tool_end, event})

    :telemetry.execute(
      [:alloy, :tool, :stop],
      %{event_seq: seq, duration_ms: meta.duration_ms},
      %{
        correlation_id: run.corr_id,
        turn: run.turn,
        tool_id: meta.id,
        tool_name: meta.name,
        error: meta.error,
        start_event_seq: start_seq
      }
    )

    seq
  end

  defp call_from({:execute, c}), do: c
  defp call_from({:blocked, c, _}), do: c

  defp tool_crash_message(tool_name, exception, stacktrace) do
    "Tool #{tool_name} crashed: #{Exception.message(exception)} " <>
      "(#{format_top_stack_frame(stacktrace)}). Check the input and try again."
  end

  defp format_top_stack_frame([{module, function, arity_or_args, info} | _]) do
    arity = stack_arity(arity_or_args)
    file = info |> Keyword.get(:file, "unknown") |> to_string() |> Path.basename()
    line = Keyword.get(info, :line, "?")

    "#{inspect(module)}.#{function}/#{arity} at #{file}:#{line}"
  end

  defp format_top_stack_frame(_stacktrace), do: "unknown location"

  defp stack_arity(arity) when is_integer(arity), do: arity
  defp stack_arity(args) when is_list(args), do: length(args)

  defp maybe_put_structured_data(meta, nil), do: meta
  defp maybe_put_structured_data(meta, data), do: Map.put(meta, :structured_data, data)

  defp random_id, do: "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  # ── Tool dispatch (module or Alloy.Tool.Inline) ──────────────────────────

  defp tool_execute(%Inline{execute: fun}, input, ctx), do: fun.(input, ctx)
  defp tool_execute(mod, input, ctx), do: mod.execute(input, ctx)

  defp tool_max_result_chars(%Inline{max_result_chars: max}), do: max

  defp tool_max_result_chars(mod) do
    if function_exported?(mod, :max_result_chars, 0), do: mod.max_result_chars()
  end

  defp tool_sequential?(%Inline{concurrent?: concurrent?}), do: concurrent? == false

  defp tool_sequential?(mod) do
    function_exported?(mod, :concurrent?, 0) and mod.concurrent?() == false
  end

  defp maybe_truncate(text, tool) when is_binary(text) do
    case tool_max_result_chars(tool) do
      max when is_integer(max) and max > 0 ->
        len = String.length(text)

        if len > max do
          head = div(max * 4, 5)
          tail = max - head

          String.slice(text, 0, head) <>
            "\n\n[truncated " <>
            Integer.to_string(len) <>
            " -> " <>
            Integer.to_string(max) <>
            " chars]\n\n" <>
            String.slice(text, -tail, tail)
        else
          text
        end

      _unlimited_or_nil ->
        text
    end
  end

  defp maybe_truncate(text, _tool), do: text

  defp build_context(%State{} = state) do
    Map.merge(state.config.context, %{
      working_directory: state.config.working_directory
    })
  end
end
