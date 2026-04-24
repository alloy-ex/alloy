defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Alloy.Agent.{Events, State}
  alias Alloy.Context.Compactor
  alias Alloy.Memory.Router, as: MemoryRouter
  alias Alloy.{Message, Middleware}
  alias Alloy.Provider.Retry
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
    run_start = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:alloy, :run, :start],
      %{system_time: System.system_time()},
      %{model: state.config.provider_config[:model]}
    )

    # Compute a hard deadline ONCE for the entire loop, leaving headroom
    # so the retry logic never overshoots the caller-side timeout.
    deadline =
      System.monotonic_time(:millisecond) + state.config.timeout_ms - @deadline_headroom_ms

    result =
      state
      |> do_turn(opts, deadline)
      |> State.materialize()

    :telemetry.execute(
      [:alloy, :run, :stop],
      %{duration_ms: System.monotonic_time(:millisecond) - run_start},
      %{
        status: result.status,
        turns: result.turn,
        model: state.config.provider_config[:model]
      }
    )

    result
  end

  defp do_turn(%State{turn: turn, config: config} = state, _opts, _deadline)
       when turn >= config.max_turns do
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state, opts, deadline) do
    if budget_exceeded?(state) do
      %{state | status: :budget_exceeded}
    else
      do_turn_inner(state, opts, deadline)
    end
  end

  defp do_turn_inner(%State{} = state, opts, deadline) do
    turn_number = state.turn + 1

    :telemetry.execute(
      [:alloy, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: turn_number}
    )

    messages_before = length(State.messages(state))
    {compaction_status, state} = Compactor.maybe_compact(state)

    state =
      case compaction_status do
        :compacted ->
          :telemetry.execute(
            [:alloy, :compaction, :done],
            %{messages_before: messages_before, messages_after: length(State.messages(state))},
            %{turn: turn_number}
          )

          case Middleware.run(:after_compaction, state) do
            {:halted, reason} ->
              %{state | status: :halted, error: "Halted by middleware: #{reason}"}

            %State{} = state ->
              state
          end

        :unchanged ->
          state
      end

    if state.status == :halted do
      :telemetry.execute([:alloy, :turn, :stop], %{}, %{turn: turn_number, status: :halted})
      state
    else
      result = do_turn_after_compaction(state, opts, deadline)

      :telemetry.execute(
        [:alloy, :turn, :stop],
        %{},
        %{turn: turn_number, status: result.status}
      )

      result
    end
  end

  defp do_turn_after_compaction(%State{} = state, opts, deadline, prompt_retried? \\ false) do
    case Middleware.run(:before_completion, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
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

        result =
          Retry.call_with_retry(
            state,
            provider,
            provider_config,
            streaming?,
            on_chunk,
            deadline
          )

        case result do
          {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage} = provider_response} ->
            state =
              state
              |> State.append_messages(new_msgs)
              |> State.increment_turn()
              |> State.merge_usage(usage)
              |> State.merge_provider_state(Map.get(provider_response, :provider_state))
              |> State.put_provider_response_metadata(
                Map.get(provider_response, :response_metadata)
              )

            handle_tool_use(state, new_msgs, opts, deadline)

          {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage} = provider_response} ->
            state =
              state
              |> State.append_messages(new_msgs)
              |> State.increment_turn()
              |> State.merge_usage(usage)
              |> State.merge_provider_state(Map.get(provider_response, :provider_state))
              |> State.put_provider_response_metadata(
                Map.get(provider_response, :response_metadata)
              )

            maybe_complete_or_continue(state, opts, deadline)

          {:error, reason} ->
            handle_provider_error(reason, state, opts, deadline, prompt_retried?)
        end
    end
  end

  defp handle_provider_error(reason, state, opts, deadline, prompt_retried?) do
    if not prompt_retried? and prompt_too_long?(reason) do
      Logger.info("[Turn] Prompt too long — forcing compaction and retrying")

      :telemetry.execute(
        [:alloy, :turn, :prompt_too_long_recovery],
        %{},
        %{turn: state.turn + 1}
      )

      state
      |> Compactor.force_compact()
      |> do_turn_after_compaction(opts, deadline, true)
      |> State.merge_run_metadata(%{prompt_too_long_recovery: true})
    else
      state = %{state | status: :error, error: reason}

      case Middleware.run(:on_error, state) do
        {:halted, halted_reason} ->
          %{state | status: :halted, error: "Halted by middleware: #{halted_reason}"}

        %State{} = state ->
          state
      end
    end
  end

  defp handle_tool_use(%State{} = state, new_msgs, opts, deadline) do
    case Middleware.run(:after_tool_request, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
        tool_calls = extract_tool_calls(new_msgs)
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
            %{state | status: :halted, error: "Halted by middleware: #{reason}"}

          {:ok, regular_msg, tool_call_meta} ->
            merged_msg = merge_tool_results(tool_calls, memory_results, regular_msg)

            state =
              state
              |> State.append_messages(merged_msg)
              |> State.append_tool_calls(tool_call_meta)

            case Middleware.run(:after_tool_execution, state) do
              {:halted, reason} ->
                %{state | status: :halted, error: "Halted by middleware: #{reason}"}

              %State{} = state ->
                do_turn(state, opts, deadline)
            end
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

  defp prompt_too_long?(reason) when is_binary(reason) do
    String.contains?(reason, "prompt is too long") or
      String.contains?(reason, "context_length_exceeded") or
      String.contains?(reason, "maximum context length")
  end

  defp prompt_too_long?(_), do: false

  defp maybe_complete_or_continue(state, opts, deadline) do
    if until_tool_pending?(state) do
      state
      |> State.append_messages([
        Message.user(
          "Continue. You must call the #{state.config.until_tool} tool before finishing."
        )
      ])
      |> do_turn(opts, deadline)
    else
      case Middleware.run(:after_completion, state) do
        {:halted, reason} ->
          %{state | status: :halted, error: "Halted by middleware: #{reason}"}

        %State{} = state ->
          %{state | status: :completed}
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
