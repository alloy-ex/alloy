defmodule Alloy.Context.TokenCounter do
  @moduledoc """
  Estimates token counts using a chars/4 heuristic.

  Good enough for budget decisions (when to compact, whether we're
  approaching limits). Not meant for billing accuracy.

  Accounts for all content block types including text, tool use, tool results,
  and extended thinking/reasoning blocks. Thinking block tokens count toward
  the context budget even though they are not part of the final response text.
  """

  alias Alloy.Message
  alias Alloy.ModelMetadata

  @default_budget_ratio 0.9

  @doc """
  Estimates tokens for a string or a list of messages.
  """
  @spec estimate_tokens(String.t() | [Message.t()]) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text), 4)
  end

  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  @doc """
  Estimates tokens for a single message, handling both string and block content.
  """
  @spec estimate_message_tokens(Message.t()) :: non_neg_integer()
  def estimate_message_tokens(%Message{content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  def estimate_message_tokens(%Message{content: blocks}) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn block, acc ->
      acc + estimate_block_tokens(block)
    end)
  end

  # Fixed heuristics for media types. These are intentionally conservative
  # rough estimates — the compactor uses them as a budget signal, not for billing.
  @image_tokens 1_000
  @audio_tokens 500
  @video_tokens 2_000
  @document_tokens 3_000

  defp estimate_block_tokens(%{type: "text", text: text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_block_tokens(%{type: "tool_use", name: name, input: input}) do
    name_tokens = estimate_tokens(to_string(name))

    input_str =
      case Jason.encode(input) do
        {:ok, json} -> json
        {:error, _} -> inspect(input)
      end

    name_tokens + estimate_tokens(input_str)
  end

  defp estimate_block_tokens(%{type: "tool_result", content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_block_tokens(%{type: "thinking", thinking: text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_block_tokens(%{type: "server_tool_use", name: name, input: input}) do
    name_tokens = estimate_tokens(to_string(name))

    input_str =
      case Jason.encode(input) do
        {:ok, json} -> json
        {:error, _} -> inspect(input)
      end

    name_tokens + estimate_tokens(input_str)
  end

  defp estimate_block_tokens(%{type: "server_tool_result", content: content})
       when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_block_tokens(%{type: "image"}), do: @image_tokens
  defp estimate_block_tokens(%{type: "audio"}), do: @audio_tokens
  defp estimate_block_tokens(%{type: "video"}), do: @video_tokens
  defp estimate_block_tokens(%{type: "document"}), do: @document_tokens

  defp estimate_block_tokens(_block), do: 0

  @doc """
  Returns the context window limit for a given model name.
  Falls back to #{ModelMetadata.default_context_window()} for unknown models.
  """
  @spec model_limit(String.t()) :: pos_integer()
  def model_limit(model_name) do
    ModelMetadata.context_window(model_name) || ModelMetadata.default_context_window()
  end

  @doc """
  Returns true if the estimated token count of messages is within
  the given ratio of the max_tokens budget (default #{@default_budget_ratio}).
  """
  @spec within_budget?([Message.t()], pos_integer(), float()) :: boolean()
  def within_budget?(messages, max_tokens, ratio \\ @default_budget_ratio) do
    estimate_tokens(messages) < max_tokens * ratio
  end
end
