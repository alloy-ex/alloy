defmodule Alloy.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Alloy.Agent.State
  alias Alloy.Events
  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, Middleware, OutputSchema}
  alias Alloy.Provider.{Error, Retry}
  alias Alloy.Tool.{Executor, Validation}

  require Logger

  # Buffer subtracted from timeout_ms when computing the retry deadline.
  # Stops retries 5s before timeout_ms and caps non-streaming receive_timeout
  # (once timeout_ms > 8_000, with a 3s floor for shorter runs) to leave
  # cleanup headroom. Streaming requests, tool execution, and turn boundaries
  # are bounded by the absolute run_deadline (started + timeout_ms).
  # Note: timeout_ms values <= this constant effectively disable retries.
  @deadline_headroom_ms 5_000

  @doc """
  Run the agent loop until completion, error, or max turns.

  Takes an initialized `State` with messages and returns the
  final state with status set to `:completed`, `:error`, or `:max_turns`.

  Each turn is reported as `[:alloy, :turn, :start]` and `[:alloy, :turn, :stop]`,
  or `[:alloy, :turn, :exception]` when the turn raises, using the same
  measurements and `telemetry_span_context` metadata shape as `:telemetry.span/3`
  with argument-stripped stacktraces (`:reason` still carries the raw exception
  or exit term, so handlers exporting externally should sanitize it). A turn's
  stop event fires when that turn ends; its `:status` is `:running` when the
  loop goes on to another turn and the final status otherwise.

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

    # Compute deadlines ONCE for the entire loop (or nil when timeout_ms: :infinity):
    # - `deadline` leaves headroom so retries never overshoot the caller timeout
    # - `run_deadline` is the absolute wall-clock bound for requests, tools, and turns
    {deadline, hard_deadline} =
      case state.config.timeout_ms do
        :infinity ->
          {nil, nil}

        timeout_ms when is_integer(timeout_ms) ->
          now = System.monotonic_time(:millisecond)
          hard = now + timeout_ms
          {hard - @deadline_headroom_ms, hard}
      end

    normalized_config = %{
      state.config
      | output_schema: OutputSchema.normalize!(state.config.output_schema)
    }

    state = %{
      state
      | config: normalized_config,
        status: :running,
        deadline: deadline,
        run_deadline: hard_deadline,
        error: nil,
        stop_reason: nil,
        provider_response_metadata: %{},
        run_metadata: %{}
    }

    run_span(state.config.provider_config[:model], fn -> loop(state, opts) end)
  end

  # :telemetry.span/3 accepts extra stop measurements only from telemetry 1.3,
  # and the run stop event has always carried :duration_ms, so the run span is
  # emitted by hand with the same start/stop/exception shape.
  defp run_span(model, fun) do
    started = System.monotonic_time(:millisecond)
    span_ctx = make_ref()

    :telemetry.execute(
      [:alloy, :run, :start],
      %{system_time: System.system_time()},
      %{model: model, telemetry_span_context: span_ctx}
    )

    try do
      final_state = fun.()

      :telemetry.execute(
        [:alloy, :run, :stop],
        %{duration_ms: System.monotonic_time(:millisecond) - started},
        %{
          status: final_state.status,
          turns: final_state.turn,
          model: model,
          telemetry_span_context: span_ctx
        }
      )

      final_state
    catch
      kind, reason ->
        :telemetry.execute(
          [:alloy, :run, :exception],
          %{duration_ms: System.monotonic_time(:millisecond) - started},
          %{
            model: model,
            kind: kind,
            reason: reason,
            stacktrace: Sanitize.stacktrace(__STACKTRACE__),
            telemetry_span_context: span_ctx
          }
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp loop(%State{turn: turn, config: config} = state, opts) do
    cond do
      turn > 0 and deadline_expired?(state) ->
        fail(state, timeout_error(state))

      turn >= config.max_turns ->
        %{state | status: :max_turns}

      true ->
        case run_turn(state, opts) do
          {:continue, state} -> loop(state, opts)
          {:halt, state} -> state
        end
    end
  end

  # One turn: one provider response and the tool calls it asks for. Every
  # step returns {:continue, state} to start another turn or {:halt, state}
  # with the final status set.
  defp run_turn(%State{} = state, opts) do
    turn = state.turn + 1
    turn_span(turn, fn -> complete(state, opts, false) end)
  end

  defp turn_span(turn, fun) do
    start_mono = System.monotonic_time()
    span_ctx = make_ref()

    :telemetry.execute(
      [:alloy, :turn, :start],
      %{monotonic_time: start_mono, system_time: System.system_time()},
      %{turn: turn, telemetry_span_context: span_ctx}
    )

    try do
      step = fun.()
      stop_mono = System.monotonic_time()

      :telemetry.execute(
        [:alloy, :turn, :stop],
        %{duration: stop_mono - start_mono, monotonic_time: stop_mono},
        %{turn: turn, status: step_status(step), telemetry_span_context: span_ctx}
      )

      step
    catch
      kind, reason ->
        stop_mono = System.monotonic_time()

        :telemetry.execute(
          [:alloy, :turn, :exception],
          %{duration: stop_mono - start_mono, monotonic_time: stop_mono},
          %{
            turn: turn,
            kind: kind,
            reason: reason,
            stacktrace: Sanitize.stacktrace(__STACKTRACE__),
            telemetry_span_context: span_ctx
          }
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp step_status({:continue, %State{}}), do: :running
  defp step_status({:halt, %State{status: status}}), do: status

  defp complete(%State{} = state, opts, overflow_retried?) do
    # On turn 0, preflight tool validation (optional dependency + local-ref/schema
    # check) before :before_completion so compaction cannot spend a summary request
    # on a misconfigured tool set. On later turns, validate once after
    # :before_completion so middleware that swaps tools does not thrash the cache.
    {pre_key, schemas, state} =
      if state.turn == 0 and not overflow_retried? do
        {prepared, updated} = prepare_tool_schemas(state)
        {tool_schema_key(updated), prepared, updated}
      else
        {nil, nil, state}
      end

    with {:continue, state} <- run_middleware(:before_completion, state),
         :ok <- check_deadline(state) do
      {schemas, state} = refresh_tool_schemas(state, pre_key, schemas)
      post_key = tool_schema_key(state)

      case request(state, opts) do
        {:ok, %{stop_reason: :refusal} = response} ->
          {:halt, refuse(state, response)}

        {:ok, %{stop_reason: stop_reason, messages: new_msgs} = response} ->
          state
          |> State.append_messages(new_msgs)
          |> account_response(response)
          |> continue_after(stop_reason, new_msgs, {post_key, schemas}, opts)

        {:error, reason} ->
          handle_provider_error(reason, state, opts, overflow_retried?)
      end
    end
  end

  defp request(%State{} = state, opts) do
    provider = state.config.provider
    provider_config = build_provider_config(state)
    provider_event_turn = state.turn + 1

    streaming? = Keyword.get(opts, :streaming, false) && Retry.supports_streaming?(provider)

    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

    on_event = fn raw_event ->
      Events.emit(opts, provider_event_turn, raw_event)
    end

    provider_config =
      provider_config
      |> then(fn cfg ->
        if is_integer(state.run_deadline),
          do: Map.put(cfg, :alloy_request_deadline, state.run_deadline),
          else: cfg
      end)
      |> then(fn cfg -> if streaming?, do: Map.put(cfg, :on_event, on_event), else: cfg end)

    Retry.call_with_retry(state, provider, provider_config, streaming?, on_chunk, state.deadline)
  end

  defp account_response(state, %{stop_reason: stop_reason, usage: usage} = response) do
    %{state | stop_reason: stop_reason}
    |> State.increment_turn()
    |> State.merge_usage(usage)
    |> State.merge_provider_state(Map.get(response, :provider_state))
    |> State.put_provider_response_metadata(Map.get(response, :response_metadata))
  end

  defp continue_after(state, :tool_use, new_msgs, prepared_schemas, opts) do
    case extract_tool_calls(new_msgs) do
      # Only server-executed tools ran: there is nothing for the client to
      # answer, and an empty tool-results message is rejected by every API.
      [] -> finish(state, new_msgs)
      calls -> handle_tool_use(state, calls, prepared_schemas, opts)
    end
  end

  defp continue_after(state, :end_turn, new_msgs, _prepared_schemas, _opts),
    do: finish(state, new_msgs)

  defp continue_after(state, :pause_turn, _new_msgs, _prepared_schemas, _opts),
    do: {:continue, state}

  defp continue_after(state, :max_tokens, new_msgs, _prepared_schemas, _opts) do
    case extract_tool_calls(new_msgs) do
      [] ->
        finish(state, new_msgs)

      calls ->
        reason =
          "Output hit the max_tokens limit while writing a tool call; raise the provider's :max_tokens"

        {:halt, abandon_tool_calls(state, calls, reason)}
    end
  end

  defp continue_after(state, stop_reason, _new_msgs, _prepared_schemas, _opts) do
    {:halt, fail(state, "Provider returned an unsupported stop_reason: #{inspect(stop_reason)}")}
  end

  # Refused output must be discarded, so the response's messages are not kept.
  defp refuse(state, response) do
    details = get_in(response, [:response_metadata, :stop_details])

    reason =
      case details do
        nil ->
          "The model refused to continue (stop_reason: refusal)"

        details ->
          "The model refused to continue (stop_reason: refusal): #{Sanitize.inspect_bounded(details)}"
      end

    state
    |> account_response(response)
    |> maybe_record_refusal_output_error(reason)
    |> fail(reason)
  end

  defp maybe_record_refusal_output_error(%State{config: %{output_schema: nil}} = state, _reason),
    do: state

  defp maybe_record_refusal_output_error(state, reason) do
    State.merge_run_metadata(state, %{
      output_error: %{kind: :refusal, message: reason, decoded: nil}
    })
  end

  # Answers every unanswered tool call with an error so the transcript stays
  # valid for a follow-up request, then fails the run.
  defp abandon_tool_calls(state, calls, failure) do
    reason = if is_struct(failure, Error), do: Exception.message(failure), else: failure

    results =
      Enum.map(calls, &Message.tool_result_block(&1.id, "Not executed: #{reason}", true))

    state
    |> State.append_messages(Message.tool_results(results))
    |> fail(failure)
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

    case Middleware.run_hook(:on_error, state) do
      {:halted, halted_reason, halted} -> halt(halted, halted_reason)
      %State{} = state -> state
    end
  end

  # A halt keeps what earlier middleware in the chain did, such as a
  # compaction whose summary request was already billed.
  defp run_middleware(hook, %State{} = state) do
    case Middleware.run_hook(hook, state) do
      {:halted, reason, halted} -> {:halt, halt(halted, reason)}
      %State{} = state -> {:continue, state}
    end
  end

  defp halt(%State{} = state, reason),
    do: %{state | status: :halted, error: "Halted by middleware: #{reason}"}

  defp handle_provider_error(reason, state, opts, false = _overflow_retried?) do
    if prompt_too_long?(reason),
      do: recover_from_overflow(reason, state, opts),
      else: {:halt, fail(state, reason)}
  end

  defp handle_provider_error(reason, state, _opts, true = _overflow_retried?),
    do: {:halt, fail(state, reason)}

  # The provider rejected the prompt as too long. :on_context_overflow
  # middleware (compaction, unless it is turned off) may shrink the history;
  # the request is retried once, and only if the messages changed. The
  # middleware's own changes (a summary request's usage) are kept either way.
  defp recover_from_overflow(reason, state, opts) do
    case run_middleware(:on_context_overflow, state) do
      {:halt, halted} ->
        overflow_event(state, false)
        {:halt, put_provider_error(halted, reason)}

      {:continue, %State{messages: messages} = unchanged} when messages == state.messages ->
        overflow_event(state, false)
        {:halt, fail(unchanged, reason)}

      {:continue, shrunk} ->
        Logger.info("[Turn] Prompt too long — history shrunk by middleware, retrying")
        overflow_event(state, true)

        case complete(shrunk, opts, true) do
          {:halt, %State{status: status} = failed} when status in [:error, :halted] ->
            {:halt, failed}

          {next, recovered} ->
            {next, State.merge_run_metadata(recovered, %{prompt_too_long_recovery: true})}
        end
    end
  end

  defp overflow_event(%State{turn: turn}, retry?) do
    :telemetry.execute(
      [:alloy, :turn, :prompt_too_long_recovery],
      %{},
      %{turn: turn + 1, retry: retry?}
    )
  end

  defp put_provider_error(state, %Error{} = error),
    do: State.merge_run_metadata(state, %{provider_error: error})

  defp put_provider_error(state, _reason), do: state

  defp handle_tool_use(%State{} = state, tool_calls, prepared_schemas, opts) do
    if deadline_expired?(state) do
      {:halt, abandon_tool_calls(state, tool_calls, timeout_error(state))}
    else
      case run_middleware(:after_tool_request, state) do
        {:continue, state} -> execute_tools(state, tool_calls, prepared_schemas, opts)
        {:halt, state} -> {:halt, answer_tool_calls(state, tool_calls, [])}
      end
    end
  end

  defp execute_tools(%State{} = state, tool_calls, {prev_key, prev_schemas}, opts) do
    # Refresh against the effective tool set only if :after_tool_request
    # middleware changed tools or validation mode.
    {schemas, state} = refresh_tool_schemas(state, prev_key, prev_schemas)

    case run_executor(tool_calls, state, schemas, opts) do
      {:halted, reason} ->
        {:halt, state |> halt(reason) |> answer_tool_calls(tool_calls, [])}

      {:ok, result_blocks, tool_call_meta} ->
        state
        |> answer_tool_calls(tool_calls, result_blocks)
        |> State.append_tool_calls(tool_call_meta)
        |> then(&run_middleware(:after_tool_execution, &1))
        |> maybe_finish_after_tool(tool_call_meta)
    end
  end

  defp tool_schema_key(%State{tool_fns: tool_fns, config: %{tool_validation: mode}}),
    do: {tool_fns, mode}

  defp refresh_tool_schemas(state, prev_key, prev_schemas) do
    if tool_schema_key(state) == prev_key do
      {prev_schemas, state}
    else
      prepare_tool_schemas(state)
    end
  end

  defp prepare_tool_schemas(state) do
    {schemas, cache} =
      Validation.prepare(state.tool_fns, state.config.tool_validation, state.tool_schema_cache)

    {schemas, %{state | tool_schema_cache: cache}}
  end

  defp maybe_finish_after_tool({:halt, _state} = halted, _calls), do: halted

  defp maybe_finish_after_tool({:continue, state} = next, calls) do
    calls = Enum.take(state.tool_calls, -length(calls))
    selected = Enum.find(calls, &(&1.name == state.config.stop_after_tool and is_nil(&1.error)))

    with %{} <- selected,
         false <- until_tool_pending?(state),
         %{content: content} = block <- final_tool_block(state, selected.id),
         false <- Map.get(block, :is_error, false) do
      final_tool =
        selected |> Map.take([:id, :name, :structured_data]) |> Map.put(:content, content)

      state = State.merge_run_metadata(state, %{final_tool: final_tool})
      finish(state, [])
    else
      _ -> next
    end
  end

  # Search trailing user messages since this round's assistant tool call so an
  # :after_tool_execution hook that appends a user note doesn't hide the result,
  # while stopping at the assistant message prevents matching an earlier round
  # that reused the same tool_use_id.
  defp final_tool_block(state, id) do
    state.messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role == :user))
    |> Enum.find_value(fn
      %Message{content: blocks} when is_list(blocks) ->
        Enum.find(blocks, &(&1[:type] == "tool_result" and &1[:tool_use_id] == id))

      _message ->
        nil
    end)
  end

  defp run_executor(calls, state, schemas, opts) do
    executor_opts =
      opts
      |> Keyword.take([:event_seq_ref, :event_correlation_id])
      |> Keyword.merge(
        on_event: &Events.emit(opts, state.turn, &1),
        event_turn: state.turn,
        tool_schemas: schemas,
        run_deadline: state.run_deadline
      )

    case Executor.execute_all(calls, state.tool_fns, state, executor_opts) do
      {:ok, %Message{content: blocks}, tool_call_meta} -> {:ok, blocks, tool_call_meta}
      {:halted, _reason} = halted -> halted
    end
  end

  # Appends one tool_result per call, in call order. A call without a result
  # (the loop halted before it ran) is answered with an error, because every
  # API rejects a tool_use left unanswered and the halted transcript must stay
  # usable for the next request. Tool-call IDs are unique per turn, so
  # id-keyed lookup is safe.
  defp answer_tool_calls(%State{} = state, tool_calls, result_blocks) do
    by_id = Map.new(result_blocks, &{&1.tool_use_id, &1})

    results =
      Enum.map(tool_calls, fn %{id: id} ->
        Map.get_lazy(by_id, id, fn ->
          Message.tool_result_block(id, "Not executed: #{state.error}", true)
        end)
      end)

    State.append_messages(state, Message.tool_results(results))
  end

  defp build_provider_config(%State{config: config, provider_state: provider_state}) do
    config.provider_config
    |> Map.put(:system_prompt, config.system_prompt)
    |> Map.put(:provider_state, provider_state)
    |> maybe_enable_code_execution(config.code_execution)
    |> maybe_put_output_schema(config.output_schema)
  end

  # The top-level option only turns code execution on, so a provider config
  # that already sets :code_execution itself is left alone when it is false.
  defp maybe_enable_code_execution(provider_config, true),
    do: Map.put(provider_config, :code_execution, true)

  defp maybe_enable_code_execution(provider_config, false), do: provider_config

  defp maybe_put_output_schema(provider_config, nil),
    do: Map.delete(provider_config, :output_schema)

  defp maybe_put_output_schema(provider_config, %OutputSchema{} = spec),
    do: Map.put(provider_config, :output_schema, spec)

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp prompt_too_long?(%Error{kind: kind}), do: kind == :context_overflow
  defp prompt_too_long?(reason) when is_binary(reason), do: Error.overflow_text?(reason)
  defp prompt_too_long?(_reason), do: false

  # Once a final answer or stop_after_tool outcome has already completed, do not
  # discard it on timeout (which would push callers to retry completed side
  # effects). When until_tool requires another turn, returning {:continue, state}
  # enters loop/2's turn > 0 deadline check before starting it.
  defp finish(state, new_msgs) do
    cond do
      structured_output_refusal?(state, new_msgs) ->
        message = "The model refused to produce structured output"
        error = %{kind: :refusal, message: message, decoded: nil}
        {:halt, state |> State.merge_run_metadata(%{output_error: error}) |> fail(message)}

      until_tool_pending?(state) ->
        reminder =
          Message.user(
            "Continue. You must call the #{state.config.until_tool} tool before finishing."
          )

        {:continue, State.append_messages(state, [reminder])}

      true ->
        case decode_structured_output(state, new_msgs) do
          {:ok, state} ->
            case run_middleware(:after_completion, state) do
              {:continue, state} -> {:halt, %{state | status: :completed}}
              {:halt, state} -> {:halt, state}
            end

          {:error, state, reason} ->
            {:halt, fail(state, reason)}
        end
    end
  end

  defp structured_output_refusal?(%State{config: %{output_schema: nil}}, _new_msgs), do: false
  defp structured_output_refusal?(%State{run_metadata: %{final_tool: _}}, _new_msgs), do: false

  defp structured_output_refusal?(_state, new_msgs) do
    new_msgs |> last_assistant_message() |> refusal_message?()
  end

  defp decode_structured_output(%State{config: %{output_schema: nil}} = state, _new_msgs),
    do: {:ok, state}

  defp decode_structured_output(%State{run_metadata: %{final_tool: _}} = state, _new_msgs),
    do: {:ok, state}

  defp decode_structured_output(%State{config: %{output_schema: spec}} = state, new_msgs) do
    text = new_msgs |> last_assistant_message() |> raw_assistant_text()
    handle_decoded_output(state, OutputSchema.decode_and_validate(text, spec))
  end

  defp handle_decoded_output(state, {:error, %{kind: :invalid_schema, message: message} = error}) do
    {:error, State.merge_run_metadata(state, %{output_error: error}), message}
  end

  defp handle_decoded_output(%State{stop_reason: :max_tokens} = state, result) do
    {detail, decoded} =
      case result do
        {:ok, value} -> {"", value}
        {:error, %{message: reason, decoded: value}} -> {" (#{reason})", value}
      end

    message = "Structured output was truncated at :max_tokens#{detail}"
    error = %{kind: :truncated, message: message, decoded: decoded}
    {:error, State.merge_run_metadata(state, %{output_error: error}), message}
  end

  defp handle_decoded_output(state, {:ok, decoded}) do
    {:ok, State.merge_run_metadata(state, %{output: decoded})}
  end

  defp handle_decoded_output(state, {:error, %{message: message} = error}) do
    {:error, State.merge_run_metadata(state, %{output_error: error}), message}
  end

  defp last_assistant_message(messages) do
    case List.last(messages) do
      %Message{role: :assistant} = msg -> msg
      _ -> nil
    end
  end

  defp refusal_message?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, &match?(%{refusal: true}, &1))
  end

  defp refusal_message?(_other), do: false

  # Join text blocks with "" (not "\n" like Message.text/1) so JSON strings
  # split across multiple text blocks (e.g. Gemini thought-signature chunks)
  # do not gain an illegal raw newline inside a JSON string literal. Returns
  # nil when the final assistant message has no text content so decode reports
  # :missing_text instead of "unexpected end of input".
  defp raw_assistant_text(nil), do: nil
  defp raw_assistant_text(%Message{content: ""}), do: nil
  defp raw_assistant_text(%Message{content: content}) when is_binary(content), do: content

  defp raw_assistant_text(%Message{content: blocks}) when is_list(blocks) do
    joined =
      Enum.map_join(blocks, "", fn
        %{type: "text", text: text} when is_binary(text) -> text
        _other -> ""
      end)

    if joined == "", do: nil, else: joined
  end

  defp check_deadline(state) do
    if deadline_expired?(state),
      do: {:halt, fail(state, timeout_error(state))},
      else: :ok
  end

  defp deadline_expired?(%State{run_deadline: deadline}) when is_integer(deadline) do
    System.monotonic_time(:millisecond) >= deadline
  end

  defp deadline_expired?(_state), do: false

  defp timeout_error(state) do
    %Error{
      kind: :timeout,
      message: "Agent run timed out after #{state.config.timeout_ms}ms"
    }
  end

  defp until_tool_pending?(%State{config: %{until_tool: nil}}), do: false

  # Only a successful call counts: a failed, blocked or unknown call means the
  # model has not produced the required output yet.
  defp until_tool_pending?(%State{config: %{until_tool: name}, tool_calls: calls}) do
    not Enum.any?(calls, fn call -> call[:name] == name and is_nil(call[:error]) end)
  end
end
