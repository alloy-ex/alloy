defmodule Alloy.Tool.Core.Bash.OutputWorker do
  @moduledoc false
  # Supervised callback worker for `Alloy.Tool.Core.Bash` `:bash_on_output`.
  #
  # Pairs a lightweight owner-monitoring watcher with a linked worker under
  # `Alloy.TaskSupervisor` so even a blocked callback is killed immediately if
  # the port runner crashes or is brutally killed. Bounds queued chunks and
  # bytes via `:atomics` and logs once per command if chunks are dropped under
  # backpressure or cut off by the post-exit flush grace cap.

  alias Alloy.Internal.{Deadline, Sanitize}

  require Logger

  @type t :: {pid(), reference(), :atomics.atomics_ref()} | nil

  @max_chunks 128
  @max_bytes 262_144
  @flush_grace_ms 250

  # Starts the watcher/worker pair for a 1-arity `:bash_on_output` callback, or
  # returns `nil` when no callback is configured.
  @spec start((binary() -> term()) | nil) :: t()
  def start(nil), do: nil

  def start(fun) when is_function(fun, 1) do
    owner = self()
    # Slot 1: queued chunks, Slot 2: queued bytes, Slot 3: drop warning logged?
    budget = :atomics.new(3, signed: false)
    ready_ref = make_ref()

    case Task.Supervisor.start_child(Alloy.TaskSupervisor, fn ->
           Process.flag(:trap_exit, true)
           owner_ref = Process.monitor(owner)
           worker_pid = spawn_link(fn -> worker_loop(fun, budget, false) end)

           send(owner, {:output_worker_ready, ready_ref, worker_pid})

           receive do
             {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
               Process.exit(worker_pid, :kill)

             {:EXIT, ^worker_pid, _reason} ->
               Process.demonitor(owner_ref, [:flush])

             {:EXIT, _supervisor_or_linked, _reason} ->
               Process.exit(worker_pid, :kill)
               Process.demonitor(owner_ref, [:flush])
           end
         end) do
      {:ok, watcher} ->
        watcher_ref = Process.monitor(watcher)

        receive do
          {:output_worker_ready, ^ready_ref, worker_pid} ->
            Process.demonitor(watcher_ref, [:flush])
            mon_ref = Process.monitor(worker_pid)
            {worker_pid, mon_ref, budget}

          {:DOWN, ^watcher_ref, :process, ^watcher, _reason} ->
            nil
        end

      {:error, reason} ->
        exit({:output_worker_start_failed, reason})
    end
  end

  # Enqueues a raw chunk for the callback worker if within the bounded chunk
  # and byte limits; otherwise drops it and logs once per command.
  @spec dispatch(t(), binary()) :: :ok
  def dispatch(nil, _data), do: :ok

  def dispatch({pid, _ref, budget}, data) do
    size = byte_size(data)
    chunks = :atomics.add_get(budget, 1, 1)
    bytes = :atomics.add_get(budget, 2, size)

    if chunks <= @max_chunks and bytes <= @max_bytes do
      send(pid, {:chunk, data})
      :ok
    else
      :atomics.sub(budget, 1, 1)
      :atomics.sub(budget, 2, size)
      log_drop_once(budget, "backpressure queue limit reached")
      :ok
    end
  end

  # Waits up to the post-exit flush grace window (clamped to `deadline`) for
  # queued chunks to drain, aborting immediately on caller death or EXIT signal.
  @spec flush(t(), reference(), integer()) :: :ok | :caller_down | {:exit, term()}
  def flush(nil, _caller_ref, _deadline), do: :ok

  def flush({pid, mon_ref, budget} = worker, caller_ref, deadline) do
    flush_ref = make_ref()
    send(pid, {:flush, self(), flush_ref})
    grace = Deadline.next_wait_ms(deadline, @flush_grace_ms)

    receive do
      {:output_worker_flushed, ^flush_ref} ->
        Process.demonitor(mon_ref, [:flush])
        :ok

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        log_exit(reason)
        :ok

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        kill(worker)
        :caller_down

      {:EXIT, from, reason} when is_pid(from) ->
        kill(worker)
        {:exit, reason}
    after
      grace ->
        kill(worker)
        log_drop_once(budget, "post-exit flush grace window (#{grace}ms) elapsed")
        :ok
    end
  end

  # Brutally kills the worker and flushes its monitor ref.
  @spec kill(t()) :: :ok
  def kill(nil), do: :ok

  def kill({pid, mon_ref, _budget}) do
    Process.exit(pid, :kill)
    Process.demonitor(mon_ref, [:flush])
    :ok
  end

  # Returns the worker's monitor reference, or `nil` when no worker is active.
  @spec monitor_ref(t()) :: reference() | nil
  def monitor_ref({_pid, mon_ref, _budget}), do: mon_ref
  def monitor_ref(nil), do: nil

  # Logs an unexpected callback worker exit with redacted reason.
  @spec log_exit(term()) :: :ok
  def log_exit(:normal), do: :ok

  def log_exit({:shutdown, {:callback_exit, summary}}) when is_binary(summary) do
    Logger.warning(
      "[Alloy.Tool.Core.Bash] :bash_on_output callback worker exited (#{summary}); command continues without further callback output."
    )

    :ok
  end

  def log_exit(reason) do
    Logger.warning(
      "[Alloy.Tool.Core.Bash] :bash_on_output callback worker exited (#{Sanitize.exit_summary(reason, :redact)}); command continues without further callback output."
    )

    :ok
  end

  defp worker_loop(fun, budget, logged?) do
    receive do
      {:chunk, data} ->
        :atomics.sub(budget, 1, 1)
        :atomics.sub(budget, 2, byte_size(data))
        next_logged? = invoke_callback(fun, data, logged?)
        worker_loop(fun, budget, next_logged?)

      {:flush, from, ref} ->
        send(from, {:output_worker_flushed, ref})
        :ok
    end
  end

  defp invoke_callback(fun, data, logged?) do
    fun.(data)
    logged?
  rescue
    exception ->
      if not logged? do
        sanitized_trace = Sanitize.stacktrace(__STACKTRACE__)

        Logger.warning(
          "[Alloy.Tool.Core.Bash] :bash_on_output callback failed (#{Sanitize.exception_summary(exception, 500)}); command continues (further failures suppressed).\n" <>
            Exception.format_stacktrace(sanitized_trace)
        )
      end

      true
  catch
    :throw, value ->
      exit({:shutdown, {:callback_exit, Sanitize.exit_summary({:nocatch, value}, :redact)}})

    :exit, :normal ->
      exit(:normal)

    :exit, reason ->
      exit({:shutdown, {:callback_exit, Sanitize.exit_summary(reason, :redact)}})
  end

  defp log_drop_once(budget, reason) do
    if :atomics.compare_exchange(budget, 3, 0, 1) == :ok do
      Logger.warning(
        "[Alloy.Tool.Core.Bash] :bash_on_output dropped queued output (#{reason}); further drops for this command suppressed."
      )
    end

    :ok
  end
end
