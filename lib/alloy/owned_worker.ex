defmodule Alloy.OwnedWorker do
  @moduledoc false
  # Runs a function inside a linked worker owned by a supervised task under
  # `Alloy.TaskSupervisor` that monitors the caller, enforces an absolute
  # monotonic deadline, propagates Logger metadata and OpenTelemetry context,
  # preserves abnormal worker exits so linked children are torn down on crash,
  # and terminates the worker immediately on caller death, explicit cancel,
  # deadline expiry, or supervisor shutdown. (Note: an external `:kill` sent
  # directly to the owner task bypasses owner cleanup, so a worker that sets
  # `:trap_exit` would not receive an explicit kill in that edge case.)

  alias Alloy.Internal.Sanitize

  @worker_kill_timeout_ms 1_000
  @cancel_timeout_ms 1_500

  @spec start(integer(), (-> term())) :: Task.t()
  def start(deadline, fun)
      when is_integer(deadline) and is_function(fun, 0) do
    caller = self()
    caller_ctx = capture_caller_context()

    Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
      Process.flag(:trap_exit, true)
      caller_ref = Process.monitor(caller)

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} ->
          :caller_down

        {:EXIT, from, reason} when is_pid(from) ->
          Process.demonitor(caller_ref, [:flush])
          exit(reason)
      after
        0 ->
          callers = [self() | Process.get(:"$callers", [])]
          owner = self()
          done_ref = make_ref()

          worker =
            spawn_link(fn ->
              Process.put(:"$callers", callers)
              restore_caller_context(caller_ctx)
              run_worker(owner, done_ref, fun)
            end)

          await_worker(caller_ref, worker, done_ref, deadline)
      end
    end)
  end

  # Gracefully signals the owner to brutally kill and await its worker before
  # exiting, so workers trapping exits cannot survive cancellation.
  @spec cancel(Task.t()) :: :ok
  def cancel(%Task{} = owner) do
    _ = Task.shutdown(owner, @cancel_timeout_ms)
    :ok
  end

  @spec shutdown_reason?(term()) :: boolean()
  def shutdown_reason?(:shutdown), do: true
  def shutdown_reason?({:shutdown, _}), do: true
  def shutdown_reason?(_), do: false

  @spec format_exit_reason(term()) :: String.t()
  def format_exit_reason(reason), do: Sanitize.exit_summary(reason, :redact)

  defp run_worker(owner, done_ref, fun) do
    result = fun.()
    send(owner, {done_ref, {:ok, result}})
  catch
    kind, reason ->
      send(
        owner,
        {done_ref,
         {:worker_exit, {:worker_crash, kind, reason, Sanitize.stacktrace(__STACKTRACE__)}}}
      )

      terminate_after_crash(kind, reason)
  end

  # Keep abnormal termination intact after reporting the captured crash so
  # ordinary linked children die with the worker instead of leaking on a
  # normal exit. Use a non-normal shutdown tuple for :error/:throw to avoid
  # duplicate BEAM crash logs when the caller re-raises or formats the error.
  defp terminate_after_crash(:exit, :normal), do: :ok
  defp terminate_after_crash(:exit, reason), do: exit(reason)
  defp terminate_after_crash(_kind, _reason), do: exit({:shutdown, :worker_crash})

  defp capture_caller_context do
    %{
      logger_metadata: Logger.metadata(),
      otel_ctx: Process.get(:"$__current_otel_ctx")
    }
  end

  defp restore_caller_context(%{logger_metadata: meta, otel_ctx: otel_ctx}) do
    Logger.metadata(meta)
    if otel_ctx != nil, do: Process.put(:"$__current_otel_ctx", otel_ctx)
  end

  defp await_worker(caller_ref, worker, done_ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^done_ref, reply} ->
        Process.demonitor(caller_ref, [:flush])
        await_worker_exit(worker)
        reply

      {:EXIT, ^worker, reason} ->
        Process.demonitor(caller_ref, [:flush])
        {:worker_exit, reason}

      # Respect supervisor shutdown and explicit cancel/1 signals promptly by
      # brutally killing and awaiting the worker before exiting.
      {:EXIT, from, reason} when is_pid(from) ->
        Process.demonitor(caller_ref, [:flush])
        kill_worker(worker)
        exit(reason)

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        kill_worker(worker)
        :caller_down
    after
      remaining ->
        Process.demonitor(caller_ref, [:flush])
        kill_worker(worker)
        :timeout
    end
  end

  defp await_worker_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      @worker_kill_timeout_ms -> kill_worker(worker)
    end
  end

  defp kill_worker(worker) do
    Process.exit(worker, :kill)

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      @worker_kill_timeout_ms -> :ok
    end
  end
end
