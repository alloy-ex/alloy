defmodule Alloy.Context.Compactor do
  @moduledoc """
  Manus-style context compaction.

  When approaching the token limit, compacts old tool results into
  summaries and truncates old assistant text, preserving the first
  message (original request) and the most recent messages.
  """

  require Logger

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
    messages = State.messages(state)

    if TokenCounter.within_budget?(messages, state.config.max_tokens) do
      state
    else
      # Use dynamic keep_recent: at most default, but ensure at least 1 message gets compacted
      msg_count = length(messages)
      keep_recent = min(@default_keep_recent, max(1, msg_count - 2))

      {first, middle, recent} = split_messages(messages, keep_recent)

      # Fire on_compaction callback BEFORE compacting, so the caller can
      # extract facts from messages that are about to be compressed.
      # Crash protection: callback failure must never prevent compaction.
      fire_on_compaction(middle, state)

      compacted_middle = Enum.map(middle, &compact_message/1)
      compacted = [first | compacted_middle] ++ recent

      # Store compacted messages and clear the accumulator
      %{state | messages: compacted, messages_new: []}
    end
  end

  # Splits messages into {first, middle, recent} for compaction.
  # The middle slice is what gets compacted; first and recent are preserved.
  defp split_messages(messages, keep_recent) do
    [first | rest] = messages
    rest_len = length(rest)
    recent_count = min(keep_recent, rest_len)
    {middle, recent} = Enum.split(rest, rest_len - recent_count)
    {first, middle, recent}
  end

  # Fires the on_compaction callback with the middle messages (those about to be
  # compacted). Any crash in the callback is swallowed — compaction must always proceed.
  defp fire_on_compaction(_middle, %State{config: %{on_compaction: nil}}), do: :ok

  defp fire_on_compaction(
         middle,
         %State{config: %{on_compaction: callback}} = state
       )
       when is_function(callback, 2) do
    callback.(middle, state)
  rescue
    e ->
      Logger.warning("on_compaction callback crashed: #{Exception.message(e)}")
      :ok
  catch
    kind, payload ->
      Logger.warning("on_compaction callback error (#{kind}): #{inspect(payload)}")
      :ok
  end

  defp fire_on_compaction(_, _), do: :ok

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
      {first, middle, recent} = split_messages(messages, keep_recent)
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
