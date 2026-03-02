defmodule Alloy.Provider.OpenAI do
  @moduledoc """
  Provider for OpenAI's Responses API.

  Normalizes OpenAI's response output items (assistant messages + function
  calls) to Alloy's content-block format.

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
  alias Alloy.Provider.SSE

  @default_api_url "https://api.openai.com"
  @default_max_tokens 4096

  @impl true
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    req_opts =
      ([
         url: "#{Map.get(config, :api_url, @default_api_url)}/v1/responses",
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
    body =
      messages
      |> build_request_body(tool_defs, config)
      |> Map.put("stream", true)

    url = "#{Map.get(config, :api_url, @default_api_url)}/v1/responses"

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"}
    ]

    initial_acc = %{
      buffer: "",
      content: "",
      response: nil,
      stream_error: nil,
      on_chunk: on_chunk
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_stream_event/2)

    req_opts =
      ([
         url: url,
         method: :post,
         headers: headers,
         body: Jason.encode!(body),
         into: stream_handler
       ] ++ Map.get(config, :req_options, []))
      |> Keyword.put(:retry, false)

    case Req.request(req_opts) do
      {:ok, %{status: 200} = resp} ->
        acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_stream_response(acc)

      {:ok, %{status: status} = resp} ->
        error_body = streaming_error_body(resp, initial_acc)
        {:error, parse_error(status, error_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    input_items = build_input_items(messages, config)

    body = %{
      "model" => config.model,
      "max_output_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "input" => input_items
    }

    case tool_defs do
      [] -> body
      defs -> Map.put(body, "tools", Enum.map(defs, &format_tool_def/1))
    end
  end

  defp build_input_items(messages, config) do
    system_items =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    convo_items = Enum.flat_map(messages, &format_input_item/1)
    system_items ++ convo_items
  end

  defp format_input_item(%Message{role: :user, content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: content}) when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: blocks}) when is_list(blocks) do
    function_calls =
      blocks
      |> Enum.filter(&(&1[:type] == "tool_use"))
      |> Enum.map(&format_assistant_function_call_item/1)

    text_parts =
      blocks
      |> Enum.filter(&(&1[:type] == "text"))
      |> Enum.map_join("\n", & &1.text)

    assistant_text_item =
      case text_parts do
        "" -> []
        text -> [%{"role" => "assistant", "content" => text}]
      end

    assistant_text_item ++ function_calls
  end

  defp format_input_item(%Message{role: :user, content: blocks}) when is_list(blocks) do
    if Enum.any?(blocks, &(&1[:type] == "tool_result")) do
      blocks
      |> Enum.map(fn
        %{type: "tool_result", tool_use_id: tool_call_id, content: content} ->
          %{"type" => "function_call_output", "call_id" => tool_call_id, "output" => content}

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      parts = blocks |> Enum.map(&format_user_content_block/1) |> Enum.reject(&is_nil/1)

      case parts do
        [] -> []
        _ -> [%{"role" => "user", "content" => parts}]
      end
    end
  end

  defp format_user_content_block(%{type: "text", text: text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp format_user_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{"type" => "input_image", "image_url" => "data:#{mime_type};base64,#{data}"}
  end

  defp format_user_content_block(%{type: "audio", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "video", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(_block), do: nil

  defp unsupported_media_notice(mime_type) do
    %{
      "type" => "input_text",
      "text" => "[Unsupported media type for OpenAI provider: #{mime_type}]"
    }
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "type" => "function",
      "name" => name,
      "description" => desc,
      "parameters" => Alloy.Provider.stringify_keys(schema)
    }
  end

  defp format_assistant_function_call_item(%{id: id, name: name, input: input}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(input)
    }
  end

  # --- Streaming ---

  # When streaming (into: handler), a non-200 body can be consumed by the SSE
  # callback and resp.body may be "". Recover it from the SSE buffer.
  defp streaming_error_body(resp, initial_acc) do
    case resp.body do
      "" ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        sse_acc.buffer

      body ->
        body
    end
  end

  defp handle_stream_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_stream_event(acc, %{event: event_name, data: data}) do
    case Jason.decode(data) do
      {:ok, parsed} ->
        event_type = event_name || Map.get(parsed, "type")
        process_stream_event(acc, event_type, parsed)

      {:error, _} ->
        acc
    end
  end

  defp process_stream_event(acc, "response.output_text.delta", %{"delta" => delta})
       when is_binary(delta) and delta != "" do
    acc.on_chunk.(delta)
    %{acc | content: acc.content <> delta}
  end

  defp process_stream_event(acc, "response.completed", %{"response" => response})
       when is_map(response) do
    %{acc | response: response}
  end

  defp process_stream_event(acc, "response.failed", payload) do
    %{acc | stream_error: parse_stream_event_error(payload)}
  end

  defp process_stream_event(acc, "error", payload) do
    %{acc | stream_error: parse_stream_event_error(payload)}
  end

  defp process_stream_event(acc, _event_type, _payload), do: acc

  defp build_stream_response(%{stream_error: error}) when is_binary(error) do
    {:error, error}
  end

  defp build_stream_response(%{response: response}) when is_map(response) do
    parse_response(response)
  end

  defp build_stream_response(%{content: content}) do
    content_blocks = if content == "", do: [], else: [%{type: "text", text: content}]

    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [%Message{role: :assistant, content: content_blocks}],
       usage: %{input_tokens: 0, output_tokens: 0}
     }}
  end

  defp parse_stream_event_error(payload) do
    payload
    |> Map.get("error", payload)
    |> format_error_payload()
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"output" => output} = resp) when is_list(output) do
    usage = resp["usage"] || %{}

    case parse_output_to_blocks(output) do
      {:ok, content_blocks} ->
        stop_reason = parse_stop_reason(content_blocks)

        alloy_msg = %Message{
          role: :assistant,
          content: content_blocks
        }

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [alloy_msg],
           usage: %{
             input_tokens: Map.get(usage, "input_tokens", 0),
             output_tokens: Map.get(usage, "output_tokens", 0)
           }
         }}

      {:error, _} = err ->
        err
    end
  end

  defp parse_response(%{"output_text" => text} = resp) when is_binary(text) do
    usage = resp["usage"] || %{}

    content_blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [%Message{role: :assistant, content: content_blocks}],
       usage: %{
         input_tokens: Map.get(usage, "input_tokens", 0),
         output_tokens: Map.get(usage, "output_tokens", 0)
       }
     }}
  end

  defp parse_response(%{"error" => error}) do
    {:error, format_error_payload(error)}
  end

  defp parse_response(resp) do
    {:error, "Unexpected OpenAI response payload: #{inspect(resp)}"}
  end

  defp parse_output_to_blocks(output) do
    result =
      Enum.reduce_while(output, {:ok, []}, fn item, {:ok, acc} ->
        case parse_output_item(item) do
          {:ok, blocks} -> {:cont, {:ok, [blocks | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, nested} -> {:ok, nested |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp parse_output_item(%{"type" => "message", "role" => "assistant", "content" => content})
       when is_list(content) do
    {:ok, parse_assistant_content(content)}
  end

  defp parse_output_item(%{"type" => "message", "role" => "assistant", "content" => text})
       when is_binary(text) do
    blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok, blocks}
  end

  defp parse_output_item(%{"type" => "function_call", "name" => name} = call) do
    case decode_function_call_arguments(call) do
      {:ok, input} ->
        {:ok, [%{type: "tool_use", id: call["call_id"] || call["id"], name: name, input: input}]}

      {:error, _} = err ->
        err
    end
  end

  defp parse_output_item(_item), do: {:ok, []}

  defp parse_assistant_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      %{"type" => "refusal", "refusal" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      %{"type" => "refusal", "text" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      _ ->
        []
    end)
  end

  defp parse_assistant_content(_content), do: []

  defp parse_stop_reason(content_blocks) do
    if Enum.any?(content_blocks, &(&1.type == "tool_use")), do: :tool_use, else: :end_turn
  end

  defp decode_function_call_arguments(%{"name" => name} = call) do
    args = Map.get(call, "arguments", "")

    case args do
      "" ->
        {:ok, %{}}

      encoded when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, input} -> {:ok, input}
          {:error, _} -> {:error, "Invalid JSON in tool call arguments for #{name}"}
        end

      decoded when is_map(decoded) ->
        {:ok, decoded}

      _other ->
        {:error, "Invalid tool call arguments payload for #{name}"}
    end
  end

  defp parse_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        format_error_payload(error)

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> format_error_payload(error)
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end

  defp format_error_payload(error) when is_map(error) do
    type = Map.get(error, "type", "error")
    message = Map.get(error, "message", inspect(error))
    "#{type}: #{message}"
  end

  defp format_error_payload(error), do: inspect(error)
end
