defmodule Alloy.Team do
  @moduledoc """
  Supervisor-style coordinator for multi-agent teams.

  Wraps multiple `Alloy.Agent.Server` processes behind a single GenServer,
  providing named agent lookup, delegation, broadcasting, and sequential
  handoff. Each agent runs in its own process with fault isolation — one
  agent crashing does not affect the others.

  ## Usage

      {:ok, team} = Alloy.Team.start_link(
        agents: [
          researcher: [provider: {Anthropic, api_key: key}, tools: [WebSearch]],
          coder: [provider: {Anthropic, api_key: key}, tools: [Read, Write, Edit, Bash]]
        ]
      )

      # Send to a specific agent
      {:ok, result} = Alloy.Team.delegate(team, :researcher, "Find Elixir release notes")

      # Send to all agents in parallel
      results = Alloy.Team.broadcast(team, "What do you know about Elixir?")

      # Chain: researcher output becomes coder input
      {:ok, result} = Alloy.Team.handoff(team, [:researcher, :coder], "Find and implement...")

  ## Dynamic Management

      :ok = Alloy.Team.add_agent(team, :reviewer, reviewer_opts)
      :ok = Alloy.Team.remove_agent(team, :reviewer)

  ## Direct Access

      pid = Alloy.Team.get_agent(team, :coder)
      {:ok, result} = Alloy.Agent.Server.chat(pid, "Read mix.exs")
  """

  use GenServer

  alias Alloy.Agent.Server

  defstruct agents: %{},
            monitors: %{},
            supervisor: nil,
            task_supervisor: nil,
            pending_replies: %{},
            shared_context: %{}

  # ── Client API ──────────────────────────────────────────────────────

  @doc """
  Start a team process with named agents.

  ## Options

    - `:agents` - Keyword list of `{name, agent_opts}` (default: `[]`)
    - `:name` - Register the team process (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, team_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, team_opts, name_opts)
  end

  @doc """
  Send a message to a named agent and wait for the result.

  The Team GenServer remains responsive while the agent works — concurrent
  delegates to different agents run in parallel.

  ## Options

    - `:timeout` - Milliseconds to wait before raising a timeout exit. Defaults
      to `120_000` (2 minutes). Use `:infinity` to wait forever. The agent
      receives this timeout directly. The outer `GenServer.call` adds a 1-second
      coordination buffer so the agent-level timeout resolves before the caller
      times out.
  """
  @spec delegate(GenServer.server(), atom(), String.t(), keyword()) ::
          {:ok, Server.result()} | {:error, term()}
  def delegate(team, agent_name, message, opts \\ [])
      when is_atom(agent_name) and is_binary(message) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    outer_timeout = coordination_timeout(timeout)
    GenServer.call(team, {:delegate, agent_name, message, timeout}, outer_timeout)
  end

  @doc """
  Send a message to all agents in parallel and collect results.

  Returns a map of `%{agent_name => {:ok, result} | {:error, reason}}`.

  ## Options

    - `:timeout` - Milliseconds to wait before raising a timeout exit. Defaults
      to `120_000` (2 minutes). Use `:infinity` to wait forever. Each individual
      agent receives this timeout. The outer `GenServer.call` adds a 1-second
      coordination buffer so that agent-level timeouts resolve before the caller
      times out.
  """
  @spec broadcast(GenServer.server(), String.t(), keyword()) :: %{atom() => term()}
  def broadcast(team, message, opts \\ []) when is_binary(message) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    outer_timeout = coordination_timeout(timeout)
    GenServer.call(team, {:broadcast, message, timeout}, outer_timeout)
  end

  @doc """
  Chain agents sequentially — each agent's text output becomes the next
  agent's input message.

  Returns `{:ok, result}` from the last agent in the chain, or the first
  error encountered.

  ## Options

    - `:timeout` - Milliseconds to wait before raising a timeout exit. Defaults
      to `120_000` (2 minutes). Use `:infinity` to wait forever. This timeout
      applies both to the outer GenServer call and to each individual agent call
      within the chain.
  """
  # Returns {:ok, nil} when agent_names is empty — no handoff occurred.
  @spec handoff(GenServer.server(), [atom()], String.t(), keyword()) ::
          {:ok, Server.result() | nil} | {:error, term()}
  def handoff(team, agent_names, message, opts \\ [])
      when is_list(agent_names) and is_binary(message) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    outer_timeout =
      if timeout == :infinity,
        do: :infinity,
        else: coordination_timeout(max(timeout * length(agent_names), timeout))

    GenServer.call(team, {:handoff, agent_names, message, timeout}, outer_timeout)
  end

  @doc """
  Dynamically add a new agent to the team.
  """
  @spec add_agent(GenServer.server(), atom(), keyword()) :: :ok | {:error, term()}
  def add_agent(team, name, opts) when is_atom(name) and is_list(opts) do
    GenServer.call(team, {:add_agent, name, opts})
  end

  @doc """
  Remove an agent from the team and stop its process.
  """
  @spec remove_agent(GenServer.server(), atom()) :: :ok | {:error, term()}
  def remove_agent(team, name) when is_atom(name) do
    GenServer.call(team, {:remove_agent, name})
  end

  @doc """
  List all running agents as a keyword list of `{name, pid}`.
  """
  @spec agents(GenServer.server()) :: keyword(pid())
  def agents(team) do
    GenServer.call(team, :agents)
  end

  @doc """
  Get the pid of a named agent for direct `Server` API access.

  Returns `nil` if the agent doesn't exist.
  """
  @spec get_agent(GenServer.server(), atom()) :: pid() | nil
  def get_agent(team, name) when is_atom(name) do
    GenServer.call(team, {:get_agent, name})
  end

  @doc """
  Store a value in the team's shared context.
  """
  @spec put_context(GenServer.server(), atom(), term()) :: :ok
  def put_context(team, key, value) when is_atom(key) do
    GenServer.call(team, {:put_context, key, value})
  end

  @doc """
  Retrieve a value from the team's shared context.

  Returns `default` (nil if not provided) when the key doesn't exist.
  """
  @spec get_context(GenServer.server(), atom(), term()) :: term()
  def get_context(team, key, default \\ nil) when is_atom(key) do
    GenServer.call(team, {:get_context, key, default})
  end

  @doc """
  Stop the team and all its agents.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(team) do
    GenServer.stop(team)
  end

  # ── Server Callbacks ────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, task_sup} = Task.Supervisor.start_link()

    agents_config = Keyword.get(opts, :agents, [])
    shared_context = Keyword.get(opts, :shared_context, %{})

    initial_state = %__MODULE__{
      supervisor: sup,
      task_supervisor: task_sup,
      shared_context: shared_context
    }

    result =
      Enum.reduce_while(agents_config, {:ok, initial_state}, fn {name, agent_opts}, {:ok, acc} ->
        case start_agent(acc.supervisor, agent_opts) do
          {:ok, pid} -> {:cont, {:ok, track_agent(acc, name, pid)}}
          {:error, reason} -> {:halt, {:error, name, reason}}
        end
      end)

    case result do
      {:ok, state} -> {:ok, state}
      {:error, name, reason} -> {:stop, {:failed_to_start_agent, name, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Task.Supervisor and DynamicSupervisor stop cascades to children
    for sup <- [state.task_supervisor, state.supervisor],
        sup != nil and Process.alive?(sup) do
      Process.exit(sup, :shutdown)
    end

    :ok
  end

  # ── Delegate (async reply) ──────────────────────────────────────────

  @impl GenServer
  def handle_call({:delegate, name, message, timeout}, from, state) do
    case Map.get(state.agents, name) do
      nil ->
        {:reply, {:error, {:unknown_agent, name}}, state}

      pid ->
        state =
          start_reply_task(state, from, fn -> Server.chat(pid, message, timeout: timeout) end)

        {:noreply, state}
    end
  end

  # ── Broadcast (async reply) ─────────────────────────────────────────

  @impl GenServer
  def handle_call({:broadcast, message, timeout}, from, state) do
    agents_snapshot = state.agents

    if map_size(agents_snapshot) == 0 do
      {:reply, %{}, state}
    else
      state =
        start_reply_task(state, from, fn ->
          agents_list = Map.to_list(agents_snapshot)

          agents_list
          |> Task.async_stream(
            fn {name, pid} ->
              result =
                try do
                  Server.chat(pid, message, timeout: timeout)
                catch
                  :exit, reason -> {:error, {:exit, reason}}
                end

              {name, result}
            end,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.zip(agents_list)
          |> Enum.reduce(%{}, fn
            {{:ok, {name, result}}, _agent}, acc ->
              Map.put(acc, name, result)

            {{:exit, reason}, {name, _pid}}, acc ->
              # Task was killed externally (:kill bypasses try/catch).
              # By zipping with the original list, we recover the name and report it.
              Map.put(acc, name, {:error, {:task_crashed, reason}})
          end)
        end)

      {:noreply, state}
    end
  end

  # ── Handoff (async reply) ───────────────────────────────────────────

  @impl GenServer
  def handle_call({:handoff, names, initial_message, timeout}, from, state) do
    agents_snapshot = state.agents

    state =
      start_reply_task(state, from, fn ->
        run_handoff(names, initial_message, agents_snapshot, timeout)
      end)

    {:noreply, state}
  end

  # ── Agent Management ────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:add_agent, name, opts}, _from, state) do
    if Map.has_key?(state.agents, name) do
      {:reply, {:error, :agent_already_exists}, state}
    else
      case start_agent(state.supervisor, opts) do
        {:ok, pid} ->
          {:reply, :ok, track_agent(state, name, pid)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:remove_agent, name}, _from, state) do
    case Map.get(state.agents, name) do
      nil ->
        {:reply, {:error, {:unknown_agent, name}}, state}

      pid ->
        # Find and demonitor
        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, state.monitors}, fn {r, n}, {found, acc} ->
            if n == name, do: {r, Map.delete(acc, r)}, else: {found, acc}
          end)

        if ref, do: Process.demonitor(ref, [:flush])

        # Stop the agent
        if Process.alive?(pid), do: Server.stop(pid)

        new_state = %{state | agents: Map.delete(state.agents, name), monitors: monitors}
        {:reply, :ok, new_state}
    end
  end

  # ── Introspection ──────────────────────────────────────────────────

  @impl GenServer
  def handle_call(:agents, _from, state) do
    {:reply, Map.to_list(state.agents), state}
  end

  @impl GenServer
  def handle_call({:get_agent, name}, _from, state) do
    {:reply, Map.get(state.agents, name), state}
  end

  # ── Shared Context ─────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:put_context, key, value}, _from, state) do
    new_context = Map.put(state.shared_context, key, value)
    {:reply, :ok, %{state | shared_context: new_context}}
  end

  @impl GenServer
  def handle_call({:get_context, key, default}, _from, state) do
    {:reply, Map.get(state.shared_context, key, default), state}
  end

  # ── Task Result Handling ──────────────────────────────────────────

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Successful task completion — demonitor and flush :DOWN
    Process.demonitor(ref, [:flush])

    case Map.pop(state.pending_replies, ref) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_replies: pending}}
    end
  end

  # ── Monitor Handling ───────────────────────────────────────────────

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Check if it's a pending reply task that crashed
    case Map.pop(state.pending_replies, ref) do
      {nil, _} ->
        # Must be an agent monitor
        case Map.get(state.monitors, ref) do
          nil ->
            {:noreply, state}

          name ->
            new_state = %{
              state
              | agents: Map.delete(state.agents, name),
                monitors: Map.delete(state.monitors, ref)
            }

            {:noreply, new_state}
        end

      {from, pending} ->
        # Reply task crashed — unblock the caller with an error
        GenServer.reply(from, {:error, {:task_crashed, reason}})
        {:noreply, %{state | pending_replies: pending}}
    end
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp start_reply_task(state, from, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(state.task_supervisor, fun)
    %{state | pending_replies: Map.put(state.pending_replies, ref, from)}
  end

  defp start_agent(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, %{
      id: make_ref(),
      start: {Server, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp track_agent(state, name, pid) do
    ref = Process.monitor(pid)

    %{
      state
      | agents: Map.put(state.agents, name, pid),
        monitors: Map.put(state.monitors, ref, name)
    }
  end

  # Adds a 1-second coordination buffer to the outer GenServer.call timeout so
  # that agent-level timeouts resolve before the caller's call times out. Returns
  # the timeout unchanged for :infinity and 0 (explicit "fail immediately").
  defp coordination_timeout(:infinity), do: :infinity
  defp coordination_timeout(0), do: 0
  defp coordination_timeout(timeout) when is_integer(timeout), do: timeout + 1_000

  defp run_handoff(names, initial_message, agents, timeout) do
    initial = %{message: initial_message, result: nil}

    names
    |> Enum.reduce_while({:ok, initial}, fn name, {:ok, acc} ->
      case Map.get(agents, name) do
        nil ->
          {:halt, {:error, {:unknown_agent, name}}}

        pid ->
          case Server.chat(pid, acc.message, timeout: timeout) do
            {:ok, result} ->
              next_message = result.text || "(no response)"
              {:cont, {:ok, %{message: next_message, result: result}}}

            {:error, result} ->
              {:halt, {:error, result}}
          end
      end
    end)
    |> case do
      {:ok, %{result: final}} -> {:ok, final}
      {:error, _} = error -> error
    end
  end
end
