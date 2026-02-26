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

  @doc """
  Stream a completion using Anthropic's SSE streaming API.

  Calls `on_chunk` for each text delta as it arrives. Accumulates all
  content blocks and returns the same `{:ok, completion_response()}` shape
  as `complete/3` once the stream finishes.
  """
  @impl true
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    body =
      build_request_body(messages, tool_defs, config)
      |> Map.put("stream", true)

    # Mutable accumulator for SSE state, held in a process dictionary-free
    # approach using the Req `into:` callback accumulator pattern.
    initial_acc = %{
      buffer: "",
      content_blocks: %{},
      input_json_buffers: %{},
      stop_reason: nil,
      usage: %{},
      on_chunk: on_chunk
    }

    stream_handler = fn {:data, chunk}, {req, resp} ->
      # Store our SSE accumulator in the response private map
      sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
      sse_acc = process_sse_chunk(sse_acc, chunk)
      resp = put_in(resp.private[:sse_acc], sse_acc)
      {:cont, {req, resp}}
    end

    req_opts =
      [
        url: "#{Map.get(config, :api_url, @default_api_url)}/v1/messages",
        method: :post,
        headers: [
          {"x-api-key", config.api_key},
          {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(body),
        into: stream_handler,
        retry: :transient,
        max_retries: 3
      ] ++ Map.get(config, :req_options, [])

    case Req.request(req_opts) do
      {:ok, %{status: 200} = resp} ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_stream_response(sse_acc)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # Process a raw SSE chunk. Chunks may contain partial events, so we buffer
  # and split on double-newline boundaries.
  defp process_sse_chunk(acc, chunk) do
    buffer = acc.buffer <> chunk

    # Split on double-newline (SSE event boundary)
    {events, remaining} = split_sse_events(buffer)

    acc = %{acc | buffer: remaining}

    Enum.reduce(events, acc, fn event, acc ->
      process_sse_event(acc, event)
    end)
  end

  defp split_sse_events(buffer) do
    # SSE events are separated by \n\n
    parts = String.split(buffer, "\n\n")

    case parts do
      # Only one part means no complete event yet
      [only] ->
        {[], only}

      # Last part is the incomplete remainder
      _ ->
        {complete, [remainder]} = Enum.split(parts, length(parts) - 1)
        {complete, remainder}
    end
  end

  defp process_sse_event(acc, event_str) do
    lines = String.split(event_str, "\n")

    event_type =
      Enum.find_value(lines, fn
        "event: " <> type -> String.trim(type)
        _ -> nil
      end)

    data =
      Enum.find_value(lines, fn
        "data: " <> json -> json
        _ -> nil
      end)

    if event_type && data do
      case Jason.decode(data) do
        {:ok, parsed} -> handle_sse_event(acc, event_type, parsed)
        {:error, _} -> acc
      end
    else
      acc
    end
  end

  defp handle_sse_event(acc, "message_start", %{"message" => msg}) do
    usage = Map.get(msg, "usage", %{})
    %{acc | usage: merge_sse_usage(acc.usage, usage)}
  end

  defp handle_sse_event(acc, "content_block_start", %{
         "index" => index,
         "content_block" => block
       }) do
    put_in(acc.content_blocks[index], block)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    # Call on_chunk for text deltas
    acc.on_chunk.(text)

    # Accumulate text into the content block
    current = Map.get(acc.content_blocks, index, %{"type" => "text", "text" => ""})
    updated = Map.update!(current, "text", &(&1 <> text))
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       }) do
    # Accumulate partial JSON for tool_use input
    current_buffer = Map.get(acc.input_json_buffers, index, "")
    %{acc | input_json_buffers: Map.put(acc.input_json_buffers, index, current_buffer <> json)}
  end

  defp handle_sse_event(acc, "content_block_stop", %{"index" => index}) do
    with json_str when is_binary(json_str) <- Map.get(acc.input_json_buffers, index),
         {:ok, input} <- Jason.decode(json_str) do
      current = Map.get(acc.content_blocks, index, %{})
      updated = Map.put(current, "input", input)

      acc
      |> put_in([Access.key(:content_blocks), index], updated)
      |> Map.put(:input_json_buffers, Map.delete(acc.input_json_buffers, index))
    else
      _ -> acc
    end
  end

  defp handle_sse_event(acc, "message_delta", %{"delta" => delta, "usage" => usage}) do
    stop_reason = Map.get(delta, "stop_reason")
    %{acc | stop_reason: stop_reason, usage: merge_sse_usage(acc.usage, usage)}
  end

  defp handle_sse_event(acc, "message_delta", %{"delta" => delta}) do
    stop_reason = Map.get(delta, "stop_reason")
    %{acc | stop_reason: stop_reason}
  end

  defp handle_sse_event(acc, _event_type, _data), do: acc

  defp merge_sse_usage(existing, new) do
    Map.merge(existing, new, fn _k, v1, v2 ->
      if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
    end)
  end

  defp build_stream_response(acc) do
    # Sort content blocks by index and convert to normalized format
    content_blocks =
      acc.content_blocks
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, block} -> block end)
      |> parse_content_blocks()

    stop_reason = parse_stop_reason(acc.stop_reason)
    usage = parse_usage(acc.usage)

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
    %{
      "name" => name,
      "description" => desc,
      "input_schema" => Anvil.Provider.stringify_keys(schema)
    }
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Anvil.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
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
end
