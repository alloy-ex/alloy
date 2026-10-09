defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Alloy.Agent.State
  alias Alloy.Context.Compactor
  alias Alloy.Events
  alias Alloy.Memory.Router, as: MemoryRouter
  alias Alloy.{Message, Middleware}
  alias Alloy.Provider.{Error, Retry}
  alias Alloy.Tool.Executor

  require Logger

  # Buffer subtracted from timeout_ms when computing the retry deadline.
  # Ensures the retry loop finishes before the caller-side timeout fires.
  # Note: timeout_ms values <= this constant effectively disable retries.
  @deadline_headroom_ms 5_000

  @doc """
  Run the agent loop until completion, error, or max turns.

  Takes an initialized `State` with messages and returns the
  final state with status set to `:completed`, `:error`, or `:max_turns`.

  Each turn is reported with `:telemetry.span/3` as `[:alloy, :turn, :start]`
  and `[:alloy, :turn, :stop]`, or `[:alloy, :turn, :exception]` when the turn
  raises. A turn's stop event fires when that turn ends; its `:status` is
  `:running` when the loop goes on to another turn and the final status
  otherwise.

  ## Options

    - `:streaming` - boolean, whether to use streaming (default: `false`)
    - `:on_chunk` - function called for each streamed chunk (default: no-op)
    - `:on_event` - function called with event envelopes:
      `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event:, payload:}`
      (default: no-op)
  """
  @spec run_loop(State.t(), keyword()) :: State.t()
  def run_loop(%State{} = state, opts \\ []) do
    opts = Events.normalize_opts(state, opts)

    # Compute a hard deadline ONCE for the entire loop, leaving headroom
    # so the retry logic never overshoots the caller-side timeout.
    deadline =
      System.monotonic_time(:millisecond) + state.config.timeout_ms - @deadline_headroom_ms

    run_span(state.config.provider_config[:model], fn ->
      state
      |> loop(opts, deadline)
      |> State.materialize()
    end)
  end

  # :telemetry.span/3 accepts extra stop measurements only from telemetry 1.3,
  # and the run stop event has always carried :duration_ms, so the run span is
  # emitted by hand with the same start/stop/exception shape.
  defp run_span(model, fun) do
    started = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:alloy, :run, :start],
      %{system_time: System.system_time()},
      %{model: model}
    )

    try do
      final_state = fun.()

      :telemetry.execute(
        [:alloy, :run, :stop],
        %{duration_ms: System.monotonic_time(:millisecond) - started},
        %{status: final_state.status, turns: final_state.turn, model: model}
      )

      final_state
    catch
      kind, reason ->
        :telemetry.execute(
          [:alloy, :run, :exception],
          %{duration_ms: System.monotonic_time(:millisecond) - started},
          %{model: model, kind: kind, reason: reason, stacktrace: __STACKTRACE__}
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp loop(%State{turn: turn, config: config} = state, _opts, _deadline)
       when turn >= config.max_turns do
    %{state | status: :max_turns}
  end

  defp loop(%State{} = state, opts, deadline) do
    if budget_exceeded?(state) do
      %{state | status: :budget_exceeded}
    else
      case run_turn(state, opts, deadline) do
        {:continue, state} -> loop(state, opts, deadline)
        {:halt, state} -> state
      end
    end
  end

  # One turn: compaction, one provider response and the tool calls it asks
  # for. Every step returns {:continue, state} to start another turn or
  # {:halt, state} with the final status set.
  defp run_turn(%State{} = state, opts, deadline) do
    turn = state.turn + 1

    :telemetry.span([:alloy, :turn], %{turn: turn}, fn ->
      step =
        with {:continue, state} <- compact(state, turn) do
          complete(state, opts, deadline, false)
        end

      {step, %{turn: turn, status: step_status(step)}}
    end)
  end

  defp step_status({:continue, %State{}}), do: :running
  defp step_status({:halt, %State{status: status}}), do: status

  defp compact(%State{} = state, turn) do
    messages_before = length(State.messages(state))

    case Compactor.maybe_compact(state, turn: turn) do
      {:unchanged, state} ->
        {:continue, state}

      {:compacted, state} ->
        :telemetry.execute(
          [:alloy, :compaction, :done],
          %{messages_before: messages_before, messages_after: length(State.messages(state))},
          %{turn: turn}
        )

        run_middleware(:after_compaction, state)
    end
  end

  defp complete(%State{} = state, opts, deadline, prompt_retried?) do
    with {:continue, state} <- run_middleware(:before_completion, state) do
      case request(state, opts, deadline) do
        {:ok, %{stop_reason: :refusal} = response} ->
          {:halt, refuse(state, response)}

        {:ok, %{stop_reason: stop_reason, messages: new_msgs} = response} ->
          state
          |> State.append_messages(new_msgs)
          |> account_response(response)
          |> continue_after(stop_reason, new_msgs, opts)

        {:error, reason} ->
          handle_provider_error(reason, state, opts, deadline, prompt_retried?)
      end
    end
  end

  defp request(%State{} = state, opts, deadline) do
    provider = state.config.provider
    provider_config = build_provider_config(state)
    provider_event_turn = state.turn + 1

    streaming? =
      Keyword.get(opts, :streaming, false) &&
        (Code.ensure_loaded(provider) == {:module, provider} &&
           function_exported?(provider, :stream, 4))

    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

    on_event = fn raw_event ->
      Events.emit(opts, provider_event_turn, raw_event)
    end

    provider_config =
      if streaming?,
        do: Map.put(provider_config, :on_event, on_event),
        else: provider_config

    Retry.call_with_retry(state, provider, provider_config, streaming?, on_chunk, deadline)
  end

  defp account_response(state, %{stop_reason: stop_reason, usage: usage} = response) do
    %{state | stop_reason: stop_reason}
    |> State.increment_turn()
    |> State.merge_usage(usage)
    |> State.merge_provider_state(Map.get(response, :provider_state))
    |> State.put_provider_response_metadata(Map.get(response, :response_metadata))
  end

  defp continue_after(state, :tool_use, new_msgs, opts) do
    case extract_tool_calls(new_msgs) do
      # Only server-executed tools ran: there is nothing for the client to
      # answer, and an empty tool-results message is rejected by every API.
      [] -> finish(state)
      calls -> handle_tool_use(state, calls, opts)
    end
  end

  defp continue_after(state, :end_turn, _new_msgs, _opts), do: finish(state)

  defp continue_after(state, :pause_turn, _new_msgs, _opts), do: {:continue, state}

  defp continue_after(state, :max_tokens, new_msgs, _opts) do
    case extract_tool_calls(new_msgs) do
      [] -> finish(state)
      calls -> {:halt, abandon_truncated_tool_calls(state, calls)}
    end
  end

  defp continue_after(state, stop_reason, _new_msgs, _opts) do
    {:halt, fail(state, "Provider returned an unsupported stop_reason: #{inspect(stop_reason)}")}
  end

  # Refused output must be discarded, so the response's messages are not kept.
  defp refuse(state, response) do
    details = get_in(response, [:response_metadata, :stop_details])

    reason =
      case details do
        nil -> "The model refused to continue (stop_reason: refusal)"
        details -> "The model refused to continue (stop_reason: refusal): #{inspect(details)}"
      end

    state
    |> account_response(response)
    |> fail(reason)
  end

  # A tool call cut off by max_tokens has incomplete arguments, so it must not
  # run. Answer each call with an error so the transcript stays valid for a
  # follow-up request, then fail the run.
  defp abandon_truncated_tool_calls(state, calls) do
    reason = "Output hit the max_tokens limit while writing a tool call; raise :max_tokens"

    results =
      Enum.map(calls, &Message.tool_result_block(&1.id, "Not executed: #{reason}", true))

    state
    |> State.append_messages(Message.tool_results(results))
    |> fail(reason)
  end

  # Result.error stays a string for compatibility; the structured error is
  # kept alongside it for callers that want the kind, status or code.
  defp fail(state, %Error{} = error) do
    state
    |> State.merge_run_metadata(%{provider_error: error})
    |> fail(Exception.message(error))
  end

  defp fail(state, reason) do
    state = %{state | status: :error, error: reason}

    case Middleware.run(:on_error, state) do
      {:halted, halted_reason} -> halt(state, halted_reason)
      %State{} = state -> state
    end
  end

  defp run_middleware(hook, %State{} = state) do
    case Middleware.run(hook, state) do
      {:halted, reason} -> {:halt, halt(state, reason)}
      %State{} = state -> {:continue, state}
    end
  end

  defp halt(%State{} = state, reason),
    do: %{state | status: :halted, error: "Halted by middleware: #{reason}"}

  defp handle_provider_error(reason, state, opts, deadline, false = _prompt_retried?) do
    if prompt_too_long?(reason) do
      Logger.info("[Turn] Prompt too long — forcing compaction and retrying")

      :telemetry.execute(
        [:alloy, :turn, :prompt_too_long_recovery],
        %{},
        %{turn: state.turn + 1}
      )

      {next, state} =
        state
        |> Compactor.force_compact()
        |> complete(opts, deadline, true)

      {next, State.merge_run_metadata(state, %{prompt_too_long_recovery: true})}
    else
      {:halt, fail(state, reason)}
    end
  end

  defp handle_provider_error(reason, state, _opts, _deadline, true = _prompt_retried?),
    do: {:halt, fail(state, reason)}

  defp handle_tool_use(%State{} = state, tool_calls, opts) do
    with {:continue, state} <- run_middleware(:after_tool_request, state) do
      {memory_calls, regular_calls} = Enum.split_with(tool_calls, &MemoryRouter.memory_call?/1)
      on_event = fn raw_event -> Events.emit(opts, state.turn, raw_event) end
      event_seq_ref = Keyword.get(opts, :event_seq_ref)
      event_correlation_id = Keyword.get(opts, :event_correlation_id)
      event_turn = state.turn

      memory_results =
        case {memory_calls, state.config.memory} do
          {[], _} -> []
          {_calls, nil} -> []
          {calls, memory} -> MemoryRouter.dispatch_all(calls, memory)
        end

      regular_result =
        case regular_calls do
          [] ->
            {:ok, nil, []}

          calls ->
            Executor.execute_all(
              calls,
              state.tool_fns,
              state,
              on_event: on_event,
              event_seq_ref: event_seq_ref,
              event_correlation_id: event_correlation_id,
              event_turn: event_turn
            )
        end

      case regular_result do
        {:halted, reason} ->
          {:halt, halt(state, reason)}

        {:ok, regular_msg, tool_call_meta} ->
          state
          |> State.append_messages(merge_tool_results(tool_calls, memory_results, regular_msg))
          |> State.append_tool_calls(tool_call_meta)
          |> then(&run_middleware(:after_tool_execution, &1))
      end
    end
  end

  # Reassemble tool_result blocks in the original tool_call order,
  # regardless of whether each result came from the memory router or
  # the generic tool executor. Tool-call IDs are unique per turn, so
  # id-keyed lookup is safe.
  defp merge_tool_results(tool_calls, memory_results, regular_msg) do
    regular_blocks =
      case regular_msg do
        %Message{content: blocks} when is_list(blocks) -> blocks
        nil -> []
      end

    by_id =
      Enum.reduce(memory_results ++ regular_blocks, %{}, fn block, acc ->
        Map.put(acc, block.tool_use_id, block)
      end)

    ordered = Enum.map(tool_calls, fn %{id: id} -> Map.fetch!(by_id, id) end)
    Message.tool_results(ordered)
  end

  defp build_provider_config(%State{config: config, provider_state: provider_state}) do
    config.provider_config
    |> Map.put(:system_prompt, config.system_prompt)
    |> Map.put(:provider_state, provider_state)
    |> maybe_put_memory(config.memory)
  end

  defp maybe_put_memory(provider_config, nil), do: provider_config
  defp maybe_put_memory(provider_config, memory), do: Map.put(provider_config, :memory, memory)

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp prompt_too_long?(%Error{kind: kind}), do: kind == :context_overflow
  defp prompt_too_long?(reason) when is_binary(reason), do: Error.overflow_text?(reason)
  defp prompt_too_long?(_reason), do: false

  defp finish(state) do
    if until_tool_pending?(state) do
      reminder =
        Message.user(
          "Continue. You must call the #{state.config.until_tool} tool before finishing."
        )

      {:continue, State.append_messages(state, [reminder])}
    else
      with {:continue, state} <- run_middleware(:after_completion, state) do
        {:halt, %{state | status: :completed}}
      end
    end
  end

  defp until_tool_pending?(%State{config: %{until_tool: nil}}), do: false

  defp until_tool_pending?(%State{config: %{until_tool: name}, tool_calls: calls}) do
    not Enum.any?(calls, fn call -> call[:name] == name end)
  end

  defp budget_exceeded?(%State{config: %{max_budget_cents: nil}}), do: false

  defp budget_exceeded?(%State{config: %{max_budget_cents: max}, usage: usage}) do
    usage.estimated_cost_cents >= max
  end
end
