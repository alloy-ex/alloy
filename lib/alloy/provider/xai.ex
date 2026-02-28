defmodule Alloy.Provider.XAI do
  @moduledoc """
  Provider for xAI's Grok API.

  xAI uses an OpenAI-compatible chat completions format. Supports Grok models
  with real-time knowledge and tool use.

  ## Config

  Required:
  - `:api_key` - xAI API key
  - `:model` - Model name (e.g., "grok-4-1-fast-reasoning", "grok-3",
    "grok-3-mini")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.x.ai")
  - `:req_options` - Additional options passed to Req

  ## Example

      Alloy.run("What happened today?",
        provider: {Alloy.Provider.XAI,
          api_key: System.get_env("XAI_API_KEY"),
          model: "grok-3"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.OpenAIStream

  @default_api_url "https://api.x.ai"
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
    openai_messages = build_messages(messages, config)

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

  defp build_messages(messages, config) do
    system_msgs =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    conv_msgs = Enum.flat_map(messages, &format_message/1)
    system_msgs ++ conv_msgs
  end

  defp format_message(%Message{role: :user, content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp format_message(%Message{role: :assistant, content: content}) when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

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

  defp format_user_content_block(_block), do: nil

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
  defp parse_finish_reason(_), do: :end_turn

  defp parse_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> "#{error["type"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> "#{error["type"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end
end
