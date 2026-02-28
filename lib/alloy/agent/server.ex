defmodule Alloy.Agent.Server do
  @moduledoc """
  OTP-backed persistent agent process.

  Wraps the stateless `Turn.run_loop/1` in a GenServer so the agent
  can hold conversation history across multiple calls, be supervised,
  and run concurrently with other agents.

  ## Usage

      {:ok, pid} = Alloy.Agent.Server.start_link(
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-opus-4-6"},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
        system_prompt: "You are a helpful assistant."
      )

      {:ok, r1} = Alloy.Agent.Server.chat(pid, "List the files in this project")
      {:ok, r2} = Alloy.Agent.Server.chat(pid, "Now read mix.exs")
      IO.puts(r2.text)

      Alloy.Agent.Server.stop(pid)

  ## Options

  All options from `Alloy.run/2` are accepted at start time, plus:

  - `:name` - Register the process under a name (optional)

  ## Supervision

      children = [
        {Alloy.Agent.Server, [
          name: :my_agent,
          provider: {Alloy.Provider.Anthropic, api_key: System.get_env("ANTHROPIC_API_KEY"), model: "claude-opus-4-6"}
        ]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer
  require Logger

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.{Message, Middleware, Session, Usage}

  @type result :: %{
          text: String.t() | nil,
          messages: [Message.t()],
          usage: Usage.t(),
          status: State.status(),
          turns: non_neg_integer(),
          error: term() | nil
        }

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Start a supervised, persistent agent process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, agent_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, agent_opts, name_opts)
  end

  @doc """
  Send a message and wait for the agent to finish its full loop.

  Blocks until the model reaches `end_turn` (including all tool calls).
  Conversation history is preserved for subsequent calls.

  ## Options

    - `:timeout` - GenServer call timeout in milliseconds. Defaults to
      `:infinity` because the Turn's deadline mechanism (driven by
      `config.timeout_ms`) enforces the actual timeout internally,
      guaranteeing a reply. Override only if you need a hard caller-side
      safety net (e.g., `timeout: config.timeout_ms + 10_000`).
  """
  @spec chat(GenServer.server(), String.t(), keyword()) :: {:ok, result()} | {:error, result()}
  def chat(server, message, opts \\ []) when is_binary(message) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(server, {:chat, message}, timeout)
  end

  @doc """
  Return the full conversation message history.

  Note: if an async Turn is in progress via `send_message/3`, this returns a
  snapshot of the conversation *before* that Turn started. The in-flight
  assistant response will appear only after the Turn completes.
  """
  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(server) do
    GenServer.call(server, :messages)
  end

  @doc """
  Return accumulated token usage across all turns.
  """
  @spec usage(GenServer.server()) :: Usage.t()
  def usage(server) do
    GenServer.call(server, :usage)
  end

  @doc """
  Clear conversation history. Config and tools are preserved.

  Returns `{:error, :busy}` if an async Turn is currently running via `send_message/3`.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, :busy}
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Switch the provider (and its config) mid-session.

  Accepts `provider_opts` in the same format as the `:provider` option in
  `start_link/1`.  Conversation history, tools, system prompt, and all
  other config fields are preserved.

  ## Examples

      Server.set_model(pid, provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-haiku-4-5-20251001"})
      Server.set_model(pid, provider: Alloy.Provider.OpenAI)

  Returns `{:error, :busy}` if an async Turn is currently running via `send_message/3`.
  """
  @spec set_model(GenServer.server(), keyword()) :: :ok | {:error, :busy}
  def set_model(server, provider_opts) when is_list(provider_opts) do
    GenServer.call(server, {:set_model, provider_opts})
  end

  @doc """
  Send a message with streaming. Calls `on_chunk` for each text delta.
  Returns the same result shape as `chat/3`.

  ## Options

    - `:timeout` - GenServer call timeout in milliseconds. Defaults to
      `:infinity` because the Turn's deadline mechanism enforces the
      actual timeout internally. See `chat/3` for details.
  """
  @spec stream_chat(GenServer.server(), String.t(), (String.t() -> :ok), keyword()) ::
          {:ok, result()} | {:error, result()}
  def stream_chat(server, message, on_chunk, opts \\ [])
      when is_binary(message) and is_function(on_chunk, 1) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(server, {:stream_chat, message, on_chunk}, timeout)
  end

  @doc """
  Send a message to the agent without blocking the caller.

  Returns `{:ok, request_id}` immediately. The agent runs its full Turn loop
  in a supervised Task, then broadcasts the result via PubSub to
  `"agent:<id>:responses"` as `{:agent_response, result}` where `result`
  includes a `:request_id` field matching the returned ID.

  Returns `{:error, :busy}` if a Turn is already in progress. The caller
  is responsible for retry or backpressure logic.

  Returns `{:error, :no_pubsub}` if the agent was started without a `:pubsub`
  option — without PubSub there is no way to receive results.

  ## Requirements

  PubSub must be configured on the agent. Add `pubsub: MyApp.PubSub` to the
  agent start options.

  ## Options

    - `:request_id` - supply your own correlation ID (binary). Defaults to
      a random URL-safe ID.

  ## Example

      {:ok, agent} = Alloy.Agent.Server.start_link(
        provider: {...},
        pubsub: MyApp.PubSub
      )

      Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:\#{session_id}:responses")

      {:ok, req_id} = Alloy.Agent.Server.send_message(agent, "Summarise the logs")

      receive do
        {:agent_response, %{request_id: ^req_id, text: text}} -> IO.puts(text)
      end
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :busy | :no_pubsub}
  def send_message(server, message, opts \\ []) when is_binary(message) do
    request_id = Keyword.get(opts, :request_id, generate_request_id())
    # Use :infinity — the handler spawns a Task and replies immediately (no I/O),
    # but the GenServer may be blocked by a long synchronous chat/3 call ahead
    # of this request in the mailbox. A hard timeout here would crash the caller
    # while the GenServer still processes the message later, spawning a ghost Turn.
    GenServer.call(server, {:send_message, message, request_id}, :infinity)
  end

  @doc """
  Stop the agent process.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Export the current conversation as a serializable Session struct.

  Note: if an async Turn is in progress via `send_message/3`, the exported
  session reflects the state *before* that Turn started (a pre-Turn snapshot).
  """
  @spec export_session(GenServer.server()) :: Session.t()
  def export_session(server) do
    GenServer.call(server, :export_session)
  end

  @doc """
  Returns a health summary map for the agent process.
  """
  @spec health(GenServer.server()) :: map()
  def health(server) do
    GenServer.call(server, :health, 5_000)
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.from_opts(opts)
    state = State.init(config, Keyword.get(opts, :messages, []))

    case Middleware.run(:session_start, state) do
      {:halted, reason} ->
        {:stop, {:middleware_halted, reason}}

      %State{} = state ->
        # Subscribe to PubSub topics if configured.
        # Use state.config (post-middleware) so session_start middleware can update
        # pubsub/subscribe fields and have them reflected in actual subscriptions.
        maybe_subscribe_pubsub(state)
        {:ok, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Kill any running async Turn task — prevents orphaned tasks after shutdown.
    if state.current_task do
      {_ref, task_pid, _request_id} = state.current_task
      # terminate_child/2 may return {:error, :not_found} if the Task already
      # finished between the GenServer receiving :stop and terminate/2 running.
      # This is safe to ignore — the Task is gone either way.
      Task.Supervisor.terminate_child(Alloy.TaskSupervisor, task_pid)
    end

    state =
      case Middleware.run(:session_end, state) do
        {:halted, reason} ->
          Logger.warning(
            "Alloy: :session_end middleware halted during shutdown (#{inspect(reason)})"
          )

          state

        %State{} = new_state ->
          new_state
      end

    if state.config.on_shutdown do
      session = build_export_session(state)

      try do
        state.config.on_shutdown.(session)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Reject synchronous chat while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call({:chat, _message}, _from, %{current_task: {_, _, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl GenServer
  def handle_call({:chat, message}, _from, state) do
    # Append user message and run the full loop
    state =
      state
      |> State.append_messages([Message.user(message)])
      |> reset_for_new_run()

    final_state = Turn.run_loop(state)

    result = build_result(final_state)

    # Keep messages but reset loop counters for next chat/2 call
    new_state = reset_for_new_run(final_state)

    case final_state.status do
      status when status in [:error, :halted] -> {:reply, {:error, result}, new_state}
      _ -> {:reply, {:ok, result}, new_state}
    end
  end

  # Reject synchronous stream_chat while an async Turn is in flight.
  @impl GenServer
  def handle_call({:stream_chat, _message, _on_chunk}, _from, %{current_task: {_, _, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl GenServer
  def handle_call({:stream_chat, message, on_chunk}, _from, state) do
    state =
      state
      |> State.append_messages([Message.user(message)])
      |> reset_for_new_run()

    # Pass streaming as opts — no config mutation needed
    final_state = Turn.run_loop(state, streaming: true, on_chunk: on_chunk)

    result = build_result(final_state)
    new_state = reset_for_new_run(final_state)

    case final_state.status do
      status when status in [:error, :halted] -> {:reply, {:error, result}, new_state}
      _ -> {:reply, {:ok, result}, new_state}
    end
  end

  @impl GenServer
  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl GenServer
  def handle_call(:usage, _from, state) do
    {:reply, state.usage, state}
  end

  # Reject reset while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call(:reset, _from, %{current_task: {_, _, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    new_state = %{state | messages: []} |> reset_for_new_run()
    {:reply, :ok, new_state}
  end

  # Reject set_model while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call({:set_model, _}, _from, %{current_task: {_, _, _}} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl GenServer
  def handle_call({:set_model, provider_opts}, _from, state) do
    {provider_mod, provider_config} =
      case provider_opts[:provider] do
        {mod, config} when is_atom(mod) and is_list(config) -> {mod, Map.new(config)}
        mod when is_atom(mod) -> {mod, %{}}
      end

    updated_config = %{state.config | provider: provider_mod, provider_config: provider_config}
    {:reply, :ok, %{state | config: updated_config}}
  end

  @impl GenServer
  def handle_call(:export_session, _from, state) do
    {:reply, build_export_session(state), state}
  end

  @impl GenServer
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: state.status,
       turns: state.turn,
       message_count: length(state.messages),
       usage: state.usage,
       uptime_ms: System.monotonic_time(:millisecond) - (state.started_at || 0),
       busy: state.current_task != nil
     }, state}
  end

  # Reject if PubSub is not configured — caller would wait forever for a broadcast.
  @impl GenServer
  def handle_call({:send_message, _, _}, _from, %{config: %{pubsub: nil}} = state) do
    {:reply, {:error, :no_pubsub}, state}
  end

  # Reject if a Turn is already running in a Task.
  @impl GenServer
  def handle_call(
        {:send_message, _message, _request_id},
        _from,
        %{current_task: {_, _, _}} = state
      ) do
    {:reply, {:error, :busy}, state}
  end

  # Accept the message, snapshot state for the Task, spawn, return immediately.
  @impl GenServer
  def handle_call({:send_message, message, request_id}, _from, state) do
    turn_state =
      state
      |> State.append_messages([Message.user(message)])
      |> reset_for_new_run()

    task =
      Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
        Turn.run_loop(turn_state)
      end)

    {:reply, {:ok, request_id}, %{turn_state | current_task: {task.ref, task.pid, request_id}}}
  end

  # Drop agent_event while an async Turn is in flight — prevents concurrent Turns.
  @impl GenServer
  def handle_info({:agent_event, _message}, %{current_task: {_, _, _}} = state) do
    Logger.warning("[Alloy] Dropping agent_event — async Turn already in progress")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:agent_event, message}, state) when is_binary(message) do
    state =
      state
      |> State.append_messages([Message.user(message)])
      |> reset_for_new_run()

    final_state = Turn.run_loop(state)

    # Broadcast result if pubsub is configured.
    # Use effective_session_id/1 so the topic matches what export_session/1
    # returns as the session ID — a :session_start middleware that injects
    # context[:session_id] would otherwise cause the broadcast topic to
    # diverge from the exported session ID, dropping messages for subscribers
    # that subscribe using the session ID.
    if state.config.pubsub do
      topic = "agent:#{effective_session_id(final_state)}:responses"
      broadcast(state.config.pubsub, topic, {:agent_response, build_result(final_state)})
    end

    {:noreply, final_state}
  end

  # Task completed successfully — broadcast result and free the agent.
  # Preserve final_state's actual status/turn/error — do NOT reset_for_new_run
  # which would overwrite :completed with :running and zero the turn counter.
  @impl GenServer
  def handle_info({ref, final_state}, %{current_task: {ref, _pid, request_id}} = _state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if final_state.config.pubsub do
      topic = "agent:#{effective_session_id(final_state)}:responses"
      result = final_state |> build_result() |> Map.put(:request_id, request_id)
      broadcast(final_state.config.pubsub, topic, {:agent_response, result})
    end

    {:noreply, %{final_state | current_task: nil}}
  end

  # Task crashed — broadcast the error, free the agent so it can recover.
  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_task: {ref, _, request_id}} = state
      )
      when is_reference(ref) do
    Logger.error("[Alloy] Async Turn crashed (request_id=#{inspect(request_id)}): #{inspect(reason)}")

    if state.config.pubsub do
      topic = "agent:#{effective_session_id(state)}:responses"

      result =
        state
        |> build_result()
        |> Map.merge(%{status: :error, error: reason, request_id: request_id})

      broadcast(state.config.pubsub, topic, {:agent_response, result})
    end

    # NOTE: state here is the pre-Turn snapshot (including the user message that
    # triggered the Turn). If the caller retries via send_message/3, that will
    # append another user message, leaving two consecutive user messages in
    # history. Anthropic enforces strict user/assistant alternation — callers
    # should call reset/1 before retrying to clear the failed message.
    {:noreply, %{state | current_task: nil, status: :error, error: reason}}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, state) do
    # Normal exits from linked helpers (e.g., the process that called start_link)
    # are expected and should not stop the agent.
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp broadcast(pubsub, topic, message) do
    case Phoenix.PubSub.broadcast(pubsub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Alloy] PubSub broadcast failed on #{inspect(topic)}: #{inspect(reason)}")
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp maybe_subscribe_pubsub(%State{config: %{pubsub: nil}}), do: :ok

  defp maybe_subscribe_pubsub(%State{config: config}) do
    unless Code.ensure_loaded?(Phoenix.PubSub) do
      raise ArgumentError,
            "Alloy: pubsub: is configured but :phoenix_pubsub is not available. " <>
              "Add {:phoenix_pubsub, \"~> 2.1\"} to your mix.exs dependencies."
    end

    for topic <- config.subscribe do
      case Phoenix.PubSub.subscribe(config.pubsub, topic) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Alloy: failed to subscribe to PubSub topic #{inspect(topic)}: #{inspect(reason)}"
          )
      end
    end
  end

  defp reset_for_new_run(state) do
    %{state | turn: 0, status: :running, error: nil}
  end

  defp build_result(%State{} = state) do
    %{
      text: State.last_assistant_text(state),
      messages: state.messages,
      usage: state.usage,
      status: state.status,
      turns: state.turn,
      error: state.error
    }
  end

  # Returns the canonical "effective session ID" used consistently for both
  # PubSub broadcast topics and the exported Session.id.
  #
  # Precedence: context[:session_id] (set by middleware) > state.agent_id (stable UUID).
  # Using this helper in both handle_info({:agent_event, ...}) and
  # build_export_session/1 guarantees that subscribers using the exported
  # session ID always receive events on the correct topic.
  defp effective_session_id(%State{} = state) do
    Map.get(state.config.context, :session_id) || state.agent_id
  end

  defp build_export_session(%State{} = state) do
    Session.new(
      id: effective_session_id(state),
      messages: state.messages,
      usage: state.usage,
      metadata: %{
        status: state.status,
        turns: state.turn,
        provider: state.config.provider
      }
    )
  end
end
