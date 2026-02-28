defmodule Alloy.Scheduler do
  @moduledoc """
  GenServer for time-based agent runs (cron jobs and heartbeats).

  Schedules `Alloy.run/2` calls at regular intervals using
  `Process.send_after/3`. Each job runs in a supervised Task,
  keeping the Scheduler responsive. Overlap protection ensures
  a job is skipped if its previous run is still in progress.

  ## Usage

      {:ok, pid} = Alloy.Scheduler.start_link(
        jobs: [
          %{
            name: :ci_check,
            every: :timer.minutes(30),
            prompt: "Check CI status and report failures.",
            agent_opts: [
              provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-haiku-4-5-20251001"},
              tools: [Alloy.Tool.Core.Bash]
            ],
            on_result: &MyApp.handle_ci_result/1
          }
        ]
      )

  ## Job Spec

  - `:name` — unique atom identifying the job
  - `:every` — interval in milliseconds
  - `:prompt` — the prompt string passed to `Alloy.run/2`
  - `:agent_opts` — options passed to `Alloy.run/2`
  - `:on_result` — optional callback `(result -> any)`, default: `Logger.info`
  """

  use GenServer

  require Logger

  @type job :: %{
          name: atom(),
          every: pos_integer(),
          prompt: String.t(),
          agent_opts: keyword(),
          on_result: (term() -> any()) | nil
        }

  defmodule State do
    @moduledoc false
    defstruct jobs: %{},
              timers: %{},
              running: MapSet.new(),
              task_refs: %{},
              generations: %{},
              task_supervisor: nil
  end

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Starts the scheduler with initial jobs.

  ## Options

  - `:jobs` — list of job specs (see module docs)
  - `:name` — optional GenServer name for registration
  - `:task_supervisor` — optional pid or name of an external `Task.Supervisor`.
    When omitted, the scheduler starts its own anonymous supervisor. For
    production use, prefer passing a named supervisor from your application's
    supervision tree for better observability in `:observer` and telemetry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, name_opts)
  end

  @doc """
  Lists all registered jobs.
  """
  @spec list_jobs(GenServer.server()) :: [job()]
  def list_jobs(server) do
    GenServer.call(server, :list_jobs)
  end

  @doc """
  Adds a job dynamically. The first tick fires after `job.every` ms.
  """
  @spec add_job(GenServer.server(), job()) :: :ok
  def add_job(server, job) do
    GenServer.call(server, {:add_job, job})
  end

  @doc """
  Removes a job by name. Cancels its pending timer.
  """
  @spec remove_job(GenServer.server(), atom()) :: :ok
  def remove_job(server, name) do
    GenServer.call(server, {:remove_job, name})
  end

  @doc """
  Manually triggers a job immediately, ignoring its schedule.

  Returns `{:error, :already_running}` if the job is currently executing.
  """
  @spec trigger(GenServer.server(), atom()) :: :ok | {:error, :not_found | :already_running}
  def trigger(server, name) do
    GenServer.call(server, {:trigger, name})
  end

  # ── Server Callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    task_sup =
      case Keyword.get(opts, :task_supervisor) do
        nil ->
          {:ok, pid} = Task.Supervisor.start_link()
          pid

        pid when is_pid(pid) ->
          pid

        name when is_atom(name) ->
          name
      end

    state = %State{task_supervisor: task_sup}

    jobs = Keyword.get(opts, :jobs, [])

    state =
      Enum.reduce(jobs, state, fn job, acc ->
        schedule_job(acc, job)
      end)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:list_jobs, _from, state) do
    jobs = Map.values(state.jobs)
    {:reply, jobs, state}
  end

  @impl GenServer
  def handle_call({:add_job, job}, _from, state) do
    state = cancel_job(state, job.name)

    gen = Map.get(state.generations, job.name, 0) + 1
    state = %{state | generations: Map.put(state.generations, job.name, gen)}
    state = schedule_job(state, job)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:remove_job, name}, _from, state) do
    state = cancel_job(state, name)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:trigger, name}, _from, state) do
    case Map.fetch(state.jobs, name) do
      {:ok, _job} ->
        if MapSet.member?(state.running, name) do
          {:reply, {:error, :already_running}, state}
        else
          state = run_job(state, name)
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_info({:tick, name}, state) do
    state =
      if MapSet.member?(state.running, name) do
        Logger.warning("Alloy.Scheduler: skipping #{name} (still running)")
        reschedule(state, name)
      else
        state = run_job(state, name)
        reschedule(state, name)
      end

    {:noreply, state}
  end

  # Task completed successfully
  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{name, gen}, task_refs} ->
        current_gen = Map.get(state.generations, name, 0)
        job = Map.get(state.jobs, name)

        cond do
          job == nil ->
            # Job was removed while task was in-flight — drop result silently.
            :ok

          gen != current_gen ->
            Logger.warning(
              "Alloy.Scheduler: discarding stale result for #{name} (gen #{gen} != #{current_gen})"
            )

          true ->
            callback = job[:on_result] || (&default_on_result/1)
            callback.(result)
        end

        state = %{state | running: MapSet.delete(state.running, name), task_refs: task_refs}
        {:noreply, state}
    end
  end

  # Task crashed
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{name, _gen}, task_refs} ->
        Logger.error("Alloy.Scheduler: job #{name} crashed: #{inspect(reason)}")
        state = %{state | running: MapSet.delete(state.running, name), task_refs: task_refs}
        {:noreply, state}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp schedule_job(state, job) do
    timer_ref = Process.send_after(self(), {:tick, job.name}, job.every)

    %{
      state
      | jobs: Map.put(state.jobs, job.name, job),
        timers: Map.put(state.timers, job.name, timer_ref)
    }
  end

  defp cancel_job(state, name) do
    case Map.get(state.timers, name) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    %{
      state
      | jobs: Map.delete(state.jobs, name),
        timers: Map.delete(state.timers, name)
    }
  end

  defp reschedule(state, name) do
    case Map.get(state.jobs, name) do
      nil ->
        state

      job ->
        timer_ref = Process.send_after(self(), {:tick, job.name}, job.every)
        %{state | timers: Map.put(state.timers, job.name, timer_ref)}
    end
  end

  defp run_job(state, name) do
    case Map.get(state.jobs, name) do
      nil ->
        state

      job ->
        gen = Map.get(state.generations, name, 0)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            Alloy.run(job.prompt, job.agent_opts)
          end)

        %{
          state
          | running: MapSet.put(state.running, name),
            task_refs: Map.put(state.task_refs, task.ref, {name, gen})
        }
    end
  end

  defp default_on_result({:ok, result}) do
    Logger.info("Alloy.Scheduler: job completed — #{result.text || "(no text)"}")
  end

  defp default_on_result({:error, result}) do
    Logger.error("Alloy.Scheduler: job failed — #{inspect(result.error)}")
  end
end
