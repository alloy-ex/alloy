defmodule Alloy.Provider.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API.

  OpenRouter is a unified gateway to 100+ LLM models from various providers
  (Anthropic, OpenAI, Google, Meta, Mistral, xAI, MiniMax, Qwen, etc.)
  through a single API key and OpenAI-compatible format.

  ## Config

  Required:
  - `:api_key` - OpenRouter API key
  - `:model` - Model in provider/model format (e.g., "anthropic/claude-sonnet-4-6",
    "openai/gpt-5.2", "google/gemini-2.5-flash", "x-ai/grok-3",
    "qwen/qwen3-72b", "meta-llama/llama-4-70b")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://openrouter.ai")
  - `:app_name` - Your app name for OpenRouter attribution (default: "Alloy")
  - `:app_url` - Your app URL for OpenRouter attribution (default: "https://github.com/alloy-ex")
  - `:req_options` - Additional options passed to Req

  ## Example

      # Access 100+ models through a single API key
      Alloy.run("Compare Elixir and Go.",
        provider: {Alloy.Provider.OpenRouter,
          api_key: System.get_env("OPENROUTER_API_KEY"),
          model: "anthropic/claude-sonnet-4-6"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.OpenAIStream

  @default_api_url "https://openrouter.ai"
  @default_max_tokens 4096

  @impl true
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"},
      {"http-referer", Map.get(config, :app_url, "https://github.com/alloy-ex")},
      {"x-title", Map.get(config, :app_name, "Alloy")}
    ]

    req_opts =
      ([
         url: "#{Map.get(config, :api_url, @default_api_url)}/api/v1/chat/completions",
         method: :post,
         headers: headers,
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
    url = "#{Map.get(config, :api_url, @default_api_url)}/api/v1/chat/completions"

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"},
      {"http-referer", Map.get(config, :app_url, "https://github.com/alloy-ex")},
      {"x-title", Map.get(config, :app_name, "Alloy")}
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
    Enum.map(blocks, fn
      %{type: "tool_result", tool_use_id: tool_call_id, content: content} ->
        %{
          "role" => "tool",
          "tool_call_id" => tool_call_id,
          "content" => content
        }

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

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
    content_blocks = parse_message_to_blocks(message)
    stop_reason = parse_finish_reason(finish_reason)
    usage = resp["usage"] || %{}

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
      |> Enum.map(fn tc ->
        %{
          type: "tool_use",
          id: tc["id"],
          name: tc["function"]["name"],
          input: Jason.decode!(tc["function"]["arguments"])
        }
      end)

    text_blocks ++ tool_blocks
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
