defmodule Alloy.Context.Compactor.Estimator do
  @moduledoc false
  # Token estimation (bytes/4 heuristic plus fixed media budgets) and
  # transcript serialization for summary compaction.

  alias Alloy.Agent.State
  alias Alloy.Message

  # Fixed heuristics for media types, whose payload size says little about
  # their token cost. Intentionally conservative rough estimates.
  @image_tokens 1_000
  @audio_tokens 500
  @video_tokens 2_000
  @document_tokens 3_000

  @spec request_tokens([Message.t()], State.t()) :: non_neg_integer()
  def request_tokens(messages, %State{} = state) do
    overhead = request_overhead_tokens(state)
    msg_tokens = estimate_messages_tokens(messages)
    overhead + msg_tokens
  end

  @spec budget_tokens(State.t()) :: non_neg_integer()
  def budget_tokens(%State{
        config: %{max_tokens: max_tokens, compaction: %{reserve_tokens: reserve}}
      })
      when is_integer(max_tokens) and is_integer(reserve) do
    if max_tokens > reserve, do: max_tokens - reserve, else: 0
  end

  @spec within_reserve?([Message.t()], State.t()) :: boolean()
  def within_reserve?(messages, %State{} = state),
    do: request_tokens(messages, state) <= budget_tokens(state)

  @spec estimate_message_tokens(Message.t()) :: non_neg_integer()
  def estimate_message_tokens(%Message{content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  def estimate_message_tokens(%Message{content: blocks}) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn block, acc -> acc + estimate_block_tokens(block) end)
  end

  @spec thinking_block?(term()) :: boolean()
  def thinking_block?(%{type: type}) when type in ["thinking", "redacted_thinking"], do: true
  def thinking_block?(%{"type" => type}) when type in ["thinking", "redacted_thinking"], do: true
  def thinking_block?(_block), do: false

  @spec serialize_messages([Message.t()]) :: String.t()
  def serialize_messages(messages) do
    messages
    |> Enum.map(&serialize_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # ── Token Estimation ──────────────────────────────────────────────────────

  defp estimate_tokens(text) when is_binary(text), do: div(byte_size(text), 4)

  defp estimate_messages_tokens(messages), do: estimate_messages_tokens(messages, 0)
  defp estimate_messages_tokens([], acc), do: acc

  defp estimate_messages_tokens([msg | rest], acc),
    do: estimate_messages_tokens(rest, acc + estimate_message_tokens(msg))

  defp estimate_block_tokens(%{type: "text", text: text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_block_tokens(%{type: type, name: name, input: input})
       when type in ["tool_use", "server_tool_use"] do
    name_str = if is_binary(name), do: name, else: inspect(name)
    estimate_tokens(name_str) + estimate_json_tokens(input)
  end

  defp estimate_block_tokens(%{type: type, content: content})
       when type in ["tool_result", "server_tool_result"] and is_binary(content) do
    estimate_tokens(content)
  end

  # Multimodal tool_result lists (atom- or string-keyed) reuse fixed media
  # budgets instead of dividing base64 byte length by 4.
  defp estimate_block_tokens(%{type: type, content: parts})
       when type in ["tool_result", "server_tool_result"] and is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc -> acc + estimate_block_tokens(part) end)
  end

  defp estimate_block_tokens(%{"type" => type, "content" => parts})
       when type in ["tool_result", "server_tool_result"] and is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc -> acc + estimate_block_tokens(part) end)
  end

  # With display "omitted" the thinking text is empty and the signature
  # carries the full encrypted reasoning the provider replays as input.
  defp estimate_block_tokens(%{type: "thinking", thinking: text} = block) when is_binary(text) do
    sig =
      case Map.get(block, :signature) do
        s when is_binary(s) -> s
        _ -> ""
      end

    estimate_tokens(text) + estimate_tokens(sig)
  end

  # Media and text blocks (both atom-keyed Alloy blocks and string-keyed
  # provider wire-format parts such as Anthropic image/document or OpenAI
  # input_image/image_url) use fixed media budgets regardless of key style.
  defp estimate_block_tokens(%{"type" => "text", "text" => text}) when is_binary(text),
    do: estimate_tokens(text)

  defp estimate_block_tokens(%{type: type})
       when type in ["image", "input_image", "image_url"],
       do: @image_tokens

  defp estimate_block_tokens(%{"type" => type})
       when type in ["image", "input_image", "image_url"],
       do: @image_tokens

  defp estimate_block_tokens(%{type: type}) when type in ["audio", "input_audio"],
    do: @audio_tokens

  defp estimate_block_tokens(%{"type" => type}) when type in ["audio", "input_audio"],
    do: @audio_tokens

  defp estimate_block_tokens(%{type: "video"}), do: @video_tokens
  defp estimate_block_tokens(%{"type" => "video"}), do: @video_tokens

  defp estimate_block_tokens(%{type: type}) when type in ["document", "file", "input_file"],
    do: @document_tokens

  defp estimate_block_tokens(%{"type" => type}) when type in ["document", "file", "input_file"],
    do: @document_tokens

  defp estimate_block_tokens(%{"inlineData" => _}), do: @image_tokens
  defp estimate_block_tokens(%{"inline_data" => _}), do: @image_tokens

  # String-keyed blocks, list content and block types this module does not
  # know are still sent to the provider, so they cost roughly their JSON size.
  defp estimate_block_tokens(block), do: estimate_json_tokens(block)

  defp estimate_json_tokens(term) do
    case Jason.encode(term) do
      {:ok, json} -> estimate_tokens(json)
      {:error, _reason} -> term |> inspect() |> estimate_tokens()
    end
  end

  # The system prompt and tool definitions are sent with every request and
  # count against the same context window as the messages.
  defp request_overhead_tokens(%State{config: config, tool_defs: tool_defs}) do
    system_prompt_tokens(config.system_prompt) + estimate_json_tokens(tool_defs)
  end

  defp system_prompt_tokens(nil), do: 0
  defp system_prompt_tokens(prompt) when is_binary(prompt), do: estimate_tokens(prompt)

  # ── Transcript Serialization ──────────────────────────────────────────────

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    "[#{role_label(role)}]\n#{content}"
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.reject(&thinking_block?/1)
    |> Enum.map(&serialize_block(role, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp serialize_block(role, %{type: "text", text: text}) when is_binary(text) do
    "[#{role_label(role)}]\n#{text}"
  end

  defp serialize_block(:assistant, %{type: type, name: name, input: input})
       when type in ["tool_use", "server_tool_use"] do
    "[Assistant tool call] #{name}(#{encode_block_data(input)})"
  end

  defp serialize_block(_role, %{type: type, content: content})
       when type in ["tool_result", "server_tool_result"] do
    "[Tool result]\n#{block_content_to_string(content)}"
  end

  defp serialize_block(role, block) when is_map(block) do
    type = Map.get(block, :type) || Map.get(block, "type") || "unknown"
    "[#{role_label(role)} block #{type}]\n#{inspect(block)}"
  end

  defp serialize_block(role, block) do
    "[#{role_label(role)} block unknown]\n#{inspect(block)}"
  end

  defp encode_block_data(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end

  defp block_content_to_string(content) when is_binary(content), do: content
  defp block_content_to_string(content), do: inspect(content)

  defp role_label(:user), do: "User"
  defp role_label(:assistant), do: "Assistant"
end
