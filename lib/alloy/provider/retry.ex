defmodule Alloy.Provider.Retry do
  @moduledoc """
  Provider retry, backoff, fallback, and streaming dispatch logic.

  Handles exponential backoff with full jitter, retryable error
  classification, fallback provider chains, and receive-timeout
  injection. Extracted from `Alloy.Agent.Turn` to separate
  provider-oriented concerns from agent loop control flow.
  """

  alias Alloy.Agent.State
  alias Alloy.Cancel
  alias Alloy.Internal.{Deadline, Sanitize}
  alias Alloy.Message
  alias Alloy.Provider.Error

  require Logger

  # Cap per-retry delay when timeout_ms: :infinity so a hostile or distant
  # Retry-After header (e.g. hours/days) aborts instead of sleeping forever.
  @max_unbounded_retry_delay_ms 60_000
  @cancel_poll_ms 25

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
    {result, _messages, _chunks_emitted?} =
      call_with_retry_attributed(state, provider, provider_config, streaming?, on_chunk, deadline)

    result
  end

  @doc false
  @spec call_with_retry_attributed(
          State.t(),
          module(),
          map(),
          boolean(),
          function(),
          integer() | nil
        ) ::
          {{:ok, map()} | {:error, term()}, [Message.t()], boolean()}
  def call_with_retry_attributed(state, provider, provider_config, streaming?, on_chunk, deadline) do
    primary_origin = Message.origin(provider, provider_config)
    base_messages = Message.attribute_file_blocks(state.messages, primary_origin, provider)
    base_state = %{state | messages: base_messages}
    cancel_token = effective_cancel_token(state, provider_config)
    provider_config = maybe_put_cancel_token(provider_config, cancel_token)

    {result, chunks_emitted?} =
      do_provider_call(%{
        state: normalize_for(base_state, provider, provider_config),
        provider: provider,
        provider_config: provider_config,
        streaming?: streaming?,
        on_chunk: on_chunk,
        retries_left: state.config.max_retries,
        deadline: deadline
      })

    case classify_attempt_outcome(result, chunks_emitted?, cancel_token) do
      {:ok, response, emitted?} ->
        {{:ok, response}, base_messages, emitted?}

      {:halt_error, error, emitted?} ->
        {error, base_messages, emitted?}

      {:fallback, error} ->
        try_fallback_providers(
          base_state,
          provider_config,
          primary_origin,
          streaming?,
          on_chunk,
          deadline,
          error
        )
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
         primary_origin,
         streaming?,
         on_chunk,
         deadline,
         last_error
       ) do
    runtime_overrides =
      Map.take(provider_config, [
        :system_prompt,
        :on_event,
        :alloy_on_text_event,
        :alloy_request_deadline,
        :alloy_cancel_token,
        :output_schema
      ])

    cancel_token = effective_cancel_token(state, provider_config)

    Enum.reduce_while(
      state.config.fallback_providers,
      {last_error, state.messages, false},
      fn {fb_provider, fb_config}, {acc_err, messages_acc, _emitted?} ->
        cond do
          Cancel.cancelled?(cancel_token) ->
            {:halt, {{:error, cancelled_error()}, messages_acc, false}}

          Deadline.expired?(deadline) ->
            {:halt, {acc_err, messages_acc, false}}

          true ->
            fb_provider_config =
              fb_config
              |> Map.merge(runtime_overrides)
              |> maybe_put_reasoning(state.config.reasoning)

            fb_streaming? = streaming? and supports_streaming?(fb_provider)
            fb_origin = Message.origin(fb_provider, fb_provider_config)

            attempt_messages =
              Message.attribute_file_blocks(messages_acc, fb_origin, fb_provider)

            attributed_state = %{state | messages: attempt_messages}

            {result, chunks_emitted?} =
              do_provider_call(%{
                state: normalize_for(attributed_state, fb_provider, fb_provider_config),
                provider: fb_provider,
                provider_config: fb_provider_config,
                streaming?: fb_streaming?,
                on_chunk: on_chunk,
                retries_left: state.config.max_retries,
                deadline: deadline
              })

            handle_fallback_outcome(
              classify_attempt_outcome(result, chunks_emitted?, cancel_token),
              fb_provider,
              fb_provider_config,
              primary_origin,
              attempt_messages
            )
        end
      end
    )
  end

  defp handle_fallback_outcome(
         {:ok, response, emitted?},
         fb_provider,
         fb_provider_config,
         primary_origin,
         attempt_messages
       ) do
    isolated = isolate_fallback_state(response, fb_provider, fb_provider_config, primary_origin)
    {:halt, {{:ok, isolated}, attempt_messages, emitted?}}
  end

  defp handle_fallback_outcome(
         {:halt_error, error, emitted?},
         _fb_provider,
         _fb_provider_config,
         _primary_origin,
         attempt_messages
       ) do
    {:halt, {error, attempt_messages, emitted?}}
  end

  defp handle_fallback_outcome(
         {:fallback, error},
         _fb_provider,
         _fb_provider_config,
         _primary_origin,
         attempt_messages
       ) do
    {:cont, {error, attempt_messages, false}}
  end

  defp classify_attempt_outcome({:ok, response}, chunks_emitted?, _cancel_token) do
    {:ok, response, chunks_emitted?}
  end

  # Preserve explicit :cancelled errors (e.g. Codex resume rotation guidance)
  # even when chunks were emitted; convert non-cancelled errors after cancel.
  defp classify_attempt_outcome(
         {:error, %Error{kind: :cancelled}} = error,
         chunks_emitted?,
         _cancel_token
       ) do
    {:halt_error, error, chunks_emitted?}
  end

  # Once any streamed output/event was emitted, never switch providers:
  # mixing chunks from multiple providers in one stream breaks turn semantics.
  defp classify_attempt_outcome({:error, _reason} = error, true, cancel_token) do
    if Cancel.cancelled?(cancel_token),
      do: {:halt_error, {:error, cancelled_error()}, true},
      else: {:halt_error, error, true}
  end

  # Do not spawn fallback workers against a supervisor that is shutting down.
  defp classify_attempt_outcome({:error, %Error{kind: :shutdown}} = error, false, _cancel_token) do
    {:halt_error, error, false}
  end

  defp classify_attempt_outcome({:error, _reason} = error, false, cancel_token) do
    if Cancel.cancelled?(cancel_token),
      do: {:halt_error, {:error, cancelled_error()}, false},
      else: {:fallback, error}
  end

  defp isolate_fallback_state(response, fb_provider, fb_config, primary_origin) do
    if Message.origin(fb_provider, fb_config) == primary_origin,
      do: response,
      else: Map.delete(response, :provider_state)
  end

  defp maybe_put_reasoning(provider_config, nil), do: provider_config

  defp maybe_put_reasoning(provider_config, reasoning) do
    Map.put_new(provider_config, :reasoning, reasoning)
  end

  defp do_provider_call(
         %{
           state: state,
           provider_config: provider_config,
           streaming?: streaming?,
           deadline: deadline
         } = call_ctx
       ) do
    cancel_token = effective_cancel_token(state, provider_config)

    if Cancel.cancelled?(cancel_token) do
      {{:error, cancelled_error()}, false}
    else
      case apply_request_deadline(provider_config, deadline, streaming?) do
        :expired ->
          {{:error, %Error{kind: :timeout, message: "Request deadline exceeded"}}, false}

        {:ok, updated_config} ->
          execute_provider_attempt(%{call_ctx | provider_config: updated_config})
      end
    end
  end

  defp execute_provider_attempt(
         %{
           state: state,
           provider: provider,
           provider_config: provider_config,
           streaming?: streaming?,
           on_chunk: on_chunk,
           retries_left: retries_left
         } = call_ctx
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
        maybe_retry_attempt(reason, chunks_emitted?, call_ctx)

      {:error, _reason} = error ->
        {error, chunks_emitted?}
    end
  end

  defp maybe_retry_attempt(%Error{kind: :cancelled} = error, chunks_emitted?, _ctx),
    do: {{:error, error}, chunks_emitted?}

  defp maybe_retry_attempt(reason, chunks_emitted?, ctx) do
    cancel_token = effective_cancel_token(ctx.state, ctx.provider_config)

    cond do
      Cancel.cancelled?(cancel_token) ->
        {{:error, cancelled_error()}, chunks_emitted?}

      retryable?(reason) and not chunks_emitted? ->
        schedule_retry_attempt(reason, ctx, cancel_token)

      true ->
        {{:error, reason}, chunks_emitted?}
    end
  end

  defp schedule_retry_attempt(reason, ctx, cancel_token) do
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
      case sleep_backoff(backoff, cancel_token) do
        :cancelled ->
          {{:error, cancelled_error()}, false}

        :ok ->
          do_provider_call(%{ctx | retries_left: ctx.retries_left - 1})
      end
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
    remaining = Deadline.remaining_ms(deadline)
    remaining == 0 or remaining < backoff
  end

  defp retry_after_ms(%Error{retry_after_ms: ms}) when is_integer(ms), do: ms
  defp retry_after_ms(_reason), do: 0

  defp sleep_backoff(0, cancel_token),
    do: if(Cancel.cancelled?(cancel_token), do: :cancelled, else: :ok)

  defp sleep_backoff(ms, nil) when ms > 0 do
    Process.sleep(ms)
    :ok
  end

  defp sleep_backoff(ms, cancel_token) when ms > 0 do
    sleep_until(System.monotonic_time(:millisecond) + ms, cancel_token)
  end

  defp sleep_until(target_ms, cancel_token) do
    if Cancel.cancelled?(cancel_token) do
      :cancelled
    else
      case Deadline.next_wait_ms(target_ms, @cancel_poll_ms) do
        0 ->
          :ok

        wait_ms ->
          Process.sleep(wait_ms)
          sleep_until(target_ms, cancel_token)
      end
    end
  end

  defp effective_cancel_token(state, provider_config) do
    Map.get(provider_config, :alloy_cancel_token) || state.config.cancel_token
  end

  defp maybe_put_cancel_token(provider_config, nil), do: provider_config

  defp maybe_put_cancel_token(provider_config, cancel_token),
    do: Map.put(provider_config, :alloy_cancel_token, cancel_token)

  defp cancelled_error, do: %Error{kind: :cancelled, message: "Request cancelled"}

  # Calls the provider and returns {result, chunks_emitted?}.
  # For streaming calls, wraps on_chunk to detect whether any chunks were
  # delivered before the call returned. This prevents retrying mid-stream
  # failures that already produced partial output.
  defp call_provider(provider, state, provider_config, true = _streaming?, on_chunk) do
    # Slot 1: chunks_emitted?, Slot 2: on_chunk warning logged?, Slot 3: on_event warning logged?
    ref = :atomics.new(3, signed: false)

    {on_text_event, provider_config} = Map.pop(provider_config, :alloy_on_text_event)
    original_on_event = Map.get(provider_config, :on_event)
    text_event_cb = on_text_event || original_on_event

    wrapped_chunk = fn chunk ->
      :atomics.put(ref, 1, 1)
      notify(:on_chunk, on_chunk, chunk, ref, 2)

      if is_function(text_event_cb, 1) do
        notify(:on_event, text_event_cb, {:text_delta, chunk}, ref, 3)
      end
    end

    provider_config =
      if is_function(original_on_event, 1) do
        wrapped_on_event = fn event ->
          :atomics.put(ref, 1, 1)
          notify(:on_event, original_on_event, event, ref, 3)
        end

        Map.put(provider_config, :on_event, wrapped_on_event)
      else
        Map.delete(provider_config, :on_event)
      end

    result = provider.stream(state.messages, state.tool_defs, provider_config, wrapped_chunk)
    {result, :atomics.get(ref, 1) == 1}
  end

  defp call_provider(provider, state, provider_config, false = _streaming?, _on_chunk) do
    provider_config = Map.delete(provider_config, :alloy_on_text_event)
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
