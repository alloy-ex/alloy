defmodule Anvil.Provider.Anthropic do
  @moduledoc """
  Provider for Anthropic's Claude Messages API.

  Uses Req for HTTP calls. Since Anthropic's wire format uses content blocks
  (the most expressive format), this provider has the simplest normalization.

  ## Config

  Required:
  - `:api_key` - Anthropic API key
  - `:model` - Model name (e.g., "claude-sonnet-4-5-20250514")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.anthropic.com")
  - `:api_version` - API version header (default: "2023-06-01")
  - `:req_options` - Additional options passed to Req (useful for testing)
  """

  @behaviour Anvil.Provider

  alias Anvil.Message

  @default_api_url "https://api.anthropic.com"
  @default_api_version "2023-06-01"
  @default_max_tokens 4096

  @impl true
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    req_opts =
      [
        url: "#{Map.get(config, :api_url, @default_api_url)}/v1/messages",
        method: :post,
        headers: [
          {"x-api-key", config.api_key},
          {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(body)
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
      "model" => config.model,
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => Enum.map(messages, &format_message/1)
    }

    body =
      case Map.get(config, :system_prompt) do
        nil -> body
        prompt -> Map.put(body, "system", prompt)
      end

    body =
      case tool_defs do
        [] -> body
        defs -> Map.put(body, "tools", Enum.map(defs, &format_tool_def/1))
      end

    body
  end

  defp format_message(%Message{role: role, content: content}) when is_binary(content) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    %{"role" => to_string(role), "content" => Enum.map(blocks, &format_content_block/1)}
  end

  defp format_content_block(%{type: "text", text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: "tool_use", id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp format_content_block(%{type: "tool_result", tool_use_id: id, content: content} = block) do
    result = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if Map.get(block, :is_error), do: Map.put(result, "is_error", true), else: result
  end

  defp format_content_block(block) when is_map(block) do
    # Pass through any other block types as-is, converting atom keys to strings
    Map.new(block, fn {k, v} -> {to_string(k), v} end)
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{"name" => name, "description" => desc, "input_schema" => stringify_keys(schema)}
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} -> {:error, "Failed to decode response JSON"}
    end
  end

  defp parse_response(%{"type" => "message"} = resp) do
    stop_reason = parse_stop_reason(resp["stop_reason"])
    content_blocks = parse_content_blocks(resp["content"] || [])
    usage = parse_usage(resp["usage"] || %{})

    message = %Message{
      role: :assistant,
      content: content_blocks
    }

    {:ok,
     %{
       stop_reason: stop_reason,
       messages: [message],
       usage: usage
     }}
  end

  defp parse_response(%{"type" => "error"} = resp) do
    error = resp["error"] || %{}
    {:error, "#{error["type"]}: #{error["message"]}"}
  end

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :end_turn
  defp parse_stop_reason("stop_sequence"), do: :end_turn
  defp parse_stop_reason(_), do: :end_turn

  defp parse_content_blocks(blocks) do
    Enum.map(blocks, &parse_content_block/1)
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    %{type: "text", text: text}
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp parse_content_block(block) do
    # Unknown block type - preserve as-is with atom keys
    Map.new(block, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> block
  end

  defp parse_usage(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens", 0),
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens", 0)
    }
  end

  defp parse_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "error", "error" => error}} ->
        "#{error["type"]}: #{error["message"]}"

      {:ok, %{"error" => error}} when is_map(error) ->
        "#{error["type"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"type" => "error", "error" => error} ->
        "#{error["type"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{inspect(body)}"
    end
  end

  # --- Helpers ---

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
