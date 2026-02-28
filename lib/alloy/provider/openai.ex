defmodule Alloy.Provider.OpenAI do
  @moduledoc """
  Provider for OpenAI's Chat Completions API.

  Normalizes OpenAI's wire format (tool_calls array on assistant messages,
  separate role:"tool" messages) to Alloy's content-block format.

  ## Config

  Required:
  - `:api_key` - OpenAI API key
  - `:model` - Model name (e.g., "gpt-5.2", "gpt-5.1", "o3-pro")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.openai.com")
  - `:req_options` - Additional options passed to Req

  ## Example

      Alloy.run("Summarize this code.",
        provider: {Alloy.Provider.OpenAI,
          api_key: System.get_env("OPENAI_API_KEY"),
          model: "gpt-5.2"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.OpenAIStream

  @default_api_url "https://api.openai.com"
  @default_max_tokens 4096

  @impl true
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    req_opts =
      ([
         url: "#{Map.get(config, :api_url, @default_api_url)}/v1/chat/completions",
         method: :post,
         headers: [
           {"authorization", "Bearer #{config.api_key}"},
           {"content-type", "application/json"}
         ],
         body: Jason.encode!(body)
       ] ++ Map.get(config, :req_options, []))
      |> Keyword.put(:retry, false)

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    body = build_request_body(messages, tool_defs, config)
    url = "#{Map.get(config, :api_url, @default_api_url)}/v1/chat/completions"

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"}
    ]

    OpenAIStream.stream(
      url,
      headers,
      body,
      on_chunk,
      Map.get(config, :req_options, [])
    )
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    openai_messages = build_openai_messages(messages, config)

    body = %{
      "model" => config.model,
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => openai_messages
    }

    case tool_defs do
      [] -> body
      defs -> Map.put(body, "tools", Enum.map(defs, &format_tool_def/1))
    end
  end

  defp build_openai_messages(messages, config) do
    system_msgs =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    conv_msgs = Enum.flat_map(messages, &format_message/1)
    system_msgs ++ conv_msgs
  end

  # Simple text user message
  defp format_message(%Message{role: :user, content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  # Simple text assistant message
  defp format_message(%Message{role: :assistant, content: content}) when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

  # Assistant message with content blocks (may contain tool_use)
  defp format_message(%Message{role: :assistant, content: blocks}) when is_list(blocks) do
    tool_calls =
      blocks
      |> Enum.filter(&(&1[:type] == "tool_use"))
      |> Enum.map(fn call ->
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{
            "name" => call.name,
            "arguments" => Jason.encode!(call.input)
          }
        }
      end)

    text_parts =
      blocks
      |> Enum.filter(&(&1[:type] == "text"))
      |> Enum.map_join("\n", & &1.text)

    msg = %{"role" => "assistant"}

    msg =
      case text_parts do
        "" -> Map.put(msg, "content", nil)
        text -> Map.put(msg, "content", text)
      end

    msg =
      case tool_calls do
        [] -> msg
        calls -> Map.put(msg, "tool_calls", calls)
      end

    [msg]
  end

  # User message with blocks. Two distinct cases:
  #   1. Tool results (from the agent loop) -> separate role:"tool" wire messages
  #   2. Media / text blocks (multimodal user turn) -> single user message with
  #      an array content field (OpenAI's vision / audio format)
  defp format_message(%Message{role: :user, content: blocks}) when is_list(blocks) do
    if Enum.any?(blocks, &(&1[:type] == "tool_result")) do
      blocks
      |> Enum.map(fn
        %{type: "tool_result", tool_use_id: tool_call_id, content: content} ->
          %{"role" => "tool", "tool_call_id" => tool_call_id, "content" => content}

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      parts = blocks |> Enum.map(&format_user_content_block/1) |> Enum.reject(&is_nil/1)
      [%{"role" => "user", "content" => parts}]
    end
  end

  defp format_user_content_block(%{type: "text", text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_user_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime_type};base64,#{data}"}}
  end

  defp format_user_content_block(%{type: "audio", mime_type: mime_type, data: data}) do
    %{
      "type" => "input_audio",
      "input_audio" => %{"data" => data, "format" => mime_to_audio_format(mime_type)}
    }
  end

  defp format_user_content_block(%{type: "video", mime_type: mime_type}) do
    %{
      "type" => "text",
      "text" => "[Unsupported media type for OpenAI provider: video/#{mime_type}]"
    }
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type}) do
    %{
      "type" => "text",
      "text" => "[Unsupported media type for OpenAI provider: document/#{mime_type}]"
    }
  end

  defp format_user_content_block(_block), do: nil

  defp mime_to_audio_format("audio/mp3"), do: "mp3"
  defp mime_to_audio_format("audio/mpeg"), do: "mp3"
  defp mime_to_audio_format("audio/wav"), do: "wav"
  defp mime_to_audio_format("audio/ogg"), do: "ogg"
  defp mime_to_audio_format("audio/flac"), do: "flac"
  defp mime_to_audio_format("audio/webm"), do: "webm"
  # Generic fallback: take the subtype (e.g. "audio/x-m4a" -> "x-m4a")
  defp mime_to_audio_format(mime), do: mime |> String.split("/") |> List.last()

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => Alloy.Provider.stringify_keys(schema)
      }
    }
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"choices" => [choice | _]} = resp) do
    message = choice["message"]
    finish_reason = choice["finish_reason"]
    usage = resp["usage"] || %{}

    case parse_message_to_blocks(message) do
      {:ok, content_blocks} ->
        stop_reason = parse_finish_reason(finish_reason)

        alloy_msg = %Message{
          role: :assistant,
          content: content_blocks
        }

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [alloy_msg],
           usage: %{
             input_tokens: Map.get(usage, "prompt_tokens", 0),
             output_tokens: Map.get(usage, "completion_tokens", 0)
           }
         }}

      {:error, _} = err ->
        err
    end
  end

  defp parse_response(%{"error" => error}) do
    {:error, "#{error["type"]}: #{error["message"]}"}
  end

  defp parse_message_to_blocks(message) do
    text_blocks =
      case message["content"] do
        nil -> []
        "" -> []
        text -> [%{type: "text", text: text}]
      end

    tool_blocks =
      (message["tool_calls"] || [])
      |> Enum.reduce_while([], fn tc, acc ->
        case Jason.decode(tc["function"]["arguments"]) do
          {:ok, input} ->
            {:cont,
             acc ++
               [
                 %{
                   type: "tool_use",
                   id: tc["id"],
                   name: tc["function"]["name"],
                   input: input
                 }
               ]}

          {:error, _} ->
            {:halt, {:error, "Invalid JSON in tool call arguments for #{tc["function"]["name"]}"}}
        end
      end)

    case tool_blocks do
      {:error, _} = err -> err
      blocks -> {:ok, text_blocks ++ blocks}
    end
  end

  defp parse_finish_reason("stop"), do: :end_turn
  defp parse_finish_reason("tool_calls"), do: :tool_use
  defp parse_finish_reason("length"), do: :end_turn
  defp parse_finish_reason("content_filter"), do: :end_turn
  defp parse_finish_reason(_), do: :end_turn

  defp parse_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        "#{error["type"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> "#{error["type"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end
end
