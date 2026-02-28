defmodule Alloy.Agent.State do
  @moduledoc """
  Mutable state for an agent run.

  Tracks the conversation history, turn count, token usage, and
  current status. Passed through each iteration of the agent loop.
  """

  alias Alloy.Agent.Config
  alias Alloy.{Message, Usage}

  @type status :: :running | :completed | :error | :max_turns | :halted

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          usage: Usage.t(),
          status: status(),
          error: term() | nil,
          tool_defs: [map()],
          tool_fns: %{String.t() => {module(), map()}},
          scratchpad: pid() | nil,
          started_at: integer() | nil,
          agent_id: String.t(),
          current_task: {reference(), pid(), binary()} | nil
        }

  @enforce_keys [:config]
  defstruct [
    :config,
    :error,
    :scratchpad,
    messages: [],
    turn: 0,
    usage: %Usage{},
    status: :running,
    tool_defs: [],
    tool_fns: %{},
    started_at: nil,
    agent_id: "",
    current_task: nil
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
      scratchpad: maybe_start_scratchpad(config.tools),
      started_at: System.monotonic_time(:millisecond),
      agent_id: agent_id
    }
  end

  @doc """
  Append messages to the conversation history.
  """
  @spec append_messages(t(), [Message.t()] | Message.t()) :: t()
  def append_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    %{state | messages: state.messages ++ messages}
  end

  def append_messages(%__MODULE__{} = state, %Message{} = message) do
    append_messages(state, [message])
  end

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
  """
  @spec last_assistant_text(t()) :: String.t() | nil
  def last_assistant_text(%__MODULE__{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = msg -> Message.text(msg)
      _ -> nil
    end)
  end

  defp maybe_start_scratchpad(tools) do
    if Alloy.Tool.Core.Scratchpad in tools do
      {:ok, pid} = Agent.start_link(fn -> %{} end)
      pid
    end
  end

  defp generate_agent_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
