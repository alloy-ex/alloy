defmodule Anvil.Context.TokenCounter do
  @moduledoc """
  Estimates token counts using a chars/4 heuristic.

  Good enough for budget decisions (when to compact, whether we're
  approaching limits). Not meant for billing accuracy.
  """

  alias Anvil.Message

  @model_limits %{
    "claude-sonnet-4-5" => 200_000,
    "claude-opus-4-5" => 200_000,
    "claude-haiku-4-5" => 200_000,
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    "gemini-2.0-flash" => 1_000_000,
    "gemini-2.5-pro" => 1_000_000
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
