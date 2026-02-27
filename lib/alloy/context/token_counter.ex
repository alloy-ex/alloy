defmodule Alloy.Context.TokenCounter do
  @moduledoc """
  Estimates token counts using a chars/4 heuristic.

  Good enough for budget decisions (when to compact, whether we're
  approaching limits). Not meant for billing accuracy.
  """

  alias Alloy.Message

  @model_limits %{
    # Anthropic (200k context)
    "claude-opus-4-6" => 200_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-6-20250514" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000,
    # OpenAI
    "gpt-5.2" => 1_047_576,
    "gpt-5.1" => 1_047_576,
    "o3-pro" => 200_000,
    # Google Gemini
    "gemini-2.5-flash" => 1_000_000,
    "gemini-2.5-pro" => 1_000_000,
    "gemini-3-flash-preview" => 1_000_000
  }

  @default_limit 200_000

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
    input_tokens = estimate_tokens(Jason.encode!(input))
    name_tokens + input_tokens
  end

  defp estimate_block_tokens(%{type: "tool_result", content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_block_tokens(%{type: "image"}), do: @image_tokens
  defp estimate_block_tokens(%{type: "audio"}), do: @audio_tokens
  defp estimate_block_tokens(%{type: "video"}), do: @video_tokens
  defp estimate_block_tokens(%{type: "document"}), do: @document_tokens

  defp estimate_block_tokens(_block), do: 0

  @doc """
  Returns the context window limit for a given model name.
  Falls back to #{@default_limit} for unknown models.
  """
  @spec model_limit(String.t()) :: pos_integer()
  def model_limit(model_name) do
    Map.get(@model_limits, model_name, @default_limit)
  end

  @doc """
  Returns true if the estimated token count of messages is within
  90% of the max_tokens budget.
  """
  @spec within_budget?([Message.t()], pos_integer()) :: boolean()
  def within_budget?(messages, max_tokens) do
    estimate_tokens(messages) < max_tokens * 0.9
  end
end
