defmodule Alloy.Provider.Retry do
  @moduledoc """
  Provider retry, backoff, fallback, and streaming dispatch logic.

  Handles exponential backoff with full jitter, retryable error
  classification, fallback provider chains, and receive-timeout
  injection. Extracted from `Alloy.Agent.Turn` to separate
  provider-oriented concerns from agent loop control flow.
  """

  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Provider.Error

  require Logger

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
        normalize_for(state, provider),
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
  def retryable?(%Error{} = error), do: Error.retryable?(error)

  # String errors from custom providers (built-in providers return
  # %Alloy.Provider.Error{}). The generic format is "HTTP <status>: <body>".
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
              normalize_for(state, fb_provider),
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

    provider_start = System.monotonic_time(:millisecond)

    {result, chunks_emitted?} =
      call_provider(provider, state, provider_config, streaming?, on_chunk)

    :telemetry.execute(
      [:alloy, :provider, :request],
      %{duration_ms: System.monotonic_time(:millisecond) - provider_start},
      %{
        provider: provider,
        model: Map.get(provider_config, :model),
        streaming: streaming?,
        attempt: state.config.max_retries - retries_left + 1,
        result: if(match?({:ok, _}, result), do: :ok, else: :error)
      }
    )

    case result do
      {:ok, response} ->
        {{:ok, record_origin(response, provider, provider_config)}, chunks_emitted?}

      {:error, reason} when retries_left > 0 ->
        if retryable?(reason) and not chunks_emitted? do
          attempt = state.config.max_retries - retries_left + 1
          base = round(state.config.retry_backoff_ms * :math.pow(2, attempt - 1))
          # Full jitter: uniform random in [0, 2*base) — prevents thundering herd
          # when multiple agents hit the same rate limit simultaneously. Never
          # retry sooner than the provider's Retry-After.
          backoff = max(:rand.uniform(base * 2), retry_after_ms(reason))
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining < backoff do
            # Not enough time left — return the error rather than sleeping
            # past the turn deadline.
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

  # Normalized once per provider rather than per attempt: retries resend the
  # same history.
  defp normalize_for(%State{} = state, provider),
    do: %{state | messages: Message.normalize_for(state.messages, provider)}

  # Provenance lets a later request to a different provider (a fallback, or
  # a model switch) rewrite blocks only this provider can read.
  defp record_origin(%{messages: messages} = response, provider, provider_config) do
    model = Map.get(provider_config, :model)
    stamp = fn %Message{} = message -> %{message | provider: provider, model: model} end
    %{response | messages: Enum.map(messages, stamp)}
  end

  defp retry_after_ms(%Error{retry_after_ms: ms}) when is_integer(ms), do: ms
  defp retry_after_ms(_reason), do: 0

  # Calls the provider and returns {result, chunks_emitted?}.
  # For streaming calls, wraps on_chunk to detect whether any chunks were
  # delivered before the call returned. This prevents retrying mid-stream
  # failures that already produced partial output.
  defp call_provider(provider, state, provider_config, true = _streaming?, on_chunk) do
    ref = :atomics.new(1, signed: false)

    original_on_event = Map.get(provider_config, :on_event, fn _ -> :ok end)

    wrapped_chunk = fn chunk ->
      :atomics.put(ref, 1, 1)
      notify(:on_chunk, on_chunk, chunk)
      notify(:on_event, original_on_event, {:text_delta, chunk})
    end

    wrapped_on_event = fn event ->
      :atomics.put(ref, 1, 1)
      notify(:on_event, original_on_event, event)
    end

    provider_config = Map.put(provider_config, :on_event, wrapped_on_event)

    result = provider.stream(state.messages, state.tool_defs, provider_config, wrapped_chunk)
    {result, :atomics.get(ref, 1) == 1}
  end

  defp call_provider(provider, state, provider_config, false = _streaming?, _on_chunk) do
    {provider.complete(state.messages, state.tool_defs, provider_config), false}
  end

  # The caller's streaming callbacks run inside the provider's stream
  # handler. If one raises there, the handler loses the delta it was
  # accumulating, so the stored message silently misses text. A raising (so
  # buggy) UI callback is logged and the stream carries on. A throw or exit
  # is deliberate control flow and still stops the stream, as it always has.
  defp notify(name, callback, payload) do
    callback.(payload)
    :ok
  rescue
    exception ->
      Logger.warning(
        "[Alloy] #{name} callback failed; the stream continues.\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
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
