defmodule Alloy.Provider.Retry do
  @moduledoc """
  Provider retry, backoff, fallback, and streaming dispatch logic.

  Handles exponential backoff with full jitter, retryable error
  classification, fallback provider chains, and receive-timeout
  injection. Extracted from `Alloy.Agent.Turn` to separate
  provider-oriented concerns from agent loop control flow.
  """

  alias Alloy.Agent.State

  @doc """
  Call a provider with retry, backoff, and fallback logic.

  Single entry point for all provider calls. Retries on transient errors
  with exponential backoff and jitter, then falls back to configured
  fallback providers if the primary provider fails.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec call_with_retry(State.t(), module(), map(), boolean(), function(), integer()) ::
          {:ok, map()} | {:error, term()}
  def call_with_retry(state, provider, provider_config, streaming?, on_chunk, deadline) do
    {result, chunks_emitted?} =
      do_provider_call(
        state,
        provider,
        provider_config,
        streaming?,
        on_chunk,
        state.config.max_retries,
        deadline
      )

    case result do
      {:ok, _} = success ->
        success

      # Once any streamed output/event was emitted, never switch providers:
      # mixing chunks from multiple providers in one stream breaks turn semantics.
      {:error, _reason} = error when chunks_emitted? ->
        error

      {:error, _reason} = error ->
        try_fallback_providers(state, provider_config, streaming?, on_chunk, deadline, error)
    end
  end

  @doc false
  @spec retryable?(term()) :: boolean()

  # HTTP status errors — providers return strings via parse_error/2.
  # The generic fallback format is "HTTP <status>: <body>".
  # Retryable: 408 (request timeout), 429 (rate limit), and 5xx server errors.
  def retryable?("HTTP 408:" <> _), do: true
  def retryable?("HTTP 429:" <> _), do: true
  def retryable?("HTTP 500:" <> _), do: true
  def retryable?("HTTP 502:" <> _), do: true
  def retryable?("HTTP 503:" <> _), do: true
  def retryable?("HTTP 504:" <> _), do: true

  # Anthropic-formatted rate limit errors: "rate_limit_error: ..."
  def retryable?("rate_limit_error:" <> _), do: true

  # OpenAI-formatted rate limit errors: "rate_limit_exceeded: ..."
  def retryable?("rate_limit_exceeded:" <> _), do: true

  # Anthropic 529 — model overloaded, always transient.
  def retryable?("overloaded_error:" <> _), do: true

  # OpenAI 500 server error.
  def retryable?("server_error:" <> _), do: true

  # Google Gemini — rate limited (429), internal error (500), unavailable (503).
  def retryable?("RESOURCE_EXHAUSTED:" <> _), do: true
  def retryable?("INTERNAL:" <> _), do: true
  def retryable?("UNAVAILABLE:" <> _), do: true

  # Network-level failures from Req/Finch/Mint.
  # Providers wrap these as: "HTTP request failed: #{inspect(reason)}"
  # Match the bare atom name (e.g. "econnrefused") rather than the
  # inspect-formatted version (":econnrefused") so that changes in
  # Req/Mint struct formatting don't silently break retry matching.
  def retryable?("HTTP request failed: " <> rest) do
    String.contains?(rest, "econnrefused") or
      String.contains?(rest, "closed") or
      String.contains?(rest, "timeout") or
      String.contains?(rest, "unprocessed")
  end

  # Atom :timeout kept for any caller that passes atoms directly.
  def retryable?(:timeout), do: true
  def retryable?(_), do: false

  # ── Private ───────────────────────────────────────────────────────────────

  defp try_fallback_providers(
         state,
         provider_config,
         streaming?,
         on_chunk,
         deadline,
         last_error
       ) do
    runtime_overrides = Map.take(provider_config, [:system_prompt, :on_event])

    Enum.reduce_while(state.config.fallback_providers, last_error, fn
      {fb_provider, fb_config}, acc ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:halt, acc}
        else
          fb_provider_config = Map.merge(fb_config, runtime_overrides)

          {result, chunks_emitted?} =
            do_provider_call(
              state,
              fb_provider,
              fb_provider_config,
              streaming?,
              on_chunk,
              state.config.max_retries,
              deadline
            )

          case result do
            {:ok, _} = success ->
              {:halt, success}

            {:error, _} = error when chunks_emitted? ->
              {:halt, error}

            {:error, _} = error ->
              {:cont, error}
          end
        end
    end)
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
        {success, chunks_emitted?}

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
            {{:error, reason}, false}
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
          {{:error, reason}, chunks_emitted?}
        end

      {:error, _reason} = error ->
        {error, chunks_emitted?}
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
end
