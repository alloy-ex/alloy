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

  @model_limits %{
    "o3-pro" => 200_000,
    "gemini-flash-latest" => 1_048_576
  }

  @anthropic_model_limits [
    {~r/^claude-opus-4-6(?:-\d{8})?$/, 200_000},
    {~r/^claude-sonnet-4-6(?:-\d{8})?$/, 200_000},
    {~r/^claude-haiku-4-5(?:-\d{8})?$/, 200_000}
  ]

  @openai_model_limits [
    {~r/^gpt-5(?:-\d{4}-\d{2}-\d{2})?$/, 400_000},
    {~r/^gpt-5\.1(?:-\d{4}-\d{2}-\d{2})?$/, 400_000},
    {~r/^gpt-5\.2(?:-\d{4}-\d{2}-\d{2})?$/, 400_000},
    {~r/^gpt-5\.4(?:-\d{4}-\d{2}-\d{2})?$/, 1_050_000}
  ]

  @gemini_model_limits [
    {~r/^gemini-2\.5-(?:flash|pro|flash-lite)(?:-preview(?:-\d{2}-\d{4})?)?$/, 1_048_576},
    {~r/^gemini-3-(?:flash|pro)-preview(?:-\d{2}-\d{4})?$/, 1_048_576}
  ]

  @xai_model_limits [
    {~r/^grok-4$/, 256_000},
    {~r/^grok-4-fast-(?:reasoning|non-reasoning)$/, 2_000_000},
    {~r/^grok-4-1-fast-reasoning$/, 2_000_000},
    {~r/^grok-4-1-fast-non-reasoning$/, 2_000_000},
    {~r/^grok-code-fast-1$/, 256_000},
    {~r/^grok-3(?:-fast)?$/, 131_072},
    {~r/^grok-3-mini(?:-fast)?$/, 131_072}
  ]

  @default_limit 200_000
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
  Falls back to #{@default_limit} for unknown models.
  """
  @spec model_limit(String.t()) :: pos_integer()
  def model_limit(model_name) do
    Map.get(@model_limits, model_name) ||
      pattern_model_limit(@anthropic_model_limits, model_name) ||
      pattern_model_limit(@openai_model_limits, model_name) ||
      pattern_model_limit(@gemini_model_limits, model_name) ||
      pattern_model_limit(@xai_model_limits, model_name) ||
      @default_limit
  end

  defp pattern_model_limit(limits, model_name) do
    Enum.find_value(limits, fn {pattern, limit} ->
      if Regex.match?(pattern, model_name), do: limit
    end)
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
