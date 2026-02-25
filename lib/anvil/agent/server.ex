defmodule Anvil.Agent.Server do
  @moduledoc """
  OTP-backed persistent agent process.

  Wraps the stateless `Turn.run_loop/1` in a GenServer so the agent
  can hold conversation history across multiple calls, be supervised,
  and run concurrently with other agents.

  ## Usage

      {:ok, pid} = Anvil.Agent.Server.start_link(
        provider: {Anvil.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-opus-4-6"},
        tools: [Anvil.Tool.Core.Read, Anvil.Tool.Core.Bash],
        system_prompt: "You are a helpful assistant."
      )

      {:ok, r1} = Anvil.Agent.Server.chat(pid, "List the files in this project")
      {:ok, r2} = Anvil.Agent.Server.chat(pid, "Now read mix.exs")
      IO.puts(r2.text)

      Anvil.Agent.Server.stop(pid)

  ## Options

  All options from `Anvil.run/2` are accepted at start time, plus:

  - `:name` - Register the process under a name (optional)

  ## Supervision

      children = [
        {Anvil.Agent.Server, [
          name: :my_agent,
          provider: {Anvil.Provider.Anthropic, api_key: System.get_env("ANTHROPIC_API_KEY"), model: "claude-opus-4-6"}
        ]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer

  alias Anvil.Agent.{Config, State, Turn}
  alias Anvil.{Message, Middleware, Usage}

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
  """
  @spec chat(GenServer.server(), String.t()) :: {:ok, result()} | {:error, result()}
  def chat(server, message) when is_binary(message) do
    GenServer.call(server, {:chat, message}, :infinity)
  end

  @doc """
  Return the full conversation message history.
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
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Switch the provider (and its config) mid-session.

  Accepts `provider_opts` in the same format as the `:provider` option in
  `start_link/1`.  Conversation history, tools, system prompt, and all
  other config fields are preserved.

  ## Examples

      Server.set_model(pid, provider: {Anvil.Provider.Anthropic, api_key: key, model: "claude-haiku-4-5-20251001"})
      Server.set_model(pid, provider: Anvil.Provider.OpenAI)
  """
  @spec set_model(GenServer.server(), keyword()) :: :ok
  def set_model(server, provider_opts) when is_list(provider_opts) do
    GenServer.call(server, {:set_model, provider_opts})
  end

  @doc """
  Send a message with streaming. Calls `on_chunk` for each text delta.
  Returns the same result shape as `chat/2`.
  """
  @spec stream_chat(GenServer.server(), String.t(), (String.t() -> :ok)) ::
          {:ok, result()} | {:error, result()}
  def stream_chat(server, message, on_chunk) when is_binary(message) and is_function(on_chunk, 1) do
    GenServer.call(server, {:stream_chat, message, on_chunk}, :infinity)
  end

  @doc """
  Stop the agent process.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    config = Config.from_opts(opts)
    state = State.init(config, Keyword.get(opts, :messages, []))
    state = Middleware.run(:session_start, state)
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Middleware.run(:session_end, state)
    :ok
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
      :error -> {:reply, {:error, result}, new_state}
      _ -> {:reply, {:ok, result}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:stream_chat, message, on_chunk}, _from, state) do
    # Temporarily enable streaming and inject on_chunk into context
    original_config = state.config

    streaming_config = %{
      original_config
      | streaming: true,
        context: Map.put(original_config.context, :on_chunk, on_chunk)
    }

    state =
      %{state | config: streaming_config}
      |> State.append_messages([Message.user(message)])
      |> reset_for_new_run()

    final_state = Turn.run_loop(state)

    result = build_result(final_state)

    # Restore original config so streaming doesn't persist
    new_state =
      %{final_state | config: original_config}
      |> reset_for_new_run()

    case final_state.status do
      :error -> {:reply, {:error, result}, new_state}
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

  @impl GenServer
  def handle_call(:reset, _from, state) do
    new_state = %{state | messages: [], turn: 0, status: :running, error: nil}
    {:reply, :ok, new_state}
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

  # ── Private ───────────────────────────────────────────────────────────────

  defp reset_for_new_run(state) do
    %{state | turn: 0, status: :running, error: nil}
  end

  defp build_result(%State{} = state) do
    %{
      text: extract_text(state),
      messages: state.messages,
      usage: state.usage,
      status: state.status,
      turns: state.turn,
      error: state.error
    }
  end

  defp extract_text(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = msg -> Message.text(msg)
      _ -> nil
    end)
  end
end
