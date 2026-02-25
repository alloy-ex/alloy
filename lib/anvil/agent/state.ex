defmodule Anvil.Agent.State do
  @moduledoc """
  Mutable state for an agent run.

  Tracks the conversation history, turn count, token usage, and
  current status. Passed through each iteration of the agent loop.
  """

  alias Anvil.{Message, Usage}
  alias Anvil.Agent.Config

  @type status :: :running | :completed | :error | :max_turns

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          usage: Usage.t(),
          status: status(),
          error: term() | nil,
          tool_defs: [map()],
          tool_fns: %{String.t() => {module(), map()}}
        }

  @enforce_keys [:config]
  defstruct [
    :config,
    :error,
    messages: [],
    turn: 0,
    usage: %Usage{},
    status: :running,
    tool_defs: [],
    tool_fns: %{}
  ]

  @doc """
  Initialize state from config and optional existing messages.
  """
  @spec init(Config.t(), [Message.t()]) :: t()
  def init(%Config{} = config, messages \\ []) do
    {tool_defs, tool_fns} = Anvil.Tool.Registry.build(config.tools)

    %__MODULE__{
      config: config,
      messages: messages,
      tool_defs: tool_defs,
      tool_fns: tool_fns
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
end
