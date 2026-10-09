defmodule Alloy.Provider.OpenAIStream do
  @moduledoc """
  Shared OpenAI-format SSE stream parser.

  Used by `Alloy.Provider.OpenAICompat` for Chat Completions providers
  such as DeepSeek, Mistral, OpenRouter, Gemini, and Ollama.
  The native OpenAI and xAI providers use Responses API parsing instead.
  Each compatible provider calls `stream/5` with its
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
  alias Alloy.Provider.{Error, HTTP}

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
      |> put_stream_options()

    initial_acc = %{
      buffer: "",
      content: "",
      reasoning_content: "",
      tool_calls: %{},
      finish_reason: nil,
      done?: false,
      stream_error: nil,
      usage: %{},
      on_chunk: on_chunk
    }

    with {:ok, acc} <-
           HTTP.stream_sse(url, headers, body, initial_acc, &handle_event/2, req_options) do
      build_response(acc)
    end
  end

  @doc false
  # Shared with OpenAICompat's non-streaming path so both read finish
  # reasons and usage the same way.
  @spec completion_response([Message.content_block()], String.t() | nil, map()) ::
          Alloy.Provider.completion_response()
  def completion_response(content_blocks, finish_reason, usage) do
    put_stop_details(
      %{
        stop_reason: stop_reason(finish_reason),
        messages: [%Message{role: :assistant, content: content_blocks}],
        usage: parse_usage(usage)
      },
      finish_reason
    )
  end

  # Alloy.Usage follows Anthropic: input_tokens excludes cache reads and
  # writes, which have their own fields. OpenAI-style servers count both
  # inside prompt_tokens, so they are taken out here.
  defp parse_usage(usage) do
    details = usage["prompt_tokens_details"] || %{}
    cache_read = details["cached_tokens"] || 0
    cache_write = details["cache_write_tokens"] || 0

    %{
      input_tokens: max((usage["prompt_tokens"] || 0) - cache_read - cache_write, 0),
      output_tokens: usage["completion_tokens"] || 0,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_write
    }
  end

  # Request usage by default, but preserve custom options and omit the field
  # entirely when the caller disables it for a less compatible endpoint.
  defp put_stream_options(%{"stream_options" => false} = body),
    do: Map.delete(body, "stream_options")

  defp put_stream_options(body),
    do: Map.put_new(body, "stream_options", %{"include_usage" => true})

  # ── SSE Event Handling ───────────────────────────────────────────────

  defp handle_event(acc, %{data: "[DONE]"}), do: %{acc | done?: true}

  defp handle_event(acc, %{data: data}) do
    case Jason.decode(data) do
      {:ok, parsed} -> process_event(acc, parsed)
      {:error, _} -> acc
    end
  end

  # Servers report failures after the 200 status line as an error chunk
  # (OpenRouter adds finish_reason "error" alongside it).
  defp process_event(acc, %{"error" => error} = event) when is_map(error) or is_binary(error) do
    %{acc | stream_error: Error.from_body(event)}
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

    # Accumulate reasoning_content from DeepSeek/xAI reasoning models
    acc =
      case delta do
        %{"reasoning_content" => text} when is_binary(text) and text != "" ->
          %{acc | reasoning_content: acc.reasoning_content <> text}

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

  # DeepInfra sends "tool_calls": null on chunks without a call.
  defp accumulate_tool_calls(acc, nil), do: acc
  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, tool_call_deltas) do
    tool_calls =
      Enum.reduce(tool_call_deltas, acc.tool_calls, fn tc_delta, tool_calls ->
        index = tc_delta["index"]

        existing =
          Map.get(tool_calls, index, %{
            id: nil,
            name: nil,
            arguments_buffer: "",
            thought_signature: nil
          })

        existing =
          case tc_delta do
            # Some providers (DeepInfra) repeat "id": null on every later chunk of
            # the same call; only a real id may set it, or it is overwritten.
            %{"id" => id} when is_binary(id) and id != "" -> %{existing | id: id}
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

        existing =
          case get_in(tc_delta, ["extra_content", "google", "thought_signature"]) do
            signature when is_binary(signature) and signature != "" ->
              %{existing | thought_signature: signature}

            _ ->
              existing
          end

        Map.put(tool_calls, index, existing)
      end)

    %{acc | tool_calls: tool_calls}
  end

  # ── Response Building ────────────────────────────────────────────────

  defp build_response(%{stream_error: %Error{} = error}), do: {:error, error}

  # Neither a finish_reason nor [DONE]: the connection was cut mid-response,
  # so the partial output must not be passed off as a complete answer.
  defp build_response(%{finish_reason: nil, done?: false}) do
    {:error,
     %Error{
       kind: :network,
       message: "Chat Completions stream ended before the response completed"
     }}
  end

  defp build_response(acc) do
    reasoning_blocks =
      if acc.reasoning_content != "",
        do: [%{type: "thinking", thinking: acc.reasoning_content}],
        else: []

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

            block =
              if is_binary(tc.thought_signature),
                do: Map.put(block, :thought_signature, tc.thought_signature),
                else: block

            {:cont, [block | blocks]}

          {:error, reason} ->
            {:halt, {:error, "Invalid tool call JSON for #{tc.name}: #{inspect(reason)}"}}
        end
      end)

    case tool_blocks_result do
      {:error, reason} ->
        {:error, reason}

      tool_blocks ->
        content_blocks = reasoning_blocks ++ text_blocks ++ Enum.reverse(tool_blocks)
        {:ok, completion_response(content_blocks, acc.finish_reason, acc.usage)}
    end
  end

  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("content_filter"), do: :refusal
  defp stop_reason(reason) when reason in ["tool_calls", "function_call"], do: :tool_use
  # "stop", a reason omitted before [DONE], and provider-specific values.
  defp stop_reason(_reason), do: :end_turn

  defp put_stop_details(response, "content_filter") do
    Map.put(response, :response_metadata, %{stop_details: %{"finish_reason" => "content_filter"}})
  end

  defp put_stop_details(response, _finish_reason), do: response
end
