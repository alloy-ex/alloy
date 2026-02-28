defmodule Alloy.Agent.State do
  @moduledoc """
  Mutable state for an agent run.

  Tracks the conversation history, turn count, token usage, and
  current status. Passed through each iteration of the agent loop.
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
    messages_new: [],
    turn: 0,
    usage: %Usage{},
    status: :idle,
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

  Uses an internal accumulator for O(1) append. Call `messages/1` to
  retrieve the full list in chronological order.
  """
  @spec append_messages(t(), [Message.t()] | Message.t()) :: t()
  def append_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    # Prepend new messages (reversed) onto the accumulator for O(1) per message.
    new_acc = Enum.reduce(messages, state.messages_new, fn msg, acc -> [msg | acc] end)
    %{state | messages_new: new_acc}
  end

  def append_messages(%__MODULE__{} = state, %Message{} = message) do
    %{state | messages_new: [message | state.messages_new]}
  end

  @doc """
  Return messages in chronological order.

  Flushes the internal accumulator and returns the full message list.
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: base, messages_new: []}) do
    base
  end

  def messages(%__MODULE__{messages: base, messages_new: new}) do
    base ++ Enum.reverse(new)
  end

  @doc """
  Flush the accumulator into the messages field.

  After this call, `state.messages` contains the full chronological
  list and `state.messages_new` is empty. Call at process boundaries
  where code reads `state.messages` directly.
  """
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{messages_new: []} = state), do: state

  def materialize(%__MODULE__{} = state) do
    %{state | messages: messages(state), messages_new: []}
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
  def last_assistant_text(%__MODULE__{} = state) do
    # Check the accumulator (newest messages) first, then fall back to base.
    find_assistant_text(state.messages_new) ||
      find_assistant_text_reversed(state.messages)
  end

  @doc """
  Clean up resources owned by this state.

  Stops the scratchpad Agent process if one was started. Safe to call
  multiple times or when scratchpad is nil.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{scratchpad: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  def cleanup(%__MODULE__{}), do: :ok

  # Search newest-first in the accumulator (already reversed / newest-first).
  defp find_assistant_text(messages_new) do
    Enum.find_value(messages_new, fn
      %Message{role: :assistant} = msg -> Message.text(msg)
      _ -> nil
    end)
  end

  # Search newest-first in the base messages (chronological, so reverse).
  defp find_assistant_text_reversed(messages) do
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
