defmodule Alloy.Provider.Anthropic.Stream do
  @moduledoc false
  # SSE streaming state machine for `Alloy.Provider.Anthropic`.
  # Accumulates content blocks, emits text/thinking/tool-call deltas, tracks
  # protocol and tool JSON errors, and preserves refusal-over-sticky-error
  # precedence when assembling the final raw Messages API payload.

  alias Alloy.Provider.{Error, HTTP, SSE}

  @known_sse_events [
    "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
    "error",
    "ping"
  ]

  @known_delta_types [
    "input_json_delta",
    "text_delta",
    "thinking_delta",
    "signature_delta"
  ]

  # "refusal" is handled ahead of this list because refused output is discarded.
  @incomplete_tool_exempt_stop_reasons ["max_tokens", "model_context_window_exceeded"]

  @spec initial_acc((String.t() -> :ok), (term() -> :ok)) :: map()
  def initial_acc(on_chunk, on_event) do
    %{
      buffer: "",
      error: nil,
      sticky_error: nil,
      tool_json_error: nil,
      message: %{},
      content_blocks: %{},
      open_tool_blocks: %{},
      input_json_buffers: %{},
      on_chunk: on_chunk,
      on_event: on_event
    }
  end

  # Once a fatal protocol error is recorded, ignore subsequent events without
  # emitting chunks/events (so Retry can still retry if nothing was streamed
  # yet), except "error" (API error takes precedence) and "message_delta" (so
  # stop_reason: "refusal" still bypasses retries).
  @spec handle_raw_event(map(), SSE.sse_event()) :: map()
  def handle_raw_event(%{sticky_error: %Error{}} = acc, %{event: event_type, data: data})
      when event_type in ["error", "message_delta"] do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) -> handle_sse_event(acc, event_type, parsed)
      _ -> acc
    end
  end

  def handle_raw_event(%{sticky_error: %Error{}} = acc, _event), do: acc

  # Bridge from SSE module's raw events to Anthropic's typed event handler.
  # Known Anthropic SSE events carry a JSON object payload; undecodable or
  # non-object data is recorded as a sticky protocol error. Unknown future
  # event types are ignored forward-compatibly.
  def handle_raw_event(acc, %{event: event_type, data: data})
      when event_type in @known_sse_events do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) ->
        handle_sse_event(acc, event_type, parsed)

      {:ok, _non_map} ->
        record_protocol_error(
          acc,
          "Malformed payload in Anthropic SSE #{event_type} event"
        )

      {:error, _} ->
        record_malformed_error(
          acc,
          "Malformed JSON in Anthropic SSE #{event_type} event"
        )
    end
  end

  def handle_raw_event(acc, _event), do: acc

  @spec assemble_message(map()) :: {:ok, map()} | {:error, Error.t()}
  def assemble_message(%{error: %Error{} = error}), do: {:error, error}

  # Refusal discards output, so partial blocks or trailing stream anomalies do not trigger retries.
  def assemble_message(%{message: %{"stop_reason" => "refusal"}} = acc) do
    {:ok, assemble_raw_message(acc)}
  end

  def assemble_message(%{sticky_error: %Error{} = error}), do: {:error, error}

  def assemble_message(%{
        message: %{"stop_reason" => stop_reason},
        tool_json_error: %Error{} = error
      })
      when is_binary(stop_reason) and
             stop_reason not in @incomplete_tool_exempt_stop_reasons do
    {:error, error}
  end

  def assemble_message(
        %{
          message: %{"stop_reason" => stop_reason},
          open_tool_blocks: open,
          input_json_buffers: buffers
        } = acc
      )
      when is_binary(stop_reason) and
             stop_reason not in @incomplete_tool_exempt_stop_reasons and
             (map_size(open) > 0 or map_size(buffers) > 0) do
    index = (Map.keys(open) ++ Map.keys(buffers)) |> Enum.min()
    name = acc.content_blocks |> Map.get(index, %{}) |> Map.get("name", "unknown")

    {:error,
     %Error{
       kind: :malformed_reply,
       message: "Incomplete tool call arguments for #{name} (missing content_block_stop)"
     }}
  end

  def assemble_message(%{message: %{"stop_reason" => stop_reason}} = acc)
      when is_binary(stop_reason) do
    {:ok, assemble_raw_message(acc)}
  end

  # Only the final message_delta carries a stop_reason, so a stream that ends
  # without one was cut off and its content is incomplete.
  def assemble_message(_acc) do
    {:error,
     %Error{
       kind: :network,
       message: "Anthropic stream ended before a stop_reason was received"
     }}
  end

  # --- Private ---

  defp handle_sse_event(acc, "message_start", %{"message" => msg}) when is_map(msg) do
    %{acc | message: msg}
  end

  defp handle_sse_event(acc, "message_start", _event) do
    record_protocol_error(acc, "Invalid message_start payload in Anthropic SSE stream")
  end

  defp handle_sse_event(acc, "content_block_start", %{
         "index" => index,
         "content_block" => block
       })
       when is_integer(index) and index >= 0 and is_map(block) do
    case validate_start_block(block) do
      {:ok, normalized} ->
        acc =
          acc
          |> put_in([Access.key(:content_blocks), index], normalized)
          |> Map.update!(:input_json_buffers, &Map.delete(&1, index))
          |> Map.update!(:open_tool_blocks, &Map.delete(&1, index))

        if tool_use_block?(normalized) do
          if normalized["type"] == "tool_use" do
            acc.on_event.(
              {:tool_call_delta,
               %{
                 id: normalized["id"],
                 index: index,
                 name: normalized["name"],
                 arguments_delta: ""
               }}
            )
          end

          %{acc | open_tool_blocks: Map.put(acc.open_tool_blocks, index, true)}
        else
          acc
        end

      :error ->
        record_protocol_error(
          acc,
          "Invalid content_block_start block at index #{index} in Anthropic SSE stream"
        )
    end
  end

  defp handle_sse_event(acc, "content_block_start", _event) do
    record_protocol_error(acc, "Invalid content_block_start payload in Anthropic SSE stream")
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "thinking_delta", "thinking" => text}
       })
       when is_integer(index) and index >= 0 and is_binary(text) do
    case Map.get(acc.content_blocks, index) do
      %{"type" => "thinking", "thinking" => existing} = current when is_binary(existing) ->
        acc.on_event.({:thinking_delta, text})
        put_in(acc.content_blocks[index], Map.put(current, "thinking", existing <> text))

      _mismatch ->
        record_protocol_error(acc, "Mismatched thinking_delta for content block #{index}")
    end
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "signature_delta", "signature" => sig}
       })
       when is_integer(index) and index >= 0 and is_binary(sig) do
    case Map.get(acc.content_blocks, index) do
      %{"type" => "thinking"} = current ->
        case Map.get(current, "signature") do
          nil ->
            put_in(acc.content_blocks[index], Map.put(current, "signature", sig))

          existing when is_binary(existing) ->
            put_in(acc.content_blocks[index], Map.put(current, "signature", existing <> sig))

          _invalid ->
            record_protocol_error(acc, "Invalid thinking block signature at index #{index}")
        end

      _mismatch ->
        record_protocol_error(acc, "Mismatched signature_delta for content block #{index}")
    end
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       })
       when is_integer(index) and index >= 0 and is_binary(text) do
    case Map.get(acc.content_blocks, index) do
      %{"type" => "text", "text" => existing} = current when is_binary(existing) ->
        # :text_delta on_event is emitted by Retry.call_provider/5 universally.
        acc.on_chunk.(text)
        put_in(acc.content_blocks[index], Map.put(current, "text", existing <> text))

      _mismatch ->
        record_protocol_error(acc, "Mismatched text_delta for content block #{index}")
    end
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       })
       when is_integer(index) and index >= 0 and is_binary(json) do
    current = Map.get(acc.content_blocks, index)

    cond do
      tool_use_block?(current) and Map.has_key?(acc.open_tool_blocks, index) ->
        if current["type"] == "tool_use" and json != "" do
          acc.on_event.(
            {:tool_call_delta,
             %{
               id: current["id"],
               index: index,
               name: current["name"],
               arguments_delta: json
             }}
          )
        end

        current_buffer = Map.get(acc.input_json_buffers, index, "")

        %{
          acc
          | input_json_buffers: Map.put(acc.input_json_buffers, index, current_buffer <> json)
        }

      tool_use_block?(current) ->
        record_protocol_error(
          acc,
          "Unexpected input_json_delta after content_block_stop for content block #{index}"
        )

      true ->
        record_protocol_error(acc, "Mismatched input_json_delta for content block #{index}")
    end
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => delta_type}
       })
       when is_integer(index) and index >= 0 and is_binary(delta_type) and
              delta_type not in @known_delta_types do
    # Forward-compatible: ignore unknown extension delta types (e.g. citations_delta).
    acc
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "delta" => %{"type" => delta_type}
       })
       when delta_type in @known_delta_types do
    record_protocol_error(acc, "Invalid #{delta_type} payload in Anthropic SSE stream")
  end

  defp handle_sse_event(acc, "content_block_delta", _event) do
    record_protocol_error(acc, "Invalid content_block_delta payload in Anthropic SSE stream")
  end

  defp handle_sse_event(acc, "content_block_stop", %{"index" => index})
       when is_integer(index) and index >= 0 do
    acc = %{acc | open_tool_blocks: Map.delete(acc.open_tool_blocks, index)}

    case Map.get(acc.input_json_buffers, index) do
      nil ->
        acc

      "" ->
        Map.put(acc, :input_json_buffers, Map.delete(acc.input_json_buffers, index))

      json_str when is_binary(json_str) ->
        current = Map.get(acc.content_blocks, index, %{})
        buffers = Map.delete(acc.input_json_buffers, index)
        name = Map.get(current, "name", "unknown")

        case HTTP.decode_tool_arguments(json_str, name) do
          {:ok, input} ->
            acc
            |> put_in([Access.key(:content_blocks), index], Map.put(current, "input", input))
            |> Map.put(:input_json_buffers, buffers)

          {:error, %Error{} = error} ->
            acc
            |> Map.put(:input_json_buffers, buffers)
            |> record_tool_json_error(error)
        end
    end
  end

  defp handle_sse_event(acc, "content_block_stop", _event) do
    record_protocol_error(acc, "Invalid content_block_stop payload in Anthropic SSE stream")
  end

  # The delta carries the message's final top-level fields (stop_reason,
  # stop_details, container). Its usage is cumulative, so it replaces the
  # message_start counts rather than adding to them.
  defp handle_sse_event(acc, "message_delta", %{"delta" => delta} = event) when is_map(delta) do
    case Map.get(event, "usage") do
      nil ->
        message = put_present(acc.message, delta)
        %{acc | message: message}

      event_usage when is_map(event_usage) ->
        usage = put_present(Map.get(acc.message, "usage", %{}), event_usage)
        message = acc.message |> put_present(delta) |> Map.put("usage", usage)
        %{acc | message: message}

      _invalid ->
        record_protocol_error(acc, "Invalid message_delta usage in Anthropic SSE stream")
    end
  end

  defp handle_sse_event(acc, "message_delta", _event) do
    record_protocol_error(acc, "Invalid message_delta payload in Anthropic SSE stream")
  end

  # Retry retries a retryable error only when no output was streamed yet.
  defp handle_sse_event(acc, "error", event), do: %{acc | error: Error.from_body(event)}

  defp handle_sse_event(acc, _event_type, _data), do: acc

  defp validate_start_block(%{"type" => "text", "text" => text} = block) when is_binary(text),
    do: {:ok, block}

  defp validate_start_block(%{"type" => "text"}), do: :error

  defp validate_start_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) do
    case Map.get(block, "signature") do
      sig when is_nil(sig) or is_binary(sig) -> {:ok, block}
      _invalid -> :error
    end
  end

  defp validate_start_block(%{"type" => "thinking"}), do: :error

  defp validate_start_block(%{"type" => type, "id" => id, "name" => name} = block)
       when is_binary(type) and is_binary(id) and id != "" and is_binary(name) and name != "" do
    if tool_use_block?(block) do
      case Map.fetch(block, "input") do
        :error -> {:ok, Map.put(block, "input", %{})}
        {:ok, input} when is_map(input) -> {:ok, block}
        {:ok, _invalid} -> :error
      end
    else
      {:ok, block}
    end
  end

  defp validate_start_block(block) do
    if tool_use_block?(block), do: :error, else: {:ok, block}
  end

  defp tool_use_block?(%{"type" => "tool_use"}), do: true

  defp tool_use_block?(%{"type" => type}) when is_binary(type),
    do: String.ends_with?(type, "_tool_use")

  defp tool_use_block?(_block), do: false

  defp record_protocol_error(acc, message),
    do: HTTP.record_sticky_error(acc, :protocol_error, message)

  defp record_malformed_error(acc, message),
    do: HTTP.record_sticky_error(acc, :malformed_reply, message)

  defp record_tool_json_error(%{tool_json_error: %Error{}} = acc, _error), do: acc

  defp record_tool_json_error(acc, %Error{} = error) do
    %{acc | tool_json_error: error}
  end

  # A null in a later event means "not reported here", not "reset".
  defp put_present(map, updates) do
    Map.merge(map, Map.reject(updates, fn {_key, value} -> is_nil(value) end))
  end

  defp assemble_raw_message(acc) do
    content =
      acc.content_blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} -> block end)

    Map.put(acc.message, "content", content)
  end
end
