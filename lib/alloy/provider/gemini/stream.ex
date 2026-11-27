defmodule Alloy.Provider.Gemini.Stream do
  @moduledoc false
  # SSE streaming state machine for `Alloy.Provider.Gemini`.
  # Decodes chunk frames, merges consecutive text/thinking parts while
  # preserving thought signatures, emits streaming deltas, and prioritizes
  # explicit in-band API errors over malformed-chunk errors.

  alias Alloy.Message
  alias Alloy.Provider.{Error, SSE}

  @type extract_blocks_fn :: (map() -> {:ok, [Message.content_block()]} | {:error, Error.t()})

  @type outcome ::
          {:prompt_blocked, map()}
          | {:candidate, [Message.content_block()], map(), map()}

  # content_blocks is newest first. response and candidate hold the latest
  # top-level and candidate fields (usage, finishReason, promptFeedback).
  @spec initial_acc((String.t() -> :ok), (term() -> :ok), extract_blocks_fn(), [String.t()]) ::
          map()
  def initial_acc(on_chunk, on_event, extract_blocks, error_finish_reasons) do
    %{
      buffer: "",
      content_blocks: [],
      response: %{},
      candidate: %{},
      stream_error: nil,
      tool_call_count: 0,
      on_chunk: on_chunk,
      on_event: on_event,
      extract_blocks: extract_blocks,
      error_finish_reasons: error_finish_reasons
    }
  end

  @spec handle_event(map(), SSE.sse_event()) :: map()
  def handle_event(acc, %{data: "[DONE]"}), do: acc

  def handle_event(%{response: %{"error" => error}} = acc, _event)
      when is_map(error) or is_binary(error),
      do: acc

  # Once a malformed chunk is recorded, stop emitting text deltas so Retry can
  # still recover if nothing was streamed yet, while still capturing an
  # in-band API error chunk so it takes precedence over malformed siblings.
  def handle_event(%{stream_error: %Error{}} = acc, %{data: data}) do
    case decode_sse_chunk(data) do
      {:ok, %{"error" => error} = decoded} when is_map(error) or is_binary(error) ->
        merge_response_fields(acc, decoded)

      _ ->
        acc
    end
  end

  def handle_event(acc, %{data: data}) do
    if String.trim(data) == "" do
      acc
    else
      case decode_sse_chunk(data) do
        {:ok, decoded} -> handle_stream_chunk(acc, decoded)
        {:error, %Error{} = error} -> %{acc | stream_error: error}
      end
    end
  end

  # Prioritize explicit in-band API errors over malformed-chunk errors so a
  # real quota/safety error is never masked by a garbled sibling chunk.
  @spec finalize(map()) :: {:ok, outcome()} | {:error, Error.t()}
  def finalize(%{response: %{"error" => error}})
      when is_map(error) or is_binary(error),
      do: {:error, Error.from_body(%{"error" => error})}

  def finalize(%{stream_error: %Error{} = error}), do: {:error, error}

  def finalize(%{
        content_blocks: [],
        response: %{"promptFeedback" => %{"blockReason" => _}} = resp
      }),
      do: {:ok, {:prompt_blocked, resp}}

  # A finished stream always ends with a non-empty finishReason; without one
  # the connection was cut and the output is incomplete.
  def finalize(%{candidate: %{"finishReason" => reason}} = acc)
      when is_binary(reason) and reason != "",
      do: {:ok, {:candidate, Enum.reverse(acc.content_blocks), acc.candidate, acc.response}}

  def finalize(_acc),
    do: {:error, %Error{kind: :network, message: "Gemini stream ended before a finishReason"}}

  # --- Private ---

  defp decode_sse_chunk(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, [%{"error" => error} = wrapper | _]} when is_map(error) or is_binary(error) ->
        {:ok, wrapper}

      {:ok, _non_map} ->
        {:error, %Error{kind: :protocol_error, message: "Malformed payload in Gemini SSE chunk"}}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :malformed_reply,
           message: "Malformed JSON in Gemini SSE chunk: #{Exception.message(reason)}"
         }}
    end
  end

  defp handle_stream_chunk(acc, %{"error" => error} = chunk)
       when is_map(error) or is_binary(error) do
    merge_response_fields(acc, chunk)
  end

  defp handle_stream_chunk(acc, %{"candidates" => [candidate | _]} = chunk)
       when is_map(candidate) do
    case acc.extract_blocks.(candidate) do
      {:ok, blocks} ->
        tool_call_count =
          if Map.get(candidate, "finishReason") in acc.error_finish_reasons do
            acc.tool_call_count
          else
            Enum.reduce(blocks, acc.tool_call_count, fn block, tc_idx ->
              emit_stream_block_event(block, tc_idx, acc.on_chunk, acc.on_event)
            end)
          end

        candidate_updates =
          candidate
          |> Map.delete("content")
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        %{
          merge_response_fields(acc, chunk)
          | content_blocks: Enum.reduce(blocks, acc.content_blocks, &merge_stream_block/2),
            candidate: Map.merge(acc.candidate, candidate_updates),
            tool_call_count: tool_call_count
        }

      {:error, %Error{} = error} ->
        %{acc | stream_error: error}
    end
  end

  defp handle_stream_chunk(acc, %{"candidates" => [_non_map | _]}) do
    %{
      acc
      | stream_error: %Error{
          kind: :protocol_error,
          message: "Malformed candidate in Gemini SSE chunk"
        }
    }
  end

  defp handle_stream_chunk(acc, %{"candidates" => candidates} = chunk)
       when is_nil(candidates) or candidates == [] do
    merge_response_fields(acc, chunk)
  end

  defp handle_stream_chunk(acc, %{"candidates" => _non_list}) do
    %{
      acc
      | stream_error: %Error{
          kind: :protocol_error,
          message: "Malformed candidates in Gemini SSE chunk"
        }
    }
  end

  defp handle_stream_chunk(acc, %{} = chunk), do: merge_response_fields(acc, chunk)

  # Usage counts are running totals: a later chunk's count replaces the
  # earlier one, and a count it leaves out keeps its last value.
  defp merge_response_fields(acc, chunk) do
    fields = Map.delete(chunk, "candidates")

    response =
      Map.merge(acc.response, fields, fn
        "usageMetadata", previous, latest when is_map(previous) and is_map(latest) ->
          Map.merge(previous, Map.reject(latest, fn {_k, v} -> is_nil(v) end))

        "usageMetadata", _previous, latest when is_map(latest) ->
          Map.reject(latest, fn {_k, v} -> is_nil(v) end)

        "usageMetadata", previous, _latest when is_map(previous) ->
          previous

        "usageMetadata", _previous, _latest ->
          %{}

        "error", previous, nil when is_map(previous) or is_binary(previous) ->
          previous

        _key, _previous, latest ->
          latest
      end)

    %{acc | response: response}
  end

  defp emit_stream_block_event(%{type: "text", text: text}, tc_idx, on_chunk, _on_event)
       when is_binary(text) and text != "" do
    on_chunk.(text)
    tc_idx
  end

  defp emit_stream_block_event(
         %{type: "thinking", thinking: thinking},
         tc_idx,
         _on_chunk,
         on_event
       )
       when is_binary(thinking) and thinking != "" do
    on_event.({:thinking_delta, thinking})
    tc_idx
  end

  defp emit_stream_block_event(
         %{type: "tool_use", id: id, name: name, input: input},
         tc_idx,
         _on_chunk,
         on_event
       ) do
    on_event.(
      {:tool_call_delta,
       %{
         id: id,
         index: tc_idx,
         name: name,
         arguments_delta: Jason.encode!(input)
       }}
    )

    tc_idx + 1
  end

  defp emit_stream_block_event(_block, tc_idx, _on_chunk, _on_event), do: tc_idx

  # Gemini streams one logical part as many pieces. Kept apart, they become
  # separate blocks that Message.text/1 joins with newlines, so consecutive
  # text (or thought) pieces are merged back, newest block first. A thought
  # signature belongs to the part it arrived on (often a trailing empty
  # text piece), so it is kept on the merged block, and a signed block is
  # never extended: two signatures never share a block. Function calls
  # arrive whole and are never merged into.
  defp merge_stream_block(
         %{type: "text", text: text} = block,
         [%{type: "text", text: previous} = last | rest]
       )
       when not is_map_key(last, :signature),
       do: [%{block | text: previous <> text} | rest]

  defp merge_stream_block(
         %{type: "thinking", thinking: text} = block,
         [%{type: "thinking", thinking: previous} = last | rest]
       )
       when not is_map_key(last, :signature),
       do: [%{block | thinking: previous <> text} | rest]

  defp merge_stream_block(block, blocks), do: [block | blocks]
end
