defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Alloy.Agent.{Events, State}
  alias Alloy.Context.Compactor
  alias Alloy.{Message, Middleware}
  alias Alloy.Provider.Retry
  alias Alloy.Tool.Executor

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

    # Compute a hard deadline ONCE for the entire loop, leaving headroom
    # so the retry logic never overshoots the caller-side timeout.
    deadline =
      System.monotonic_time(:millisecond) + state.config.timeout_ms - @deadline_headroom_ms

    state
    |> do_turn(opts, deadline)
    |> State.materialize()
  end

  defp do_turn(%State{turn: turn, config: config} = state, _opts, _deadline)
       when turn >= config.max_turns do
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state, opts, deadline) do
    state = Compactor.maybe_compact(state)

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
          {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage}} ->
            state =
              state
              |> State.append_messages(new_msgs)
              |> State.increment_turn()
              |> State.merge_usage(usage)

            handle_tool_use(state, new_msgs, opts, deadline)

          {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage}} ->
            state =
              state
              |> State.append_messages(new_msgs)
              |> State.increment_turn()
              |> State.merge_usage(usage)

            case Middleware.run(:after_completion, state) do
              {:halted, reason} ->
                %{state | status: :halted, error: "Halted by middleware: #{reason}"}

              %State{} = state ->
                %{state | status: :completed}
            end

          {:error, reason} ->
            state = %{state | status: :error, error: reason}

            case Middleware.run(:on_error, state) do
              {:halted, halted_reason} ->
                %{state | status: :halted, error: "Halted by middleware: #{halted_reason}"}

              %State{} = state ->
                state
            end
        end
    end
  end

  defp handle_tool_use(%State{} = state, new_msgs, opts, deadline) do
    case Middleware.run(:after_tool_request, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
        tool_calls = extract_tool_calls(new_msgs)
        on_event = fn raw_event -> Events.emit(opts, state.turn, raw_event) end
        event_seq_ref = Keyword.get(opts, :event_seq_ref)
        event_correlation_id = Keyword.get(opts, :event_correlation_id)
        event_turn = state.turn

        case Executor.execute_all(
               tool_calls,
               state.tool_fns,
               state,
               on_event: on_event,
               event_seq_ref: event_seq_ref,
               event_correlation_id: event_correlation_id,
               event_turn: event_turn
             ) do
          {:halted, reason} ->
            %{state | status: :halted, error: "Halted by middleware: #{reason}"}

          {:ok, result_msg, tool_call_meta} ->
            state =
              state
              |> State.append_messages(result_msg)
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

  defp build_provider_config(%State{config: config}) do
    Map.put(config.provider_config, :system_prompt, config.system_prompt)
  end

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end
end
