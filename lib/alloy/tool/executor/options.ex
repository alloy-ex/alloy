defmodule Alloy.Tool.Executor.Options do
  @moduledoc false
  # Option and tool-call validation plus run-context assembly for
  # `Alloy.Tool.Executor`.

  alias Alloy.Agent.State
  alias Alloy.Cancel
  alias Alloy.Internal.Deadline
  alias Alloy.Tool.{Inline, Registry, Validation}

  # Validates a single tool_call map for `Executor.run_tool/3`, defaulting
  # omitted `:input` to `%{}` while preserving explicit `nil` or non-map values.
  @spec validate_tool_call!(map()) :: map()
  def validate_tool_call!(tool_call) do
    _ = validate_non_empty_utf8!(Map.get(tool_call, :id), "tool_call :id")
    _ = validate_non_empty_utf8!(Map.get(tool_call, :name), "tool_call :name")
    Map.put_new(tool_call, :input, %{})
  end

  # Validates the `:tool_fns` override map passed to `Executor.run_tool/3`.
  @spec validate_tool_fns!(term()) :: %{String.t() => Registry.tool()}
  def validate_tool_fns!(tool_fns) when is_map(tool_fns) and not is_struct(tool_fns),
    do: tool_fns

  def validate_tool_fns!(bad) do
    raise ArgumentError,
          ":tool_fns must be a map of tool name => tool, got: #{inspect(bad)}"
  end

  # Validates execution options, clamps deadlines and cancellation tokens
  # against outer state, prepares validation schemas, and returns `{run, inline_tools}`.
  @spec build_run(%{String.t() => Registry.tool()}, State.t(), keyword()) ::
          {map(), %{String.t() => Inline.t()}}
  def build_run(tool_fns, %State{} = state, opts) do
    inline_tools = Map.new(tool_fns, fn {name, tool} -> {name, Registry.to_inline(tool)} end)

    schemas =
      Keyword.get_lazy(opts, :tool_schemas, fn ->
        {prepared, _cache} =
          Validation.prepare(inline_tools, state.config.tool_validation, state.tool_schema_cache)

        prepared
      end)

    raw_on_event = Keyword.get(opts, :on_event)
    on_event = validate_on_event!(raw_on_event)

    emit_tool_updates? =
      validate_event_subscriber!(
        Keyword.get(opts, :event_subscriber?),
        is_function(raw_on_event, 1)
      )

    opt_cancel_token = validate_cancel_token!(Keyword.get(opts, :cancel_token))
    cancel_token = Cancel.combine(state.config.cancel_token, opt_cancel_token)
    timeout = validate_tool_timeout!(Keyword.get(opts, :tool_timeout, state.config.tool_timeout))
    opt_deadline = validate_run_deadline!(Keyword.get(opts, :run_deadline))
    run_deadline = Deadline.min(state.run_deadline, opt_deadline)

    outer_deadline_governs? =
      is_integer(state.run_deadline) and
        (is_nil(opt_deadline) or state.run_deadline <= opt_deadline)

    parent_call_id =
      validate_optional_non_empty_utf8!(
        Keyword.get(opts, :parent_call_id),
        ":parent_call_id",
        fn -> nil end
      )

    seq_ref = validate_event_seq_ref!(Keyword.get(opts, :event_seq_ref))

    corr_id =
      validate_optional_non_empty_utf8!(
        Keyword.get(opts, :event_correlation_id),
        ":event_correlation_id",
        &random_id/0
      )

    turn = validate_event_turn!(Keyword.get(opts, :event_turn), state.turn)

    effective_state = %{
      state
      | config: %{state.config | cancel_token: cancel_token, tool_timeout: timeout},
        run_deadline: run_deadline
    }

    run = %{
      state: effective_state,
      schemas: schemas,
      concurrency: state.config.tool_concurrency || System.schedulers_online(),
      tool_fns: inline_tools,
      context: build_context(effective_state),
      timeout: timeout,
      run_deadline: run_deadline,
      outer_deadline_governs?: outer_deadline_governs?,
      cancel_token: cancel_token,
      parent_call_id: parent_call_id,
      on_event: on_event,
      emit_tool_updates?: emit_tool_updates?,
      seq_ref: seq_ref,
      corr_id: corr_id,
      turn: turn
    }

    {run, inline_tools}
  end

  defp valid_non_empty_utf8?(value) do
    is_binary(value) and byte_size(value) > 0 and String.valid?(value)
  end

  defp validate_non_empty_utf8!(value, label) do
    if valid_non_empty_utf8?(value) do
      value
    else
      raise ArgumentError, "#{label} must be a non-empty UTF-8 string, got: #{inspect(value)}"
    end
  end

  defp validate_optional_non_empty_utf8!(nil, _label, default_fun), do: default_fun.()

  defp validate_optional_non_empty_utf8!(value, label, _default_fun) do
    if valid_non_empty_utf8?(value) do
      value
    else
      raise ArgumentError,
            "#{label} must be a non-empty UTF-8 string or nil, got: #{inspect(value)}"
    end
  end

  defp validate_tool_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_tool_timeout!(bad) do
    raise ArgumentError, ":tool_timeout must be a positive integer, got: #{inspect(bad)}"
  end

  defp validate_run_deadline!(nil), do: nil
  defp validate_run_deadline!(deadline) when is_integer(deadline), do: deadline

  defp validate_run_deadline!(bad) do
    raise ArgumentError, ":run_deadline must be an integer or nil, got: #{inspect(bad)}"
  end

  defp validate_cancel_token!(nil), do: nil

  defp validate_cancel_token!(token) do
    if Cancel.valid?(token) do
      token
    else
      raise ArgumentError,
            ":cancel_token must be an Alloy.Cancel token or nil, got: #{inspect(token)}"
    end
  end

  defp validate_on_event!(nil), do: fn _ -> :ok end
  defp validate_on_event!(fun) when is_function(fun, 1), do: fun

  defp validate_on_event!(bad) do
    raise ArgumentError, ":on_event must be a 1-arity function or nil, got: #{inspect(bad)}"
  end

  defp validate_event_subscriber!(nil, default), do: default
  defp validate_event_subscriber!(flag, _default) when is_boolean(flag), do: flag

  defp validate_event_subscriber!(bad, _default) do
    raise ArgumentError, ":event_subscriber? must be a boolean or nil, got: #{inspect(bad)}"
  end

  defp validate_event_seq_ref!(nil), do: :atomics.new(1, signed: false)

  defp validate_event_seq_ref!(ref) do
    if Cancel.valid_atomics_ref?(ref) do
      ref
    else
      raise ArgumentError,
            ":event_seq_ref must be an :atomics reference with at least 1 slot or nil, got: #{inspect(ref)}"
    end
  end

  defp validate_event_turn!(nil, default), do: default
  defp validate_event_turn!(turn, _default) when is_integer(turn) and turn >= 0, do: turn

  defp validate_event_turn!(bad, _default) do
    raise ArgumentError,
          ":event_turn must be a non-negative integer or nil, got: #{inspect(bad)}"
  end

  defp random_id, do: "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp build_context(%State{} = state) do
    Map.merge(state.config.context, %{
      working_directory: state.config.working_directory
    })
  end
end
