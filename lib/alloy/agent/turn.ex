defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  ~80 lines of actual logic.
  """

  alias Alloy.Agent.State
  alias Alloy.Context.Compactor
  alias Alloy.{Message, Middleware}
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
    opts = normalize_runtime_opts(state, opts)

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
          emit_runtime_event(opts, provider_event_turn, raw_event)
        end

        provider_config =
          if streaming?,
            do: Map.put(provider_config, :on_event, on_event),
            else: provider_config

        result =
          call_provider_with_retry(
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
    case Middleware.run(:after_completion, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
        tool_calls = extract_tool_calls(new_msgs)
        on_event = fn raw_event -> emit_runtime_event(opts, state.turn, raw_event) end
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

  defp call_provider_with_retry(state, provider, provider_config, streaming?, on_chunk, deadline) do
    do_provider_call(
      state,
      provider,
      provider_config,
      streaming?,
      on_chunk,
      state.config.max_retries,
      deadline
    )
  end

  defp do_provider_call(
         state,
         provider,
         provider_config,
         streaming?,
         on_chunk,
         retries_left,
         deadline
       ) do
    # Inject receive_timeout so hung HTTP requests can't overshoot the deadline.
    # All providers read :req_options from config, so this flows through automatically.
    provider_config = inject_receive_timeout(provider_config, deadline)

    {result, chunks_emitted?} =
      call_provider(provider, state, provider_config, streaming?, on_chunk)

    case result do
      {:ok, _} = success ->
        success

      {:error, reason} when retries_left > 0 ->
        if retryable?(reason) and not chunks_emitted? do
          attempt = state.config.max_retries - retries_left + 1
          base = round(state.config.retry_backoff_ms * :math.pow(2, attempt - 1))
          # Full jitter: uniform random in [0, 2*base) — prevents thundering herd
          # when multiple agents hit the same rate limit simultaneously.
          backoff = :rand.uniform(base * 2)
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining < backoff do
            # Not enough time left — return the error rather than sleeping
            # past the GenServer.call timeout.
            {:error, reason}
          else
            Process.sleep(backoff)

            do_provider_call(
              state,
              provider,
              provider_config,
              streaming?,
              on_chunk,
              retries_left - 1,
              deadline
            )
          end
        else
          {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Calls the provider and returns {result, chunks_emitted?}.
  # For streaming calls, wraps on_chunk to detect whether any chunks were
  # delivered before the call returned. This prevents retrying mid-stream
  # failures that already produced partial output.
  defp call_provider(provider, state, provider_config, true = _streaming?, on_chunk) do
    ref = :atomics.new(1, signed: false)

    original_on_event = Map.get(provider_config, :on_event, fn _ -> :ok end)

    wrapped_chunk = fn chunk ->
      :atomics.put(ref, 1, 1)
      on_chunk.(chunk)
      original_on_event.({:text_delta, chunk})
    end

    wrapped_on_event = fn event ->
      :atomics.put(ref, 1, 1)
      original_on_event.(event)
    end

    provider_config = Map.put(provider_config, :on_event, wrapped_on_event)

    messages = State.messages(state)
    result = provider.stream(messages, state.tool_defs, provider_config, wrapped_chunk)
    {result, :atomics.get(ref, 1) == 1}
  end

  defp call_provider(provider, state, provider_config, false = _streaming?, _on_chunk) do
    messages = State.messages(state)
    {provider.complete(messages, state.tool_defs, provider_config), false}
  end

  # HTTP status errors — providers return strings via parse_error/2.
  # The generic fallback format is "HTTP <status>: <body>".
  # Retryable: 408 (request timeout), 429 (rate limit), and 5xx server errors.
  defp retryable?("HTTP 408:" <> _), do: true
  defp retryable?("HTTP 429:" <> _), do: true
  defp retryable?("HTTP 500:" <> _), do: true
  defp retryable?("HTTP 502:" <> _), do: true
  defp retryable?("HTTP 503:" <> _), do: true
  defp retryable?("HTTP 504:" <> _), do: true

  # Anthropic-formatted rate limit errors: "rate_limit_error: ..."
  defp retryable?("rate_limit_error:" <> _), do: true

  # OpenAI-formatted rate limit errors: "rate_limit_exceeded: ..."
  defp retryable?("rate_limit_exceeded:" <> _), do: true

  # Anthropic 529 — model overloaded, always transient.
  defp retryable?("overloaded_error:" <> _), do: true

  # OpenAI 500 server error.
  defp retryable?("server_error:" <> _), do: true

  # Google Gemini — rate limited (429), internal error (500), unavailable (503).
  defp retryable?("RESOURCE_EXHAUSTED:" <> _), do: true
  defp retryable?("INTERNAL:" <> _), do: true
  defp retryable?("UNAVAILABLE:" <> _), do: true

  # Network-level failures from Req/Finch/Mint.
  # Providers wrap these as: "HTTP request failed: #{inspect(reason)}"
  # Match the bare atom name (e.g. "econnrefused") rather than the
  # inspect-formatted version (":econnrefused") so that changes in
  # Req/Mint struct formatting don't silently break retry matching.
  defp retryable?("HTTP request failed: " <> rest) do
    String.contains?(rest, "econnrefused") or
      String.contains?(rest, "closed") or
      String.contains?(rest, "timeout") or
      String.contains?(rest, "unprocessed")
  end

  # Atom :timeout kept for any caller that passes atoms directly.
  defp retryable?(:timeout), do: true
  defp retryable?(_), do: false

  # Sets receive_timeout in the provider's req_options based on remaining deadline.
  # This prevents a single hung HTTP request from overshooting the overall timeout.
  # Uses Keyword.put to override any user-set value — the deadline takes precedence.
  defp inject_receive_timeout(provider_config, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    # Floor at 1s so we don't set absurdly short timeouts, but also
    # don't overshoot the deadline when remaining time is under 5s.
    timeout = max(remaining, 1_000)
    existing = Map.get(provider_config, :req_options, [])
    Map.put(provider_config, :req_options, Keyword.put(existing, :receive_timeout, timeout))
  end

  defp build_provider_config(%State{config: config}) do
    Map.put(config.provider_config, :system_prompt, config.system_prompt)
  end

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp normalize_runtime_opts(%State{} = state, opts) do
    on_event = Keyword.get(opts, :on_event) || fn _event -> :ok end

    opts
    |> Keyword.put(:on_event, on_event)
    |> put_new_lazy(:event_seq_ref, fn -> :atomics.new(1, signed: false) end)
    |> put_new_lazy(:event_correlation_id, fn -> build_event_correlation_id(state) end)
  end

  defp put_new_lazy(opts, key, producer) when is_list(opts) and is_function(producer, 0) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      Keyword.put(opts, key, producer.())
    end
  end

  defp build_event_correlation_id(%State{} = state) do
    context = state.config.context

    cond do
      is_binary(Map.get(context, :request_id)) ->
        Map.get(context, :request_id)

      is_binary(Map.get(context, :correlation_id)) ->
        Map.get(context, :correlation_id)

      true ->
        state.agent_id <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    end
  end

  defp emit_runtime_event(opts, turn, raw_event) do
    on_event = Keyword.get(opts, :on_event) || fn _event -> :ok end
    event_seq_ref = Keyword.get(opts, :event_seq_ref)
    correlation_id = Keyword.get(opts, :event_correlation_id)

    envelope = build_event_envelope(raw_event, event_seq_ref, correlation_id, turn)
    on_event.(envelope)

    :telemetry.execute(
      [:alloy, :event],
      %{seq: envelope.seq},
      %{
        v: envelope.v,
        event: envelope.event,
        correlation_id: envelope.correlation_id,
        turn: envelope.turn
      }
    )
  end

  defp build_event_envelope(%{v: 1} = envelope, _seq_ref, _correlation_id, _turn), do: envelope

  defp build_event_envelope({event, payload}, seq_ref, correlation_id, turn)
       when is_atom(event) do
    {seq, effective_correlation_id, normalized_payload} =
      normalize_event_fields(event, payload, seq_ref, correlation_id)

    %{
      v: 1,
      seq: seq,
      correlation_id: effective_correlation_id,
      turn: turn,
      ts_ms: System.system_time(:millisecond),
      event: event,
      payload: normalized_payload
    }
  end

  defp build_event_envelope(raw_event, seq_ref, correlation_id, turn) do
    %{
      v: 1,
      seq: next_event_seq(seq_ref),
      correlation_id: correlation_id,
      turn: turn,
      ts_ms: System.system_time(:millisecond),
      event: :runtime_event,
      payload: raw_event
    }
  end

  defp normalize_event_fields(event, payload, seq_ref, correlation_id)
       when event in [:tool_start, :tool_end] and is_map(payload) do
    seq = Map.get(payload, :event_seq) || next_event_seq(seq_ref)
    effective_correlation_id = Map.get(payload, :correlation_id) || correlation_id
    normalized_payload = Map.drop(payload, [:event_seq, :correlation_id])

    {seq, effective_correlation_id, normalized_payload}
  end

  defp normalize_event_fields(_event, payload, seq_ref, correlation_id) do
    {next_event_seq(seq_ref), correlation_id, payload}
  end

  defp next_event_seq(ref) do
    :atomics.add_get(ref, 1, 1)
  end
end
