defmodule Alloy.Provider.Retry do
  @moduledoc """
  Provider retry, backoff, fallback, and streaming dispatch logic.

  Handles exponential backoff with full jitter, retryable error
  classification, fallback provider chains, and receive-timeout
  injection. Extracted from `Alloy.Agent.Turn` to separate
  provider-oriented concerns from agent loop control flow.
  """

  alias Alloy.Agent.State
  alias Alloy.Internal.Sanitize
  alias Alloy.Message
  alias Alloy.Provider.Error

  require Logger

  # Cap per-retry delay when timeout_ms: :infinity so a hostile or distant
  # Retry-After header (e.g. hours/days) aborts instead of sleeping forever.
  @max_unbounded_retry_delay_ms 60_000

  @doc """
  Call a provider with retry, backoff, and fallback logic.

  Single entry point for all provider calls. Retries on transient errors
  with exponential backoff and jitter, then falls back to configured
  fallback providers if the primary provider fails.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec call_with_retry(State.t(), module(), map(), boolean(), function(), integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def call_with_retry(state, provider, provider_config, streaming?, on_chunk, deadline) do
    {result, chunks_emitted?} =
      do_provider_call(
        normalize_for(state, provider, provider_config),
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

      # Do not spawn fallback workers against a supervisor that is shutting down.
      {:error, %Error{kind: :shutdown}} = error ->
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

  @doc false
  @spec supports_streaming?(module()) :: boolean()
  def supports_streaming?(provider) when is_atom(provider) do
    Code.ensure_loaded(provider) == {:module, provider} and
      function_exported?(provider, :stream, 4)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp try_fallback_providers(
         state,
         provider_config,
         streaming?,
         on_chunk,
         deadline,
         last_error
       ) do
    runtime_overrides =
      Map.take(provider_config, [
        :system_prompt,
        :on_event,
        :alloy_request_deadline,
        :output_schema
      ])

    primary_origin = Message.origin(state.config.provider, provider_config)

    base_messages =
      Message.attribute_file_blocks(state.messages, primary_origin, state.config.provider)

    {final_result, _messages} =
      Enum.reduce_while(
        state.config.fallback_providers,
        {last_error, base_messages},
        fn {fb_provider, fb_config}, {acc_err, messages_acc} ->
          now = System.monotonic_time(:millisecond)

          if is_integer(deadline) and deadline - now <= 0 do
            {:halt, {acc_err, messages_acc}}
          else
            fb_provider_config = Map.merge(fb_config, runtime_overrides)
            fb_streaming? = streaming? and supports_streaming?(fb_provider)
            fb_origin = Message.origin(fb_provider, fb_provider_config)

            attempt_messages =
              Message.attribute_file_blocks(messages_acc, fb_origin, fb_provider)

            attributed_state = %{state | messages: attempt_messages}

            {result, chunks_emitted?} =
              do_provider_call(
                normalize_for(attributed_state, fb_provider, fb_provider_config),
                fb_provider,
                fb_provider_config,
                fb_streaming?,
                on_chunk,
                state.config.max_retries,
                deadline
              )

            case result do
              {:ok, response} ->
                {:halt,
                 {{:ok,
                   isolate_fallback_state(
                     response,
                     fb_provider,
                     fb_provider_config,
                     primary_origin
                   )}, attempt_messages}}

              {:error, _} = error when chunks_emitted? ->
                {:halt, {error, attempt_messages}}

              {:error, %Error{kind: :shutdown}} = error ->
                {:halt, {error, attempt_messages}}

              {:error, _} = error ->
                {:cont, {error, attempt_messages}}
            end
          end
        end
      )

    final_result
  end

  defp isolate_fallback_state(response, fb_provider, fb_config, primary_origin) do
    if Message.origin(fb_provider, fb_config) == primary_origin,
      do: response,
      else: Map.delete(response, :provider_state)
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
    case apply_request_deadline(provider_config, deadline, streaming?) do
      :expired ->
        {{:error, %Error{kind: :timeout, message: "Request deadline exceeded"}}, false}

      {:ok, provider_config} ->
        execute_provider_attempt(
          state,
          provider,
          provider_config,
          streaming?,
          on_chunk,
          retries_left,
          deadline
        )
    end
  end

  defp execute_provider_attempt(
         state,
         provider,
         provider_config,
         streaming?,
         on_chunk,
         retries_left,
         deadline
       ) do
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
        call_ctx = %{
          state: state,
          provider: provider,
          provider_config: provider_config,
          streaming?: streaming?,
          on_chunk: on_chunk,
          retries_left: retries_left,
          deadline: deadline
        }

        maybe_retry_attempt(reason, chunks_emitted?, call_ctx)

      {:error, _reason} = error ->
        {error, chunks_emitted?}
    end
  end

  defp maybe_retry_attempt(reason, chunks_emitted?, ctx) do
    if retryable?(reason) and not chunks_emitted? do
      attempt = ctx.state.config.max_retries - ctx.retries_left + 1
      base = round(ctx.state.config.retry_backoff_ms * :math.pow(2, attempt - 1))
      # Full jitter: uniform random in [1, 2*base] when base > 0 (0 when
      # retry_backoff_ms: 0) — prevents thundering herd when multiple agents
      # hit the same rate limit simultaneously. Never retry sooner than the
      # provider's Retry-After.
      jitter = if base > 0, do: :rand.uniform(base * 2), else: 0
      retry_after = retry_after_ms(reason)

      backoff =
        if is_nil(ctx.deadline) do
          max(min(jitter, @max_unbounded_retry_delay_ms), retry_after)
        else
          max(jitter, retry_after)
        end

      if retry_budget_exhausted?(ctx.deadline, backoff) do
        # Not enough time left — return the error rather than sleeping
        # past the turn deadline.
        {{:error, reason}, false}
      else
        sleep_backoff(backoff)

        do_provider_call(
          ctx.state,
          ctx.provider,
          ctx.provider_config,
          ctx.streaming?,
          ctx.on_chunk,
          ctx.retries_left - 1,
          ctx.deadline
        )
      end
    else
      {{:error, reason}, chunks_emitted?}
    end
  end

  # Normalized once per provider rather than per attempt: retries resend the
  # same history.
  defp normalize_for(%State{} = state, provider, provider_config),
    do: %{state | messages: Message.normalize_for(state.messages, provider, provider_config)}

  # Provenance lets a later request to a different provider (a fallback, or
  # a model switch) rewrite blocks only this provider can read.
  defp record_origin(%{messages: messages} = response, provider, provider_config) do
    model = Map.get(provider_config, :model)
    origin = Message.origin(provider, provider_config)

    stamp = fn %Message{} = message ->
      %{message | provider: provider, model: model, origin: origin}
    end

    %{response | messages: Enum.map(messages, stamp)}
  end

  defp retry_budget_exhausted?(nil, backoff), do: backoff > @max_unbounded_retry_delay_ms

  defp retry_budget_exhausted?(deadline, backoff) when is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    remaining <= 0 or remaining < backoff
  end

  defp retry_after_ms(%Error{retry_after_ms: ms}) when is_integer(ms), do: ms
  defp retry_after_ms(_reason), do: 0

  defp sleep_backoff(0), do: :ok
  defp sleep_backoff(ms) when ms > 0, do: Process.sleep(ms)

  # Calls the provider and returns {result, chunks_emitted?}.
  # For streaming calls, wraps on_chunk to detect whether any chunks were
  # delivered before the call returned. This prevents retrying mid-stream
  # failures that already produced partial output.
  defp call_provider(provider, state, provider_config, true = _streaming?, on_chunk) do
    # Slot 1: chunks_emitted?, Slot 2: on_chunk warning logged?, Slot 3: on_event warning logged?
    ref = :atomics.new(3, signed: false)

    original_on_event = Map.get(provider_config, :on_event, fn _ -> :ok end)

    wrapped_chunk = fn chunk ->
      :atomics.put(ref, 1, 1)
      notify(:on_chunk, on_chunk, chunk, ref, 2)
      notify(:on_event, original_on_event, {:text_delta, chunk}, ref, 3)
    end

    wrapped_on_event = fn event ->
      :atomics.put(ref, 1, 1)
      notify(:on_event, original_on_event, event, ref, 3)
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
  # buggy) UI callback is logged at most once per stream call and the stream
  # carries on. A throw or exit is deliberate control flow and still stops
  # the stream, as it always has.
  defp notify(name, callback, payload, ref, log_slot) do
    callback.(payload)
    :ok
  rescue
    exception ->
      if :atomics.compare_exchange(ref, log_slot, 0, 1) == :ok do
        sanitized_trace = Sanitize.stacktrace(__STACKTRACE__)

        Logger.warning(
          "[Alloy] #{name} callback failed (#{Sanitize.exception_summary(exception, 500)}); the stream continues (further failures in this stream suppressed).\n" <>
            Exception.format_stacktrace(sanitized_trace)
        )
      end

      :ok
  end

  # Sets :receive_timeout in req_options (standard Req option) and keeps
  # Alloy's internal :alloy_request_deadline outside req_options so custom
  # providers forwarding req_options directly to Req never see unknown keys.
  # Never renews an expired request deadline.
  defp apply_request_deadline(provider_config, retry_deadline, streaming?) do
    now = System.monotonic_time(:millisecond)

    case resolve_request_budget(provider_config, retry_deadline, streaming?, now) do
      :unbounded ->
        req_options =
          provider_config
          |> Map.get(:req_options, [])
          |> Keyword.put_new(:receive_timeout, :infinity)

        {:ok, Map.put(provider_config, :req_options, req_options)}

      :expired ->
        :expired

      {:ok, timeout, request_deadline} ->
        req_options =
          provider_config
          |> Map.get(:req_options, [])
          |> Keyword.update(:receive_timeout, timeout, fn
            existing when is_integer(existing) and existing > 0 -> min(existing, timeout)
            _other -> timeout
          end)

        {:ok,
         provider_config
         |> Map.put(:req_options, req_options)
         |> Map.put(:alloy_request_deadline, request_deadline)}
    end
  end

  defp resolve_request_budget(provider_config, retry_deadline, streaming?, now) do
    case Map.get(provider_config, :alloy_request_deadline) do
      hard_deadline when is_integer(hard_deadline) ->
        hard_remaining = hard_deadline - now

        if hard_remaining <= 0 do
          :expired
        else
          # Finch's HTTP/2 pool treats :receive_timeout as a total request timer
          # rather than an idle timer, so streaming calls receive the full
          # hard_remaining budget (bounded by HTTP's own hard wall-clock timer).
          # Non-streaming calls follow retry_deadline (which Turn sets 5s ahead
          # of hard_deadline) with a 3s floor clamped to hard_remaining so short
          # runs scale monotonically without discarding most of their budget.
          receive_timeout =
            if streaming? or not is_integer(retry_deadline) do
              hard_remaining
            else
              retry_remaining = retry_deadline - now
              min(hard_remaining, max(retry_remaining, 3_000))
            end

          {:ok, receive_timeout, hard_deadline}
        end

      _none when is_integer(retry_deadline) ->
        remaining = retry_deadline - now
        if remaining <= 0, do: :expired, else: {:ok, remaining, retry_deadline}

      _none ->
        :unbounded
    end
  end
end
