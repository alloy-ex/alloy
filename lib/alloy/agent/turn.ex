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

  ## Options

    - `:streaming` - boolean, whether to use streaming (default: `false`)
    - `:on_chunk` - function called for each streamed chunk (default: no-op)
  """
  @spec run_loop(State.t(), keyword()) :: State.t()
  def run_loop(%State{} = state, opts \\ []) do
    do_turn(state, opts)
  end

  defp do_turn(%State{turn: turn, config: config} = state, _opts) when turn >= config.max_turns do
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state, opts) do
    state = Compactor.maybe_compact(state)

    case Middleware.run(:before_completion, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
        provider = state.config.provider
        provider_config = build_provider_config(state)

        streaming? =
          Keyword.get(opts, :streaming, false) &&
            (Code.ensure_loaded(provider) == {:module, provider} &&
               function_exported?(provider, :stream, 4))

        on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

        result = call_provider_with_retry(state, provider, provider_config, streaming?, on_chunk)

        case result do
          {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage}} ->
            state =
              state
              |> State.append_messages(new_msgs)
              |> State.increment_turn()
              |> State.merge_usage(usage)

            handle_tool_use(state, new_msgs, opts)

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

  defp handle_tool_use(%State{} = state, new_msgs, opts) do
    case Middleware.run(:after_completion, state) do
      {:halted, reason} ->
        %{state | status: :halted, error: "Halted by middleware: #{reason}"}

      %State{} = state ->
        tool_calls = extract_tool_calls(new_msgs)

        case Executor.execute_all(tool_calls, state.tool_fns, state) do
          {:halted, reason} ->
            %{state | status: :halted, error: "Halted by middleware: #{reason}"}

          result_msg ->
            state = State.append_messages(state, result_msg)

            case Middleware.run(:after_tool_execution, state) do
              {:halted, reason} ->
                %{state | status: :halted, error: "Halted by middleware: #{reason}"}

              %State{} = state ->
                do_turn(state, opts)
            end
        end
    end
  end

  defp call_provider_with_retry(state, provider, provider_config, streaming?, on_chunk) do
    do_provider_call(
      state,
      provider,
      provider_config,
      streaming?,
      on_chunk,
      state.config.max_retries
    )
  end

  defp do_provider_call(state, provider, provider_config, streaming?, on_chunk, retries_left) do
    {result, chunks_emitted?} =
      call_provider(provider, state, provider_config, streaming?, on_chunk)

    case result do
      {:ok, _} = success ->
        success

      {:error, reason} when retries_left > 0 ->
        if retryable?(reason) and not chunks_emitted? do
          attempt = state.config.max_retries - retries_left + 1
          backoff = round(state.config.retry_backoff_ms * :math.pow(2, attempt - 1))

          # NOTE: Process.sleep/1 blocks this GenServer process. During backoff,
          # health/1 and other calls will be unreachable. This is intentional —
          # retry backoff is brief and bounded, and the alternative (timer-based)
          # would add significant complexity for marginal benefit.
          Process.sleep(backoff)

          do_provider_call(
            state,
            provider,
            provider_config,
            streaming?,
            on_chunk,
            retries_left - 1
          )
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

    wrapped_chunk = fn chunk ->
      :atomics.put(ref, 1, 1)
      on_chunk.(chunk)
    end

    result = provider.stream(state.messages, state.tool_defs, provider_config, wrapped_chunk)
    {result, :atomics.get(ref, 1) == 1}
  end

  defp call_provider(provider, state, provider_config, false = _streaming?, _on_chunk) do
    {provider.complete(state.messages, state.tool_defs, provider_config), false}
  end

  # HTTP status errors — providers return strings via parse_error/2.
  # The generic fallback format is "HTTP <status>: <body>".
  # Retryable: 429 (rate limit) and 5xx server errors.
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
  # The inspect output includes the error reason atoms as text.
  defp retryable?("HTTP request failed: " <> rest) do
    String.contains?(rest, ":econnrefused") or
      String.contains?(rest, ":closed") or
      String.contains?(rest, ":timeout")
  end

  # Atom :timeout kept for any caller that passes atoms directly.
  defp retryable?(:timeout), do: true
  defp retryable?(_), do: false

  defp build_provider_config(%State{config: config}) do
    Map.put(config.provider_config, :system_prompt, config.system_prompt)
  end

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end
end
