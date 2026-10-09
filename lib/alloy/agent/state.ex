defmodule Alloy.Agent.State do
  @moduledoc """
  Mutable state for an agent run.

  Tracks the conversation history, turn count, token usage, and
  current status. Passed through each iteration of the agent loop.

  `deadline` is the monotonic time in milliseconds (see
  `System.monotonic_time/1`) by which the run's provider requests must
  finish; `Alloy.Agent.Turn.run_loop/2` sets it. Middleware that makes its
  own provider request, as compaction does, should finish by it.
  """

  alias Alloy.Agent.Config
  alias Alloy.{Message, Usage}

  @type status :: :idle | :running | :completed | :error | :max_turns | :halted

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          usage: Usage.t(),
          status: status(),
          error: term() | nil,
          stop_reason: Alloy.Provider.stop_reason() | nil,
          tool_calls: [map()],
          tool_defs: [map()],
          tool_fns: %{String.t() => Alloy.Tool.Registry.tool()},
          provider_state: map(),
          provider_response_metadata: map(),
          run_metadata: map(),
          started_at: integer() | nil,
          deadline: integer() | nil,
          agent_id: String.t()
        }

  @enforce_keys [:config]
  defstruct [
    :config,
    :error,
    :stop_reason,
    messages: [],
    turn: 0,
    usage: %Usage{},
    tool_calls: [],
    status: :idle,
    tool_defs: [],
    tool_fns: %{},
    provider_state: %{},
    provider_response_metadata: %{},
    run_metadata: %{},
    started_at: nil,
    deadline: nil,
    agent_id: ""
  ]

  @doc """
  Initialize state from config and optional existing messages.
  """
  @spec init(Config.t(), [Message.t()]) :: t()
  def init(%Config{} = config, messages \\ []) do
    {tool_defs, tool_fns} = Alloy.Tool.Registry.build(config.tools)

    agent_id =
      Map.get(config.context, :session_id) || generate_agent_id()

    %__MODULE__{
      config: config,
      messages: messages,
      tool_defs: tool_defs,
      tool_fns: tool_fns,
      provider_state: Map.get(config.provider_config, :provider_state, %{}),
      started_at: System.monotonic_time(:millisecond),
      agent_id: agent_id
    }
  end

  @doc """
  Append messages to the conversation history.

  `state.messages` always holds the full history in chronological order,
  so middleware can read it directly.
  """
  @spec append_messages(t(), [Message.t()] | Message.t()) :: t()
  def append_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    %{state | messages: state.messages ++ messages}
  end

  def append_messages(%__MODULE__{} = state, %Message{} = message),
    do: append_messages(state, [message])

  @doc """
  Append tool execution metadata for the current run.
  """
  @spec append_tool_calls(t(), [map()]) :: t()
  def append_tool_calls(%__MODULE__{} = state, tool_calls) when is_list(tool_calls) do
    %{state | tool_calls: state.tool_calls ++ tool_calls}
  end

  @doc """
  Merge provider-owned state returned by the model backend.
  """
  @spec merge_provider_state(t(), map() | nil) :: t()
  def merge_provider_state(%__MODULE__{} = state, nil), do: state

  def merge_provider_state(%__MODULE__{} = state, provider_state) when is_map(provider_state) do
    %{state | provider_state: Map.merge(state.provider_state, provider_state)}
  end

  @doc """
  Replace the latest provider response metadata for this run.
  """
  @spec put_provider_response_metadata(t(), map() | nil) :: t()
  def put_provider_response_metadata(%__MODULE__{} = state, nil), do: state

  def put_provider_response_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | provider_response_metadata: metadata}
  end

  @doc """
  Merge agent-loop runtime metadata for the current run.
  """
  @spec merge_run_metadata(t(), map() | nil) :: t()
  def merge_run_metadata(%__MODULE__{} = state, nil), do: state

  def merge_run_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | run_metadata: Map.merge(state.run_metadata, metadata)}
  end

  @doc """
  Return the conversation history in chronological order, the same as
  `state.messages`.
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Increment the turn counter.
  """
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn: state.turn + 1}
  end

  @doc """
  Merge usage from a provider response.
  """
  @spec merge_usage(t(), map()) :: t()
  def merge_usage(%__MODULE__{} = state, response_usage) do
    %{state | usage: Usage.merge(state.usage, response_usage)}
  end

  @doc """
  Extract the text from the last assistant message.

  Returns `""` when that message has no text blocks and `nil` when there is
  no assistant message.
  """
  @spec last_assistant_text(t()) :: String.t() | nil
  def last_assistant_text(%__MODULE__{} = state),
    do: find_last_assistant(state, &Message.text/1)

  @doc """
  Extract the thinking/reasoning text from the most recent assistant message
  that carries any. Returns `nil` when no assistant message has thinking.
  """
  @spec last_assistant_thinking(t()) :: String.t() | nil
  def last_assistant_thinking(%__MODULE__{} = state),
    do: find_last_assistant(state, &Message.thinking/1)

  # Newest first, the first assistant message for which `extract` returns a
  # value. Message.text/1 returns "" rather than nil, so text stops at the
  # last assistant message while thinking keeps looking further back.
  defp find_last_assistant(%__MODULE__{} = state, extract) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = message -> extract.(message)
      _message -> nil
    end)
  end

  defp generate_agent_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
