defmodule MinimalHost.CodeMode do
  @moduledoc """
  Host-owned nested execution experiment for trusted programs.

  This is not a sandbox and never evaluates model-supplied Elixir. A host may
  connect a separately sandboxed interpreter to the dispatch capability. Single
  child calls route through `Alloy.Tool.Executor.run_tool/3` and multi-call
  batches route through `Alloy.Tool.Executor.execute_all/4`, preserving Alloy's
  middleware, schema validation, deadlines, cooperative cancellation, and
  native `:parent_call_id` event tagging.
  """

  alias Alloy.Agent.State
  alias Alloy.{Message, Middleware}
  alias Alloy.Tool.Executor

  @spec run((function() -> term()), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(program, %State{} = state, opts) when is_function(program, 1) do
    timeout = Keyword.fetch!(opts, :timeout)
    max_calls = Keyword.fetch!(opts, :max_calls)
    parent = Keyword.fetch!(opts, :parent_call_id)

    if not (is_integer(timeout) and timeout > 0 and is_integer(max_calls) and max_calls > 0 and
              is_binary(parent) and byte_size(parent) > 0 and String.valid?(parent)) do
      raise ArgumentError,
            "positive timeout/max_calls and a non-empty UTF-8 parent_call_id are required"
    end

    deadline = System.monotonic_time(:millisecond) + timeout
    run_opts = Keyword.put(opts, :run_deadline, deadline)
    task = Task.async(fn -> run_program(program, state, run_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _stopped -> {:error, :timeout}
    end
  end

  defp run_program(program, state, opts) do
    key = make_ref()
    owner = self()
    script_name = Keyword.get(opts, :script_tool_name, "run_script")
    state = %{state | tool_fns: Map.delete(state.tool_fns, script_name)}
    Process.put(key, {state, 0})

    try do
      dispatch = fn calls_or_call ->
        if self() != owner,
          do: raise(ArgumentError, "dispatch must run in the interpreter process")

        dispatch(calls_or_call, key, opts)
      end

      result = program.(dispatch)
      check_interpreter_deadline!(Keyword.fetch!(opts, :run_deadline))
      {:ok, result}
    catch
      :throw, :timeout -> {:error, :timeout}
      kind, reason -> {:error, {kind, reason}}
    after
      Process.delete(key)
    end
  end

  defp dispatch(call, key, opts) when is_map(call) and not is_struct(call) do
    %{results: [result], metadata: metadata} = dispatch([call], key, opts)
    %{result: result, metadata: List.first(metadata)}
  end

  defp dispatch(calls, key, opts) when is_list(calls) do
    deadline = Keyword.fetch!(opts, :run_deadline)
    check_interpreter_deadline!(deadline)

    {state, used} = Process.get(key)
    total = used + length(calls)
    if total > Keyword.fetch!(opts, :max_calls), do: throw(:call_limit)
    parent = Keyword.fetch!(opts, :parent_call_id)

    calls =
      Enum.with_index(calls, used + 1)
      |> Enum.map(fn {call, index} ->
        %{
          id: "#{parent}-#{index}",
          name: Map.fetch!(call, :name),
          input: Map.fetch!(call, :input)
        }
      end)

    Process.put(key, {state, total})

    requested =
      State.append_messages(
        state,
        Message.assistant_blocks(Enum.map(calls, &Map.put(&1, :type, "tool_use")))
      )

    executor_opts = [
      parent_call_id: parent,
      run_deadline: deadline,
      on_event: Keyword.get(opts, :on_event)
    ]

    with %State{} = ready <- Middleware.run(:after_tool_request, requested),
         {:ok, results, metadata} <- run_child_calls(calls, ready, executor_opts),
         :ok <- check_interpreter_deadline!(deadline),
         %State{} = finished <-
           ready
           |> State.append_messages(results)
           |> State.append_tool_calls(metadata)
           |> then(&Middleware.run(:after_tool_execution, &1)) do
      check_interpreter_deadline!(deadline)
      Process.put(key, {finished, total})
      %{results: results.content, metadata: metadata}
    else
      {:halted, reason} -> throw({:halted, reason})
    end
  end

  defp check_interpreter_deadline!(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      throw(:timeout)
    else
      :ok
    end
  end

  defp run_child_calls([single_call], ready, executor_opts) do
    case Executor.run_tool(single_call, ready, executor_opts) do
      {:ok, result_block, meta} ->
        metadata = if meta, do: [meta], else: []
        {:ok, Message.tool_results([result_block]), metadata}

      {:halted, reason} ->
        {:halted, reason}
    end
  end

  defp run_child_calls(calls, ready, executor_opts) do
    Executor.execute_all(calls, ready.tool_fns, ready, executor_opts)
  end
end
