defmodule Alloy.Provider.Google do
  @moduledoc """
  Provider for Google's Gemini API.

  Normalizes Google's wire format (functionCall/functionResponse parts,
  systemInstruction, functionDeclarations) to Alloy's content-block format.

  ## Config

  Required:
  - `:api_key` - Google AI API key
  - `:model` - Model name (e.g., "gemini-2.5-flash", "gemini-2.5-pro",
    "gemini-3-flash-preview")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://generativelanguage.googleapis.com")
  - `:req_options` - Additional options passed to Req

  ## Example

      Alloy.run("Explain OTP supervisors.",
        provider: {Alloy.Provider.Google,
          api_key: System.get_env("GEMINI_API_KEY"),
          model: "gemini-2.5-flash"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message

  @default_api_url "https://generativelanguage.googleapis.com"
  @default_max_tokens 4096

  @impl true
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)
    model = config.model

    req_opts =
      [
        url:
          "#{Map.get(config, :api_url, @default_api_url)}/v1beta/models/#{model}:generateContent",
        method: :post,
        headers: [
          {"content-type", "application/json"},
          {"x-goog-api-key", config.api_key}
        ],
        body: Jason.encode!(body),
        retry: :transient,
        max_retries: 3
      ] ++ Map.get(config, :req_options, [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    body = %{
      "contents" => format_all_messages(messages),
      "generationConfig" => %{
        "maxOutputTokens" => Map.get(config, :max_tokens, @default_max_tokens)
      }
    }

    body =
      case Map.get(config, :system_prompt) do
        nil ->
          body

        prompt ->
          Map.put(body, "systemInstruction", %{
            "parts" => [%{"text" => prompt}]
          })
      end

    case tool_defs do
      [] ->
        body

      defs ->
        Map.put(body, "tools", [
          %{"functionDeclarations" => Enum.map(defs, &format_tool_def/1)}
        ])
    end
  end

  # Build a map of tool_use_id -> tool_name from conversation history
  defp build_tool_name_map(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{role: :assistant, content: blocks} when is_list(blocks) ->
        blocks
        |> Enum.filter(&(&1[:type] == "tool_use"))
        |> Enum.map(&{&1.id, &1.name})

      _ ->
        []
    end)
    |> Map.new()
  end

  defp format_all_messages(messages) do
    name_map = build_tool_name_map(messages)
    Enum.flat_map(messages, &format_message(&1, name_map))
  end

  # Simple text user message
  defp format_message(%Message{role: :user, content: content}, _name_map)
       when is_binary(content) do
    [%{"role" => "user", "parts" => [%{"text" => content}]}]
  end

  # Simple text assistant message -> model role
  defp format_message(%Message{role: :assistant, content: content}, _name_map)
       when is_binary(content) do
    [%{"role" => "model", "parts" => [%{"text" => content}]}]
  end

  # Assistant message with content blocks (may contain tool_use)
  defp format_message(%Message{role: :assistant, content: blocks}, _name_map)
       when is_list(blocks) do
    parts =
      Enum.map(blocks, fn
        %{type: "text", text: text} ->
          %{"text" => text}

        %{type: "tool_use", name: name, input: input} ->
          %{"functionCall" => %{"name" => name, "args" => input}}
      end)

    [%{"role" => "model", "parts" => parts}]
  end

  # User message with tool_result blocks -> functionResponse parts
  defp format_message(%Message{role: :user, content: blocks}, name_map) when is_list(blocks) do
    parts =
      Enum.map(blocks, fn
        %{type: "tool_result", tool_use_id: tool_use_id, content: content} ->
          name = Map.get(name_map, tool_use_id, tool_use_id)

          %{
            "functionResponse" => %{
              "name" => name,
              "response" => %{"content" => content}
            }
          }
      end)

    [%{"role" => "user", "parts" => parts}]
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "name" => name,
      "description" => desc,
      "parameters" => Alloy.Provider.stringify_keys(schema)
    }
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"candidates" => [candidate | _]} = resp) do
    content = candidate["content"]
    finish_reason = candidate["finishReason"]
    parts = content["parts"] || []

    content_blocks = parse_parts_to_blocks(parts)
    stop_reason = parse_finish_reason(finish_reason, content_blocks)
    usage = parse_usage(resp["usageMetadata"] || %{})

    alloy_msg = %Message{
      role: :assistant,
      content: content_blocks
    }

    {:ok,
     %{
       stop_reason: stop_reason,
       messages: [alloy_msg],
       usage: usage
     }}
  end

  defp parse_response(%{"error" => error}) do
    {:error, "#{error["status"]}: #{error["message"]}"}
  end

  defp parse_parts_to_blocks(parts) do
    Enum.map(parts, fn
      %{"text" => text} ->
        %{type: "text", text: text}

      %{"functionCall" => %{"name" => name, "args" => args}} ->
        %{
          type: "tool_use",
          id: generate_tool_id(name),
          name: name,
          input: args
        }
    end)
  end

  # Google doesn't have a "tool_calls" finish reason — we detect it from content
  defp parse_finish_reason(_reason, blocks) do
    has_tool_use = Enum.any?(blocks, &(&1.type == "tool_use"))
    if has_tool_use, do: :tool_use, else: :end_turn
  end

  defp parse_usage(metadata) do
    %{
      input_tokens: Map.get(metadata, "promptTokenCount", 0),
      output_tokens: Map.get(metadata, "candidatesTokenCount", 0)
    }
  end

  defp parse_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        "#{error["status"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> "#{error["status"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end

  defp generate_tool_id(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "alloy_#{name}_#{random}"
  end
end
