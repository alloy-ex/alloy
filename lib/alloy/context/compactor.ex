defmodule Alloy.Context.Compactor do
  @moduledoc """
  Manus-style context compaction.

  When approaching the token limit, compacts old tool results into
  summaries and truncates old assistant text, preserving the first
  message (original request) and the most recent messages.
  """

  alias Alloy.Agent.State
  alias Alloy.Context.TokenCounter
  alias Alloy.Message

  @default_keep_recent 10
  @truncate_length 200

  @doc """
  Compacts state messages if over the 90% token budget threshold.
  Returns state unchanged if within budget.
  """
  @spec maybe_compact(State.t()) :: State.t()
  def maybe_compact(%State{} = state) do
    if TokenCounter.within_budget?(state.messages, state.config.max_tokens) do
      state
    else
      # Use dynamic keep_recent: at most default, but ensure at least 1 message gets compacted
      msg_count = length(state.messages)
      keep_recent = min(@default_keep_recent, max(1, msg_count - 2))
      %{state | messages: compact_messages(state.messages, keep_recent: keep_recent)}
    end
  end

  @doc """
  Compacts messages, preserving the first message and the most recent N messages.

  ## Options
    * `:keep_recent` - number of recent messages to preserve (default #{@default_keep_recent})
  """
  @spec compact_messages([Message.t()], keyword()) :: [Message.t()]
  def compact_messages(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    count = length(messages)

    if count <= keep_recent + 1 do
      messages
    else
      # Split: first message | middle (to compact) | recent (to keep)
      [first | rest] = messages
      recent_count = min(keep_recent, length(rest))
      {middle, recent} = Enum.split(rest, length(rest) - recent_count)

      compacted_middle = Enum.map(middle, &compact_message/1)

      [first | compacted_middle] ++ recent
    end
  end

  defp compact_message(%Message{content: blocks} = msg) when is_list(blocks) do
    compacted_blocks =
      Enum.map(blocks, fn
        %{type: "tool_result"} = block -> %{block | content: "[compacted]"}
        block -> block
      end)

    %{msg | content: compacted_blocks}
  end

  defp compact_message(%Message{role: :assistant, content: text} = msg) when is_binary(text) do
    if String.length(text) > @truncate_length do
      %{msg | content: String.slice(text, 0, @truncate_length) <> "..."}
    else
      msg
    end
  end

  defp compact_message(msg), do: msg
end
