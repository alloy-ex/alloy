defmodule Alloy.Provider.OpenAIStream do
  @moduledoc """
  Shared OpenAI-format SSE stream parser.

  Used by all OpenAI-compatible providers (OpenAI, DeepSeek, Mistral,
  OpenRouter, xAI, Ollama). Each provider calls `stream/5` with its
  own URL and headers; this module handles SSE parsing and response
  normalization.

  ## OpenAI Streaming Format

      data: {"choices":[{"index":0,"delta":{"content":"chunk"}}]}
      data: {"choices":[{"index":0,"delta":{"tool_calls":[...]}}]}
      data: [DONE]

  Text deltas are emitted via `on_chunk`. Tool call argument deltas
  are accumulated silently. The final response has the same shape as
  `complete/3`.
  """

  alias Alloy.Message
  alias Alloy.Provider.SSE

  @doc """
  Execute a streaming request against an OpenAI-compatible endpoint.

  Returns `{:ok, completion_response()} | {:error, term()}`.
  """
  @spec stream(String.t(), [{String.t(), String.t()}], map(), (String.t() -> :ok), keyword()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(url, headers, body, on_chunk, req_options) when is_function(on_chunk, 1) do
    body =
      body
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    initial_acc = %{
      buffer: "",
      content: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: %{},
      on_chunk: on_chunk
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_event/2)

    req_opts =
      ([
         url: url,
         method: :post,
         headers: headers,
         body: Jason.encode!(body),
         into: stream_handler
       ] ++ req_options)
      |> Keyword.put(:retry, false)

    case Req.request(req_opts) do
      {:ok, %{status: 200} = resp} ->
        acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_response(acc)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # ── SSE Event Handling ───────────────────────────────────────────────

  defp handle_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_event(acc, %{data: data}) do
    case Jason.decode(data) do
      {:ok, parsed} -> process_event(acc, parsed)
      {:error, _} -> acc
    end
  end

  defp process_event(acc, %{"choices" => [%{"delta" => delta} | _]} = event) do
    acc =
      case delta do
        %{"content" => text} when is_binary(text) and text != "" ->
          acc.on_chunk.(text)
          %{acc | content: acc.content <> text}

        _ ->
          acc
      end

    acc = accumulate_tool_calls(acc, Map.get(delta, "tool_calls", []))

    acc =
      case event do
        %{"choices" => [%{"finish_reason" => reason} | _]} when is_binary(reason) ->
          %{acc | finish_reason: reason}

        _ ->
          acc
      end

    acc
  end

  # Usage event: either no choices key, or empty choices list.
  # This clause is ordered BEFORE the catch-all to handle both shapes
  # reliably — some providers send usage alongside empty choices, others
  # send it as a top-level-only event.
  defp process_event(acc, %{"choices" => [], "usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  defp process_event(acc, %{"usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  defp process_event(acc, _event), do: acc

  # ── Tool Call Accumulation ───────────────────────────────────────────

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, tool_call_deltas) do
    tool_calls =
      Enum.reduce(tool_call_deltas, acc.tool_calls, fn tc_delta, tool_calls ->
        index = tc_delta["index"]
        existing = Map.get(tool_calls, index, %{id: nil, name: nil, arguments_buffer: ""})

        existing =
          case tc_delta do
            %{"id" => id} -> %{existing | id: id}
            _ -> existing
          end

        existing =
          case get_in(tc_delta, ["function", "name"]) do
            nil -> existing
            name -> %{existing | name: name}
          end

        existing =
          case get_in(tc_delta, ["function", "arguments"]) do
            nil -> existing
            args -> %{existing | arguments_buffer: existing.arguments_buffer <> args}
          end

        Map.put(tool_calls, index, existing)
      end)

    %{acc | tool_calls: tool_calls}
  end

  # ── Response Building ────────────────────────────────────────────────

  defp build_response(acc) do
    text_blocks = if acc.content != "", do: [%{type: "text", text: acc.content}], else: []

    tool_blocks_result =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.reduce_while([], fn {_index, tc}, blocks ->
        # Treat empty buffer as an empty-input tool call (no-arg tools send "" not "{}").
        # Treat non-empty invalid JSON as an error — likely network truncation.
        input_result =
          case tc.arguments_buffer do
            "" -> {:ok, %{}}
            args -> Jason.decode(args)
          end

        case input_result do
          {:ok, input} ->
            block = %{type: "tool_use", id: tc.id, name: tc.name, input: input}
            {:cont, [block | blocks]}

          {:error, reason} ->
            {:halt, {:error, "Invalid tool call JSON for #{tc.name}: #{inspect(reason)}"}}
        end
      end)

    case tool_blocks_result do
      {:error, reason} ->
        {:error, reason}

      tool_blocks ->
        content_blocks = text_blocks ++ Enum.reverse(tool_blocks)
        stop_reason = parse_finish_reason(acc.finish_reason)
        message = %Message{role: :assistant, content: content_blocks}

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [message],
           usage: %{
             input_tokens: Map.get(acc.usage, "prompt_tokens", 0),
             output_tokens: Map.get(acc.usage, "completion_tokens", 0)
           }
         }}
    end
  end

  defp parse_finish_reason("stop"), do: :end_turn
  defp parse_finish_reason("tool_calls"), do: :tool_use
  defp parse_finish_reason("length"), do: :end_turn
  defp parse_finish_reason("content_filter"), do: :end_turn
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
