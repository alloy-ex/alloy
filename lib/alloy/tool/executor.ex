defmodule Alloy.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Calls run in the order the model made them. Consecutive calls to tools
  that are safe to run concurrently (the default; see
  `c:Alloy.Tool.concurrent?/0`) run in parallel; a call to a tool that
  returns `concurrent?: false` waits for everything before it and runs
  alone.

  `:tool_concurrency` limits parallel calls (defaults to the scheduler count).
  `:tool_validation` defaults to required-key checks; `:schema` enables optional
  JSON Schema validation. Each dispatched call outcome passes through
  `:after_tool_call` middleware before transcript and event publication. If the
  run's `:timeout_ms` deadline expires before a batch starts, unstarted calls
  (including middleware-blocked calls in that batch) still receive matching
  error `tool_result` blocks in the transcript (preserving any `:before_tool_call`
  block reason) without emitting `:tool_start`/`:tool_end`, running
  `:after_tool_call`, or appearing in `result.tool_calls`.

  Each call runs in an unlinked task under `Alloy.TaskSupervisor`, bounded
  by the agent's `:tool_timeout`. A tool that raises, exits, throws or
  times out produces an `is_error` tool result instead of crashing the
  agent.
  """

  alias Alloy.Agent.State
  alias Alloy.Cancel
  alias Alloy.Internal.{Deadline, Sanitize}
  alias Alloy.{Message, Middleware, OwnedWorker}
  alias Alloy.Tool.Executor.Options
  alias Alloy.Tool.{Inline, Registry, Validation}

  require Logger

  @max_inflight_tool_updates 256
  @cancel_poll_ms 25

  @doc """
  Executes a single tool call through the same pipeline as `execute_all/4`.

  Runs `:before_tool_call` middleware, input required-key and optional JSON
  Schema validation, supervised worker execution bounded by `:tool_timeout` and
  `:run_deadline` with cooperative `:cancel_token` cancellation, crash/exit
  sanitization, incremental `:tool_update` marshalling back to the caller
  process, `:after_tool_call` middleware, result truncation, and `:tool_start` /
  `:tool_update` / `:tool_end` events.

  `tool_call` is a map with `:id`, `:name`, and `:input` (the same shape
  returned by `Alloy.Message.tool_calls/1`).

  ## Options

  - `:tool_fns` — tool registry map overriding `state.tool_fns`
  - `:tool_timeout` — positive integer ms overriding `state.config.tool_timeout`
  - `:run_deadline` — monotonic ms deadline; clamped to `state.run_deadline`
    when the outer state already carries a deadline
  - `:cancel_token` — `Alloy.Cancel.t()` or `nil`; combined with
    `state.config.cancel_token` so passing `nil` or a child token never disarms
    outer cancellation
  - `:parent_call_id` — optional non-empty UTF-8 `String.t()` attached as
    `:parent_call_id` on emitted `:tool_start`, `:tool_update`, and `:tool_end`
    events, tool telemetry metadata, and returned tool-call metadata
  - `:on_event` — `(event -> any())` or `nil`, invoked in the caller process
    with raw `{:tool_start | :tool_update | :tool_end, map()}` tuples (not
    wrapped in `Alloy.Events` v1 envelopes and not rescued; to emit v1
    envelopes inside an existing host stream, pass
    `on_event: &Alloy.Events.emit(event_opts, turn, &1)` together with
    `:event_subscriber?`, `:event_seq_ref`, `:event_correlation_id`, and
    `:event_turn` from `Alloy.Events.normalize_opts/2`)
  - `:event_subscriber?` — boolean or `nil` enabling `:tool_update` streaming
    (defaults to `is_function(opts[:on_event], 1)`)
  - `:event_seq_ref`, `:event_correlation_id`, `:event_turn` — event envelope
    coordination options (`nil` uses defaults)

  ## Returns

  - `{:ok, result_block, tool_call_meta}` — `result_block` is a normalized
    `tool_result` content block (`%{type: "tool_result", ...}`), and
    `tool_call_meta` is the execution metadata map (or `nil` if the call was not
    started because `:cancel_token` was already cancelled or `:run_deadline` had
    already expired)
  - `{:halted, reason}` — `:before_tool_call` middleware halted execution

  ## Example

      {:ok, result_block, meta} =
        Alloy.Tool.Executor.run_tool(
          %{id: "child_1", name: "read", input: %{"file_path" => "mix.exs"}},
          state,
          parent_call_id: parent_call_id
        )
  """
  @spec run_tool(map(), State.t(), keyword()) ::
          {:ok, map(), map() | nil} | {:halted, String.t()}
  def run_tool(tool_call, %State{} = state, opts \\ [])
      when is_map(tool_call) and not is_struct(tool_call) and is_list(opts) do
    normalized_call = Options.validate_tool_call!(tool_call)
    tool_fns = Options.validate_tool_fns!(Keyword.get(opts, :tool_fns, state.tool_fns))
    {run, _inline_tools} = Options.build_run(tool_fns, state, Keyword.delete(opts, :tool_schemas))

    with {:ok, [tagged]} <- tag_tool_calls(run.state, [normalized_call]) do
      [{result_block, meta}] = run_batch([tagged], run)
      {:ok, result_block, meta}
    end
  end

  @doc """
  Executes `tool_calls` against `tool_fns` and returns a user `Alloy.Message`
  holding matching `tool_result` blocks in call order, or `{:halted, reason}`
  if `:before_tool_call` middleware halts the round.

  Equivalent to `execute_all/4` with default options (`[]`), discarding the
  per-call execution metadata list.
  """
  @spec execute_all([map()], %{String.t() => Registry.tool()}, State.t()) ::
          Message.t() | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state) do
    case execute_all(tool_calls, tool_fns, state, []) do
      {:ok, msg, _meta} -> msg
      {:halted, _} = h -> h
    end
  end

  @doc """
  Executes `tool_calls` against `tool_fns` and returns
  `{:ok, result_message, tool_call_metadata}` or `{:halted, reason}`.

  Consecutive calls to concurrency-safe tools (`c:Alloy.Tool.concurrent?/0`)
  run in parallel up to `:tool_concurrency`; sequential tools wait for earlier
  calls and run alone in call order. Accepts the same execution and event
  coordination options as `run_tool/3` (`:tool_timeout`, `:run_deadline`,
  `:cancel_token`, `:parent_call_id`, `:on_event`, `:event_subscriber?`,
  `:event_seq_ref`, `:event_correlation_id`, `:event_turn`).
  """
  @spec execute_all([map()], %{String.t() => Registry.tool()}, State.t(), keyword()) ::
          {:ok, Message.t(), [map()]} | {:halted, String.t()}
  def execute_all(tool_calls, tool_fns, %State{} = state, opts) when is_list(opts) do
    {run, inline_tools} = Options.build_run(tool_fns, state, opts)

    with {:ok, tagged} <- tag_tool_calls(run.state, tool_calls) do
      {results, meta} =
        tagged
        |> batches(inline_tools, state.config.tool_concurrency == 1)
        |> Enum.flat_map(&run_batch(&1, run))
        |> Enum.unzip()

      {:ok, Message.tool_results(results), Enum.reject(meta, &is_nil/1)}
    end
  end

  @doc false
  @spec execute_all_for_turn([map()], %{String.t() => Registry.tool()}, State.t(), keyword()) ::
          {:ok, Message.t(), [map()], [Message.t()]}
          | {:deadline_expired, Message.t(), [map()]}
          | {:steering_error, Message.t(), [map()], String.t()}
          | {:halted, String.t()}
  def execute_all_for_turn(tool_calls, tool_fns, %State{} = state, opts) when is_list(opts) do
    {run, inline_tools} = Options.build_run(tool_fns, state, opts)
    poll_steering = Keyword.get(opts, :poll_steering)

    with {:ok, tagged} <- tag_tool_calls(run.state, tool_calls) do
      batches = batches(tagged, inline_tools, state.config.tool_concurrency == 1)
      run_batches(batches, run, poll_steering, [], [])
    end
  end

  defguardp is_worker_reply(reply)
            when reply in [:timeout, :cancelled] or
                   (is_tuple(reply) and tuple_size(reply) == 2 and
                      elem(reply, 0) in [:ok, :worker_exit])

  defp run_batches([], _run, _poll_steering, results_rev, metas_rev) do
    {:ok, Message.tool_results(Enum.reverse(results_rev)), Enum.reverse(metas_rev), []}
  end

  defp run_batches([batch | rest], run, poll_steering, results_rev, metas_rev) do
    {batch_results, batch_metas} = batch |> run_batch(run) |> Enum.unzip()
    next_results_rev = Enum.reverse(batch_results, results_rev)
    next_metas_rev = batch_metas |> Enum.reject(&is_nil/1) |> Enum.reverse(metas_rev)

    if is_function(poll_steering, 1) and
         not Cancel.cancelled?(run.cancel_token) and
         not Deadline.expired?(run.run_deadline) do
      steering_state = State.append_tool_calls(run.state, Enum.reverse(next_metas_rev))

      handle_steering_poll(
        poll_steering.(steering_state),
        rest,
        run,
        poll_steering,
        next_results_rev,
        next_metas_rev
      )
    else
      run_batches(rest, run, poll_steering, next_results_rev, next_metas_rev)
    end
  end

  defp handle_steering_poll(outcome, rest, run, poll_steering, next_results_rev, next_metas_rev) do
    cond do
      Cancel.cancelled?(run.cancel_token) ->
        skipped = skip_batches(rest, "Not executed: Cancelled")
        all_results = Enum.reverse(next_results_rev, skipped)
        {:ok, Message.tool_results(all_results), Enum.reverse(next_metas_rev), []}

      Deadline.expired?(run.run_deadline) ->
        skipped = skip_batches(rest, deadline_skipped_message(run))
        all_results = Enum.reverse(next_results_rev, skipped)
        {:deadline_expired, Message.tool_results(all_results), Enum.reverse(next_metas_rev)}

      true ->
        apply_steering_outcome(
          outcome,
          rest,
          run,
          poll_steering,
          next_results_rev,
          next_metas_rev
        )
    end
  end

  defp apply_steering_outcome(
         {:ok, []},
         rest,
         run,
         poll_steering,
         next_results_rev,
         next_metas_rev
       ) do
    run_batches(rest, run, poll_steering, next_results_rev, next_metas_rev)
  end

  defp apply_steering_outcome(
         {:ok, steering_msgs},
         rest,
         _run,
         _poll_steering,
         next_results_rev,
         next_metas_rev
       ) do
    skipped = skip_batches(rest, "Skipped due to steering message.")
    all_results = Enum.reverse(next_results_rev, skipped)
    {:ok, Message.tool_results(all_results), Enum.reverse(next_metas_rev), steering_msgs}
  end

  defp apply_steering_outcome(
         {:error, reason},
         rest,
         _run,
         _poll_steering,
         next_results_rev,
         next_metas_rev
       ) do
    skipped = skip_batches(rest, "Not executed: #{reason}")
    all_results = Enum.reverse(next_results_rev, skipped)
    {:steering_error, Message.tool_results(all_results), Enum.reverse(next_metas_rev), reason}
  end

  defp skip_batches(batches, message) do
    batches
    |> List.flatten()
    |> Enum.map(&unexecuted_block(&1, message))
  end

  # Calls run in the order the model made them, so a sequential call sees
  # the effects of every call before it ([read f, edit f] reads first).
  # Consecutive concurrency-safe calls share a parallel batch unless
  # tool_concurrency: 1 is explicitly requested; sequential calls (and all
  # calls under explicit tool_concurrency: 1) run as their own single-call
  # batch so unstarted calls after deadline expiry never emit tool_start.
  defp batches(tagged, _tool_fns, true = _explicit_serial?), do: Enum.map(tagged, &[&1])

  defp batches(tagged, tool_fns, false = _explicit_serial?) do
    tagged
    |> Enum.chunk_by(&concurrent?(&1, tool_fns))
    |> Enum.flat_map(fn [first | _] = batch ->
      if concurrent?(first, tool_fns), do: [batch], else: Enum.map(batch, &[&1])
    end)
  end

  defp concurrent?({:execute, call}, tool_fns) do
    case Map.fetch(tool_fns, call[:name]) do
      {:ok, %Inline{concurrent?: concurrent?}} -> concurrent? != false
      :error -> true
    end
  end

  defp concurrent?({:blocked, _call, _reason}, _tool_fns), do: true

  # Every tool runs in an unlinked, supervised task: a tool that raises,
  # exits or throws, or overruns :tool_timeout, becomes an error result
  # instead of taking down the agent process that called the executor. If
  # that process is killed (a cancelled turn), the tasks are killed too.
  #
  # tool_start is emitted here, before the tasks in a batch exist, and tool_end
  # after each finishes, so on_event always runs in the caller process and every
  # tool_start pairs with a tool_end even on timeout. Sequential calls (and all
  # calls when tool_concurrency: 1) are singleton batches, so expired calls emit
  # no events and are omitted from tool_calls. Inside an already-dispatched
  # parallel batch (tool_concurrency > 1), a queued call dequeued after expiry
  # skips tool execution and emits its matching error tool_end. Parallelism uses
  # the configured cap, defaulting to schedulers_online; a queued call's duration
  # includes its wait.
  defp run_batch(batch, run) do
    cond do
      Cancel.cancelled?(run.cancel_token) ->
        Enum.map(batch, &{unexecuted_block(&1, "Not executed: Cancelled"), nil})

      Deadline.expired?(run.run_deadline) ->
        msg = deadline_skipped_message(run)
        Enum.map(batch, &{unexecuted_block(&1, msg), nil})

      true ->
        started = batch |> Enum.with_index() |> Enum.map(&start(&1, run))
        execute_batch_tasks(started, batch, run)
    end
  end

  # Each tool runs inside an `OwnedWorker` that independently enforces the
  # tool's deadline (`min(now + tool_timeout, run_deadline)`), monitors the
  # caller, and kills the worker immediately on expiry, caller death, or cancel
  # even if the caller is busy inside a slow `:on_event` callback.
  #
  # Incremental `:tool_update` messages are gated on subscriber presence and
  # routed through a per-call process alias (`Process.alias/0`) with a bounded
  # in-flight credit counter. The alias is unaliased the instant the call
  # completes, times out, or aborts so surviving child processes cannot keep
  # replenishing the caller's mailbox during draining or after `:tool_end`.
  defp execute_batch_tasks(started, batch, run) do
    ctx = %{
      run: run,
      max_concurrency: min(length(batch), run.concurrency)
    }

    results = await_batch(%{}, %{}, started, [], ctx)

    results
    |> Enum.sort_by(fn {index, _pair} -> index end)
    |> Enum.map(fn {_index, pair} -> pair end)
  end

  defp await_batch(running, _aliases, [], done, _ctx) when map_size(running) == 0, do: done

  defp await_batch(running, aliases, pending, done, ctx)
       when map_size(running) < ctx.max_concurrency and pending != [] do
    {running, aliases, pending, done} = fill_slots(running, aliases, pending, done, ctx)
    await_batch(running, aliases, pending, done, ctx)
  end

  defp await_batch(running, aliases, pending, done, ctx) do
    # Prioritize terminal worker messages ahead of queued :alloy_tool_update
    # messages so a burst of updates with a slow :on_event callback cannot delay
    # timeout, cancellation, or completion handling.
    receive do
      {ref, reply} when is_map_key(running, ref) and is_worker_reply(reply) ->
        complete_worker(ref, reply, running, aliases, pending, done, ctx)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        complete_worker(ref, {:down, reason}, running, aliases, pending, done, ctx)
    after
      0 ->
        await_batch_blocking(running, aliases, pending, done, ctx)
    end
  end

  defp await_batch_blocking(running, aliases, pending, done, ctx) do
    if Cancel.cancelled?(ctx.run.cancel_token) do
      abort_batch_cancelled(running, pending, done, ctx)
    else
      wait_ms = if ctx.run.cancel_token, do: @cancel_poll_ms, else: :infinity

      receive do
        {ref, reply} when is_map_key(running, ref) and is_worker_reply(reply) ->
          complete_worker(ref, reply, running, aliases, pending, done, ctx)

        {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
          complete_worker(ref, {:down, reason}, running, aliases, pending, done, ctx)

        {:alloy_tool_update, call_alias, call_id, name, start_seq, chunk}
        when is_map_key(aliases, call_alias) ->
          handle_tool_update(
            {call_alias, call_id, name, start_seq, chunk},
            running,
            aliases,
            pending,
            done,
            ctx
          )
      after
        wait_ms ->
          if Cancel.cancelled?(ctx.run.cancel_token),
            do: abort_batch_cancelled(running, pending, done, ctx),
            else: await_batch(running, aliases, pending, done, ctx)
      end
    end
  end

  defp abort_batch_cancelled(running, pending, done, ctx) do
    # Kill every running worker and flush all aliases/replies before invoking
    # :after_tool_call / :on_event so a throwing callback cannot leak siblings.
    stopped =
      running
      |> Enum.map(fn {ref, entry} ->
        if entry.update_alias, do: Process.unalias(entry.update_alias)
        OwnedWorker.cancel(entry.owner)
        Process.demonitor(ref, [:flush])
        flush_worker_reply(ref)
        flush_alias_updates(entry.update_alias)
        entry
      end)
      |> Enum.sort_by(& &1.started.index)

    done_after_running =
      Enum.reduce(stopped, done, fn entry, acc ->
        outcome = {:error, "Tool #{entry.started.call[:name]} was cancelled.", nil}
        [finish(entry.started, outcome, ctx.run) | acc]
      end)

    Enum.reduce(pending, done_after_running, fn started, acc ->
      outcome =
        case started.tag do
          {:blocked, _call, reason} -> {:error, "Blocked: #{reason}", nil}
          {:execute, _call} -> {:error, "Not executed: Cancelled", nil}
        end

      [finish(started, outcome, ctx.run) | acc]
    end)
  end

  defp flush_worker_reply(ref) do
    receive do
      {^ref, _reply} -> flush_worker_reply(ref)
    after
      0 -> :ok
    end
  end

  defp handle_tool_update(
         {call_alias, call_id, name, start_seq, chunk},
         running,
         aliases,
         pending,
         done,
         ctx
       ) do
    ref = Map.fetch!(aliases, call_alias)
    %{inflight: inflight, deadline: call_deadline} = Map.fetch!(running, ref)
    :atomics.sub(inflight, 1, 1)

    _ =
      unless Cancel.cancelled?(ctx.run.cancel_token) or
               Deadline.expired?(ctx.run.run_deadline) or
               Deadline.expired?(call_deadline) do
        run_or_cleanup(running, fn ->
          emit_update(call_id, name, start_seq, chunk, ctx.run)
        end)
      end

    await_batch(running, aliases, pending, done, ctx)
  end

  defp complete_worker(ref, signal, running, aliases, pending, done, ctx) do
    {entry, next_running} = Map.pop!(running, ref)
    next_aliases = deactivate_update_alias(aliases, entry.update_alias)
    maybe_demonitor(ref, signal)
    {outcome, emit_queued?} = worker_outcome(signal, entry, ctx.run)
    done_entry = finish_or_cleanup(entry, outcome, emit_queued?, ctx.run, next_running)
    await_batch(next_running, next_aliases, pending, [done_entry | done], ctx)
  end

  defp maybe_demonitor(_ref, {:down, _reason}), do: :ok

  defp maybe_demonitor(ref, _signal) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp worker_outcome({:ok, outcome}, _entry, _run), do: {outcome, true}

  defp worker_outcome(:timeout, entry, run),
    do: {exit_outcome(entry.started.call, :timeout, run, entry.deadline_capped?), false}

  defp worker_outcome(:cancelled, entry, _run),
    do: {{:error, "Tool #{entry.started.call[:name]} was cancelled.", nil}, false}

  defp worker_outcome({:worker_exit, reason}, entry, run),
    do: {worker_exit_outcome(entry.started.call, reason, run, entry.deadline_capped?), false}

  defp worker_outcome({:down, reason}, entry, run),
    do: {exit_outcome(entry.started.call, reason, run, entry.deadline_capped?), false}

  defp finish_or_cleanup(entry, outcome, emit_queued?, run, remaining_running) do
    run_or_cleanup(remaining_running, fn ->
      if emit_queued? do
        drain_call_updates(entry.update_alias, entry.started.start_seq, run)
      else
        flush_alias_updates(entry.update_alias)
      end

      finish(entry.started, outcome, run)
    end)
  after
    flush_alias_updates(entry.update_alias)
  end

  defp run_or_cleanup(running, fun) do
    fun.()
  catch
    kind, reason ->
      cleanup_running(running)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp cleanup_running(running) do
    Enum.each(running, fn {_ref, %{owner: owner, update_alias: call_alias}} ->
      if call_alias, do: Process.unalias(call_alias)
      OwnedWorker.cancel(owner)
      flush_alias_updates(call_alias)
    end)
  end

  defp deactivate_update_alias(aliases, nil), do: aliases

  defp deactivate_update_alias(aliases, call_alias) do
    Process.unalias(call_alias)
    Map.delete(aliases, call_alias)
  end

  defp fill_slots(running, aliases, [], done, _ctx), do: {running, aliases, [], done}

  defp fill_slots(running, aliases, pending, done, ctx)
       when map_size(running) >= ctx.max_concurrency,
       do: {running, aliases, pending, done}

  defp fill_slots(
         running,
         aliases,
         [%{tag: {:blocked, _call, reason}} = started | rest],
         done,
         ctx
       ) do
    entry =
      run_or_cleanup(running, fn ->
        finish(started, {:error, "Blocked: #{reason}", nil}, ctx.run)
      end)

    fill_slots(running, aliases, rest, [entry | done], ctx)
  end

  defp fill_slots(running, aliases, [started | rest], done, ctx) do
    if Cancel.cancelled?(ctx.run.cancel_token) do
      entry =
        run_or_cleanup(running, fn ->
          finish(started, {:error, "Not executed: Cancelled", nil}, ctx.run)
        end)

      fill_slots(running, aliases, rest, [entry | done], ctx)
    else
      fill_slot_with_budget(running, aliases, started, rest, done, ctx)
    end
  end

  defp fill_slot_with_budget(running, aliases, started, rest, done, ctx) do
    case task_deadline(ctx.run) do
      :expired ->
        entry =
          run_or_cleanup(running, fn ->
            finish(started, deadline_skipped_outcome(ctx.run), ctx.run)
          end)

        fill_slots(running, aliases, rest, [entry | done], ctx)

      {deadline, deadline_capped?} ->
        {call_run, call_alias, inflight} = maybe_attach_tool_updates(ctx.run, started)

        owner =
          try do
            OwnedWorker.start(deadline, fn -> invoke(started.tag, call_run) end,
              cancel_token: ctx.run.cancel_token
            )
          catch
            kind, reason ->
              if call_alias, do: Process.unalias(call_alias)
              cleanup_running(running)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        entry = %{
          owner: owner,
          started: started,
          deadline: deadline,
          deadline_capped?: deadline_capped?,
          update_alias: call_alias,
          inflight: inflight
        }

        next_aliases = if call_alias, do: Map.put(aliases, call_alias, owner.ref), else: aliases
        fill_slots(Map.put(running, owner.ref, entry), next_aliases, rest, done, ctx)
    end
  end

  defp task_deadline(%{run_deadline: nil, timeout: timeout}) do
    {System.monotonic_time(:millisecond) + timeout, false}
  end

  defp task_deadline(%{run_deadline: run_deadline, timeout: timeout}) do
    now = System.monotonic_time(:millisecond)

    if run_deadline <= now do
      :expired
    else
      tool_deadline = now + timeout
      {min(tool_deadline, run_deadline), run_deadline < tool_deadline}
    end
  end

  defp worker_exit_outcome(call, {:worker_crash, :exit, reason, _trace}, run, capped?) do
    exit_outcome(call, reason, run, capped?)
  end

  defp worker_exit_outcome(call, {:worker_crash, :throw, value, _trace}, run, capped?) do
    exit_outcome(call, {:nocatch, value}, run, capped?)
  end

  defp worker_exit_outcome(call, {:worker_crash, :error, exception, _trace}, run, capped?) do
    exit_outcome(call, exception, run, capped?)
  end

  defp worker_exit_outcome(call, reason, run, capped?) do
    exit_outcome(call, reason, run, capped?)
  end

  defp maybe_attach_tool_updates(%{emit_tool_updates?: false} = run, _started) do
    {run, nil, nil}
  end

  defp maybe_attach_tool_updates(run, started) do
    call_alias = Process.alias()
    # Slot 1: in-flight updates, Slot 2: drop warning logged?
    inflight = :atomics.new(2, signed: false)
    call_id = started.call[:id]
    call_name = started.call[:name]
    start_seq = started.start_seq

    on_update = fn
      chunk when is_binary(chunk) and byte_size(chunk) > 0 ->
        if :atomics.add_get(inflight, 1, 1) <= @max_inflight_tool_updates do
          send(
            call_alias,
            {:alloy_tool_update, call_alias, call_id, call_name, start_seq, chunk}
          )
        else
          :atomics.sub(inflight, 1, 1)

          if :atomics.compare_exchange(inflight, 2, 0, 1) == :ok do
            Logger.warning(
              "[Alloy.Tool.Executor] Tool #{call_name} (#{call_id}) dropped :tool_update chunks after reaching #{@max_inflight_tool_updates} in-flight updates; further drops for this call suppressed."
            )
          end
        end

        :ok

      _other ->
        :ok
    end

    {%{run | context: Map.put(run.context, :on_tool_update, on_update)}, call_alias, inflight}
  end

  defp drain_call_updates(nil, _start_seq, _run), do: :ok

  defp drain_call_updates(call_alias, start_seq, run) do
    if Cancel.cancelled?(run.cancel_token) or Deadline.expired?(run.run_deadline) do
      flush_alias_updates(call_alias)
    else
      receive do
        {:alloy_tool_update, ^call_alias, call_id, name, ^start_seq, chunk} ->
          emit_update(call_id, name, start_seq, chunk, run)
          drain_call_updates(call_alias, start_seq, run)
      after
        0 -> :ok
      end
    end
  end

  defp flush_alias_updates(nil), do: :ok

  defp flush_alias_updates(call_alias) do
    receive do
      {:alloy_tool_update, ^call_alias, _id, _name, _seq, _chunk} ->
        flush_alias_updates(call_alias)
    after
      0 -> :ok
    end
  end

  defp emit_update(call_id, name, start_seq, chunk, run) do
    seq = :atomics.add_get(run.seq_ref, 1, 1)

    event =
      %{
        id: call_id,
        name: name,
        chunk: valid_text(chunk),
        start_event_seq: start_seq,
        event_seq: seq,
        correlation_id: run.corr_id
      }
      |> maybe_put_parent_call_id(run.parent_call_id)

    run.on_event.({:tool_update, event})
    :ok
  end

  defp unexecuted_block({:blocked, call, reason}, _message),
    do: Message.tool_result_block(call[:id], "Blocked: #{reason}", true)

  defp unexecuted_block({:execute, call}, message),
    do: Message.tool_result_block(call[:id], message, true)

  defp deadline_skipped_message(%{outer_deadline_governs?: true} = run) do
    case run.state.config.timeout_ms do
      timeout_ms when is_integer(timeout_ms) ->
        "Not executed: Agent run timed out after #{timeout_ms}ms"

      _infinity ->
        "Not executed: Agent run deadline was reached"
    end
  end

  defp deadline_skipped_message(_run) do
    "Not executed: Agent run deadline was reached"
  end

  defp deadline_skipped_outcome(run) do
    {:error, deadline_skipped_message(run), nil}
  end

  defp tag_tool_calls(state, calls) do
    result =
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
        if Cancel.cancelled?(state.config.cancel_token) do
          {:cont, {:ok, [{:execute, call} | acc]}}
        else
          case Middleware.run_before_tool_call(state, call) do
            :ok -> {:cont, {:ok, [{:execute, call} | acc]}}
            :cancelled -> {:cont, {:ok, [{:execute, call} | acc]}}
            {:edit, modified_call} -> {:cont, {:ok, [{:execute, modified_call} | acc]}}
            {:block, reason} -> {:cont, {:ok, [{:blocked, call, reason} | acc]}}
            {:halted, reason} -> {:halt, {:halted, reason}}
          end
        end
      end)

    case result do
      {:ok, tagged} -> {:ok, Enum.reverse(tagged)}
      other -> other
    end
  end

  defp start({tag, index}, run) do
    call = call_from(tag)
    seq = :atomics.add_get(run.seq_ref, 1, 1)

    start_event =
      %{
        id: call[:id],
        name: call[:name],
        input: Map.get(call, :input, %{}),
        event_seq: seq,
        correlation_id: run.corr_id
      }
      |> maybe_put_parent_call_id(run.parent_call_id)

    run.on_event.({:tool_start, start_event})

    telemetry_meta =
      %{
        correlation_id: run.corr_id,
        turn: run.turn,
        tool_id: call[:id],
        tool_name: call[:name]
      }
      |> maybe_put_parent_call_id(run.parent_call_id)

    :telemetry.execute([:alloy, :tool, :start], %{event_seq: seq}, telemetry_meta)

    %{
      index: index,
      tag: tag,
      call: call,
      start_seq: seq,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  # Runs inside the task. Returns {:ok, text, structured_data | nil} or
  # {:error, model_visible_message, diagnostic_message}.
  defp invoke({:execute, call}, run) do
    with {:ok, tool} <- fetch_tool(run.tool_fns, call[:name]),
         input = Map.get(call, :input, %{}),
         :ok <- check_input(input, tool),
         :ok <- Validation.check(input, call[:name], run.schemas) do
      execute_tool(tool, input, call, run.context)
    end
  end

  defp fetch_tool(tool_fns, name) do
    case Map.fetch(tool_fns, name) do
      {:ok, %Inline{} = tool} -> {:ok, tool}
      :error -> {:error, "Unknown tool: #{name}", nil}
    end
  end

  # Only the shape every tool's execute/2 relies on: an object holding the
  # schema's required keys. Types are not checked or coerced; third-party
  # schemas are too loose for that to be safe.
  defp check_input(input, %Inline{name: name, input_schema: schema}) when is_map(input) do
    present = MapSet.new(Map.keys(input), &to_string/1)

    case Enum.reject(required_keys(schema), &(&1 in present)) do
      [] ->
        :ok

      missing ->
        {:error,
         "Missing required parameter(s) for #{name}: #{Enum.join(missing, ", ")}. " <>
           "Call the tool again with every required parameter.", nil}
    end
  end

  defp check_input(input, %Inline{name: name}) do
    {:error, "Input for #{name} must be a JSON object, got: #{Sanitize.inspect_bounded(input)}",
     nil}
  end

  defp required_keys(schema) do
    case Map.get(schema, :required, Map.get(schema, "required")) do
      keys when is_list(keys) -> Enum.map(keys, &to_string/1)
      _none -> []
    end
  end

  defp execute_tool(%Inline{execute: execute} = tool, input, call, context) do
    case execute.(input, context) do
      {:ok, text, data} when is_map(data) -> {:ok, maybe_truncate(text, tool), data}
      {:ok, text} -> {:ok, maybe_truncate(text, tool), nil}
      {:error, reason} -> {:error, reason, nil}
    end
  rescue
    e ->
      stacktrace = Sanitize.stacktrace(__STACKTRACE__)
      summary = Sanitize.exception_summary(e, 500)
      formatted_trace = Exception.format_stacktrace(stacktrace)

      diagnostic_header = "** #{Sanitize.exception_header(e, 500)}"

      Logger.error("Tool #{call[:name]} crashed: #{summary}\n#{formatted_trace}")

      {:error, tool_crash_message(call[:name], summary, stacktrace),
       "#{diagnostic_header}\n#{formatted_trace}"}
  end

  defp exit_outcome(call, :timeout, run, true = _deadline_capped?) do
    run_deadline_timeout_outcome(call, run)
  end

  defp exit_outcome(call, :timeout, run, false = _deadline_capped?) do
    if Deadline.expired?(run.run_deadline) do
      run_deadline_timeout_outcome(call, run)
    else
      {:error,
       "Tool #{call[:name]} timed out after #{run.timeout}ms. " <>
         "Try a smaller input or raise :tool_timeout.", nil}
    end
  end

  defp exit_outcome(call, reason, _run, _deadline_capped?) do
    {:error,
     "Tool #{call[:name]} crashed during execution: #{Sanitize.exit_summary(reason)}. " <>
       "Check the input and try again.", nil}
  end

  defp run_deadline_timeout_outcome(call, %{outer_deadline_governs?: true} = run) do
    detail =
      case run.state.config.timeout_ms do
        timeout_ms when is_integer(timeout_ms) -> " (#{timeout_ms}ms)"
        _infinity -> ""
      end

    {:error, "Tool #{call[:name]} timed out because the run deadline#{detail} was reached.", nil}
  end

  defp run_deadline_timeout_outcome(call, _run) do
    {:error, "Tool #{call[:name]} timed out because the run deadline was reached.", nil}
  end

  defp finish(started, outcome, run) do
    %{call: call, start_seq: start_seq} = started

    {block, error, structured_data} =
      case outcome do
        {:ok, text, data} ->
          {Message.tool_result_block(call[:id], valid_text(text), false), nil, data}

        {:error, visible, diagnostic} ->
          {Message.tool_result_block(call[:id], valid_text(visible), true),
           valid_text(diagnostic || visible), nil}
      end

    original = %{
      content: block.content,
      data: structured_data,
      is_error: Map.get(block, :is_error, false)
    }

    result = Middleware.run_after_tool_call(run.state, call, original)

    block = %{block | content: bounded_result(result.content, original.content, call, run)}

    meta =
      %{
        id: call[:id],
        name: call[:name],
        input: Map.get(call, :input, %{}),
        duration_ms: max(System.monotonic_time(:millisecond) - started.started_at, 0),
        error: result_error(error, original, result)
      }
      |> maybe_put_parent_call_id(run.parent_call_id)

    end_seq = emit_end(meta, start_seq, run)

    meta =
      meta
      |> Map.merge(%{
        correlation_id: run.corr_id,
        start_event_seq: start_seq,
        end_event_seq: end_seq
      })
      |> maybe_put_structured_data(result.data)

    {started.index, {block, meta}}
  end

  defp result_error(nil, _original, _result), do: nil
  defp result_error(error, result, result), do: error
  defp result_error(_error, _original, result), do: result.content

  defp bounded_result(content, content, _call, _run), do: content

  defp bounded_result(content, _original, call, run) do
    case Map.fetch(run.tool_fns, call[:name]) do
      {:ok, %Inline{} = tool} -> maybe_truncate(valid_text(content), tool)
      :error -> valid_text(content)
    end
  end

  # Tool output is sent back to the provider as JSON on every later turn.
  # One invalid byte (a binary file, `cat` of a latin-1 log) would make
  # every request of the session fail to encode, so it is replaced here.
  defp valid_text(text) when is_binary(text), do: String.replace_invalid(text)
  defp valid_text(other), do: other

  defp emit_end(meta, start_seq, run) do
    seq = :atomics.add_get(run.seq_ref, 1, 1)

    event =
      Map.merge(meta, %{event_seq: seq, correlation_id: run.corr_id, start_event_seq: start_seq})

    run.on_event.({:tool_end, event})

    telemetry_meta =
      %{
        correlation_id: run.corr_id,
        turn: run.turn,
        tool_id: meta.id,
        tool_name: meta.name,
        error: meta.error,
        start_event_seq: start_seq
      }
      |> maybe_put_parent_call_id(run.parent_call_id)

    :telemetry.execute(
      [:alloy, :tool, :stop],
      %{event_seq: seq, duration_ms: meta.duration_ms},
      telemetry_meta
    )

    seq
  end

  defp call_from({:execute, c}), do: c
  defp call_from({:blocked, c, _}), do: c

  defp tool_crash_message(tool_name, summary, stacktrace) do
    "Tool #{tool_name} crashed: #{summary} " <>
      "(#{format_top_stack_frame(stacktrace)}). Check the input and try again."
  end

  defp format_top_stack_frame([{module, function, arity, info} | _]) when is_integer(arity) do
    file = info |> Keyword.get(:file, "unknown") |> to_string() |> Path.basename()
    line = Keyword.get(info, :line, "?")

    "#{inspect(module)}.#{function}/#{arity} at #{file}:#{line}"
  end

  defp format_top_stack_frame([{fun, arity, info} | _]) when is_integer(arity) do
    file = info |> Keyword.get(:file, "unknown") |> to_string() |> Path.basename()
    line = Keyword.get(info, :line, "?")

    "#{inspect(fun)}/#{arity} at #{file}:#{line}"
  end

  defp format_top_stack_frame(_stacktrace), do: "unknown location"

  defp maybe_put_structured_data(meta, nil), do: meta
  defp maybe_put_structured_data(meta, data), do: Map.put(meta, :structured_data, data)

  defp maybe_put_parent_call_id(map, nil), do: map

  defp maybe_put_parent_call_id(map, parent_call_id),
    do: Map.put(map, :parent_call_id, parent_call_id)

  defp maybe_truncate(text, %Inline{max_result_chars: max_result_chars}) when is_binary(text) do
    case max_result_chars do
      max when is_integer(max) and max > 0 ->
        len = String.length(text)

        if len > max do
          head = div(max * 4, 5)
          tail = max - head

          String.slice(text, 0, head) <>
            "\n\n[truncated " <>
            Integer.to_string(len) <>
            " -> " <>
            Integer.to_string(max) <>
            " chars]\n\n" <>
            String.slice(text, -tail, tail)
        else
          text
        end

      _unlimited_or_nil ->
        text
    end
  end

  defp maybe_truncate(text, _tool), do: text
end
