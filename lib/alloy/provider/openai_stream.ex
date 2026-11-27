defmodule Alloy.Provider.OpenAIStream do
  @moduledoc """
  Shared OpenAI-format SSE stream parser.

  Used by `Alloy.Provider.OpenAICompat` for Chat Completions providers
  such as DeepSeek, Mistral, OpenRouter, Gemini, and Ollama.
  The native OpenAI and xAI providers use Responses API parsing instead.
  Each compatible provider calls `stream/5` or `stream/6` with its own URL,
  headers, and optional streaming options (`:on_event`, `:deadline`,
  `:cancel_token`); this module handles SSE parsing and response
  normalization.

  ## OpenAI Streaming Format

      data: {"choices":[{"index":0,"delta":{"content":"chunk"}}]}
      data: {"choices":[{"index":0,"delta":{"tool_calls":[...]}}]}
      data: [DONE]

  Text deltas are emitted via `on_chunk`. Reasoning deltas (`{:thinking_delta,
  text}`) and tool call argument deltas (`{:tool_call_delta, event}`) are
  emitted via `:on_event` while being accumulated into the final response,
  which has the same shape as `complete/3`.
  """

  alias Alloy.Message
  alias Alloy.Provider.{Error, HTTP}

  @doc """
  Execute a streaming request against an OpenAI-compatible endpoint.

  Returns `{:ok, completion_response()} | {:error, term()}`.
  """
  @spec stream(
          String.t(),
          [{String.t(), String.t()}],
          map(),
          (String.t() -> :ok),
          keyword(),
          keyword()
        ) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(url, headers, body, on_chunk, req_options, opts \\ [])
      when is_function(on_chunk, 1) do
    body =
      body
      |> Map.put("stream", true)
      |> put_stream_options()

    initial_acc = %{
      buffer: "",
      content: "",
      reasoning_content: "",
      content_thinking: "",
      refusal: "",
      tool_calls: %{},
      last_tool_call_index: nil,
      finish_reason: nil,
      done?: false,
      stream_error: nil,
      sticky_error: nil,
      usage: %{},
      on_chunk: on_chunk,
      on_event: Keyword.get(opts, :on_event, fn _ -> :ok end)
    }

    with {:ok, acc} <-
           HTTP.stream_sse(url, headers, body, initial_acc, &handle_event/2, req_options, opts) do
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
        stop_reason: stop_reason(finish_reason, content_blocks),
        messages: [%Message{role: :assistant, content: content_blocks}],
        usage: parse_usage(usage)
      },
      finish_reason
    )
  end

  @doc false
  # Shared with OpenAICompat so streaming and non-streaming Chat Completions
  # responses assemble assistant content blocks in the exact same order.
  @spec assemble_content_blocks(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [Message.content_block()]
        ) :: [Message.content_block()]
  def assemble_content_blocks(reasoning, content_thinking, text, refusal, tool_blocks) do
    reasoning_blocks =
      if reasoning != "", do: [%{type: "thinking", thinking: reasoning}], else: []

    content_thinking_blocks =
      if content_thinking != "",
        do: [%{type: "thinking", thinking: content_thinking, source: "content_part"}],
        else: []

    text_blocks = if text != "", do: [%{type: "text", text: text}], else: []

    refusal_blocks =
      if refusal != "", do: [%{type: "text", text: refusal, refusal: true}], else: []

    reasoning_blocks ++ content_thinking_blocks ++ text_blocks ++ refusal_blocks ++ tool_blocks
  end

  @doc false
  # Shared with OpenAICompat to build lenient placeholder tool_use blocks when
  # finish_reason is "length" so Turn abandons truncated calls cleanly.
  @spec build_truncated_tool_call(
          non_neg_integer(),
          term(),
          term(),
          term(),
          String.t() | nil
        ) :: Message.content_block()
  def build_truncated_tool_call(index, raw_id, raw_name, raw_args, thought_signature) do
    id =
      if is_binary(raw_id) and raw_id != "",
        do: raw_id,
        else: HTTP.truncated_tool_call_id(index)

    name = if is_binary(raw_name) and raw_name != "", do: raw_name, else: "truncated"

    block = %{
      type: "tool_use",
      id: id,
      name: name,
      input: HTTP.decode_truncated_arguments(raw_args)
    }

    if is_binary(thought_signature),
      do: Map.put(block, :thought_signature, thought_signature),
      else: block
  end

  @doc false
  # Shared optional string validator for Chat Completions fields
  # ("reasoning_content", "refusal").
  @spec validate_optional_string(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_optional_string(nil, _msg), do: {:ok, ""}
  def validate_optional_string(text, _msg) when is_binary(text), do: {:ok, text}
  def validate_optional_string(_invalid, msg), do: {:error, msg}

  @doc false
  # Extracts text and thinking text from Chat Completions content fields,
  # supporting both string content and structured part lists (e.g. Mistral
  # Magistral reasoning models) while rejecting malformed present shapes.
  @spec extract_content_parts(term()) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, String.t()}
  def extract_content_parts(nil), do: {:ok, "", "", ""}
  def extract_content_parts(text) when is_binary(text), do: {:ok, text, "", ""}

  def extract_content_parts(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, "", "", ""}, fn part, {:ok, text_acc, thinking_acc, ref_acc} ->
      case extract_content_part(part) do
        {:ok, :text, t} -> {:cont, {:ok, text_acc <> t, thinking_acc, ref_acc}}
        {:ok, :thinking, t} -> {:cont, {:ok, text_acc, thinking_acc <> t, ref_acc}}
        {:ok, :refusal, t} -> {:cont, {:ok, text_acc, thinking_acc, ref_acc <> t}}
        {:ok, :ignore} -> {:cont, {:ok, text_acc, thinking_acc, ref_acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def extract_content_parts(_invalid),
    do: {:error, "Invalid content in Chat Completions payload"}

  @doc false
  # Preserve Gemini 3.x thought signatures for multi-turn tool calls while
  # validating nested extension shapes instead of crashing get_in/2.
  @spec extract_thought_signature(map()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def extract_thought_signature(tc) when is_map(tc) do
    case Map.fetch(tc, "extra_content") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, extra} when is_map(extra) -> extract_google_thought_signature(extra)
      {:ok, _invalid} -> {:error, "Invalid extra_content in Chat Completions tool call"}
    end
  end

  defp extract_content_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: {:ok, :text, text}

  defp extract_content_part(%{"type" => "text"}),
    do: {:error, "Invalid text content part in Chat Completions payload"}

  defp extract_content_part(%{"type" => "refusal", "refusal" => text}) when is_binary(text),
    do: {:ok, :refusal, text}

  defp extract_content_part(%{"type" => "refusal"}),
    do: {:error, "Invalid refusal content part in Chat Completions payload"}

  defp extract_content_part(%{"type" => "thinking", "thinking" => text}) when is_binary(text),
    do: {:ok, :thinking, text}

  defp extract_content_part(%{"type" => "thinking", "text" => text}) when is_binary(text),
    do: {:ok, :thinking, text}

  defp extract_content_part(%{"type" => "thinking", "thinking" => nested}) when is_list(nested) do
    case extract_content_parts(nested) do
      {:ok, nested_text, nested_thinking, _nested_refusal} ->
        {:ok, :thinking, nested_text <> nested_thinking}

      {:error, _} ->
        {:error, "Invalid thinking content part in Chat Completions payload"}
    end
  end

  defp extract_content_part(%{"type" => "thinking"}),
    do: {:error, "Invalid thinking content part in Chat Completions payload"}

  # Forward-compatible: skip well-formed non-text/thinking parts (e.g. Mistral
  # reference, image_url, document_url, file, or audio chunks).
  defp extract_content_part(%{"type" => type}) when is_binary(type) and type != "",
    do: {:ok, :ignore}

  defp extract_content_part(_invalid),
    do: {:error, "Invalid content part in Chat Completions payload"}

  # Alloy.Usage follows Anthropic: input_tokens excludes cache reads and
  # writes, which have their own fields. OpenAI-style servers count both
  # inside prompt_tokens, so they are taken out here.
  defp parse_usage(usage) when is_map(usage) do
    details =
      case usage["prompt_tokens_details"] do
        map when is_map(map) -> map
        _ -> %{}
      end

    HTTP.cache_adjusted_usage(
      HTTP.non_neg_int(usage["prompt_tokens"]),
      HTTP.non_neg_int(usage["completion_tokens"]),
      HTTP.non_neg_int(details["cached_tokens"]),
      HTTP.non_neg_int(details["cache_write_tokens"])
    )
  end

  # Request usage by default, but preserve custom options and omit the field
  # entirely when the caller disables it for a less compatible endpoint.
  defp put_stream_options(%{"stream_options" => false} = body),
    do: Map.delete(body, "stream_options")

  defp put_stream_options(body),
    do: Map.put_new(body, "stream_options", %{"include_usage" => true})

  # ── SSE Event Handling ───────────────────────────────────────────────

  defp handle_event(acc, %{data: "[DONE]"}), do: %{acc | done?: true}

  defp handle_event(%{stream_error: %Error{}} = acc, _event), do: acc

  # Once a malformed chunk is recorded, stop emitting chunks while still
  # allowing an in-band API error chunk to take precedence.
  defp handle_event(%{sticky_error: %Error{}} = acc, %{data: data}) do
    case Jason.decode(data) do
      {:ok, %{"error" => error} = event} when is_map(error) or is_binary(error) ->
        %{acc | stream_error: Error.from_body(event)}

      _ ->
        acc
    end
  end

  defp handle_event(acc, %{data: data}) do
    if String.trim(data) == "" do
      acc
    else
      case Jason.decode(data) do
        {:ok, parsed} when is_map(parsed) ->
          process_event(acc, parsed)

        {:ok, _non_map} ->
          record_protocol_error(acc, "Malformed payload in Chat Completions SSE chunk")

        {:error, _} ->
          record_malformed_error(acc, "Malformed JSON in Chat Completions SSE chunk")
      end
    end
  end

  # Servers report failures after the 200 status line as an error chunk
  # (OpenRouter adds finish_reason "error" alongside it).
  defp process_event(acc, %{"error" => error} = event) when is_map(error) or is_binary(error) do
    %{acc | stream_error: Error.from_body(event)}
  end

  defp process_event(acc, %{"choices" => [choice | _]} = event) when is_map(choice) do
    case Map.fetch(choice, "delta") do
      {:ok, delta} when is_map(delta) ->
        apply_choice_delta(acc, delta, choice, event)

      :error ->
        acc
        |> put_choice_finish_reason(choice)
        |> put_event_usage(event)

      {:ok, _non_map} ->
        record_protocol_error(acc, "Invalid choice delta in Chat Completions SSE chunk")
    end
  end

  defp process_event(acc, %{"choices" => [_non_map | _]}) do
    record_protocol_error(acc, "Invalid choice in Chat Completions SSE chunk")
  end

  defp process_event(acc, %{"choices" => choices})
       when choices != nil and not is_list(choices) do
    record_protocol_error(acc, "Invalid choices in Chat Completions SSE chunk")
  end

  # Usage event: handles both empty choices (`"choices" => []`) and top-level
  # usage-only chunks; ordered before the catch-all after non-empty / invalid
  # choices clauses have already matched.
  defp process_event(acc, %{"usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  defp process_event(acc, _event), do: acc

  defp apply_choice_delta(acc, delta, choice, event) do
    # Validate delta text fields and tool_calls before emitting text deltas so
    # a malformed field on the same chunk cannot leak text before failing.
    with {:ok, text, content_thinking, content_refusal} <-
           extract_content_parts(Map.get(delta, "content")),
         {:ok, reasoning} <-
           validate_optional_string(
             Map.get(delta, "reasoning_content"),
             "Invalid delta reasoning_content in Chat Completions SSE chunk"
           ),
         {:ok, refusal} <-
           validate_optional_string(
             Map.get(delta, "refusal"),
             "Invalid delta refusal in Chat Completions SSE chunk"
           ) do
      {acc, tool_events} = accumulate_tool_calls(acc, Map.get(delta, "tool_calls", []))
      combined_refusal = content_refusal <> refusal

      if acc.sticky_error do
        acc
      else
        if reasoning != "", do: acc.on_event.({:thinking_delta, reasoning})
        if content_thinking != "", do: acc.on_event.({:thinking_delta, content_thinking})

        acc =
          if text != "" do
            acc.on_chunk.(text)
            %{acc | content: acc.content <> text}
          else
            acc
          end

        Enum.each(tool_events, fn ev -> acc.on_event.({:tool_call_delta, ev}) end)

        acc =
          if reasoning != "",
            do: %{acc | reasoning_content: acc.reasoning_content <> reasoning},
            else: acc

        acc =
          if content_thinking != "",
            do: %{acc | content_thinking: acc.content_thinking <> content_thinking},
            else: acc

        acc =
          if combined_refusal != "",
            do: %{acc | refusal: acc.refusal <> combined_refusal},
            else: acc

        acc
        |> put_choice_finish_reason(choice)
        |> put_event_usage(event)
      end
    else
      {:error, message} -> record_protocol_error(acc, message)
    end
  end

  defp put_choice_finish_reason(acc, %{"finish_reason" => reason}) when is_binary(reason),
    do: %{acc | finish_reason: reason}

  defp put_choice_finish_reason(acc, _choice), do: acc

  defp put_event_usage(acc, %{"usage" => usage}) when is_map(usage), do: %{acc | usage: usage}
  defp put_event_usage(acc, _event), do: acc

  # ── Tool Call Accumulation ───────────────────────────────────────────

  # DeepInfra sends "tool_calls": null on chunks without a call.
  defp accumulate_tool_calls(acc, nil), do: {acc, []}
  defp accumulate_tool_calls(acc, []), do: {acc, []}

  defp accumulate_tool_calls(acc, tool_call_deltas) when is_list(tool_call_deltas) do
    {acc, events_rev} =
      Enum.reduce(tool_call_deltas, {acc, []}, &accumulate_tool_call_delta/2)

    {acc, Enum.reverse(events_rev)}
  end

  defp accumulate_tool_calls(acc, _invalid) do
    {record_protocol_error(acc, "Invalid tool_calls delta in Chat Completions SSE chunk"), []}
  end

  defp extract_google_thought_signature(extra) do
    case Map.fetch(extra, "google") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{"thought_signature" => sig}} when is_binary(sig) and sig != "" ->
        {:ok, sig}

      {:ok, %{"thought_signature" => sig}} when is_nil(sig) or sig == "" ->
        {:ok, nil}

      {:ok, %{"thought_signature" => _invalid}} ->
        {:error, "Invalid extra_content.google.thought_signature in Chat Completions tool call"}

      {:ok, google} when is_map(google) ->
        {:ok, nil}

      {:ok, _invalid} ->
        {:error, "Invalid extra_content.google in Chat Completions tool call"}
    end
  end

  defp accumulate_tool_call_delta(tc_delta, {acc, events}) when is_map(tc_delta) do
    case resolve_tool_call_index(tc_delta, acc) do
      {:ok, index} ->
        existing =
          Map.get(acc.tool_calls, index, %{
            id: nil,
            name: nil,
            arguments_buffer: "",
            thought_signature: nil,
            emitted_header?: false
          })

        with {:ok, existing} <-
               merge_string_field(
                 existing,
                 :id,
                 Map.fetch(tc_delta, "id"),
                 "tool call id in Chat Completions SSE chunk"
               ),
             {:ok, sig} <- extract_thought_signature(tc_delta),
             with_sig = if(sig, do: %{existing | thought_signature: sig}, else: existing),
             {:ok, updated, args_delta} <-
               merge_function_delta(with_sig, Map.fetch(tc_delta, "function")) do
          {updated, next_events} =
            maybe_emit_tool_call_delta(updated, index, args_delta, events)

          next_acc = %{
            acc
            | tool_calls: Map.put(acc.tool_calls, index, updated),
              last_tool_call_index: index
          }

          {next_acc, next_events}
        else
          {:error, message} -> {record_protocol_error(acc, message), events}
        end

      {:error, message} ->
        {record_protocol_error(acc, message), events}
    end
  end

  defp accumulate_tool_call_delta(_invalid, {acc, events}) do
    {record_protocol_error(acc, "Invalid tool call delta in Chat Completions SSE chunk"), events}
  end

  # Some providers (DeepInfra) repeat "id": null on every later chunk of the
  # same call; only a real non-empty string may set a field, while non-string
  # or conflicting values fail fast.
  defp merge_string_field(existing, _field, :error, _label), do: {:ok, existing}
  defp merge_string_field(existing, _field, {:ok, nil}, _label), do: {:ok, existing}
  defp merge_string_field(existing, _field, {:ok, ""}, _label), do: {:ok, existing}

  defp merge_string_field(existing, field, {:ok, value}, label) when is_binary(value) do
    case Map.fetch!(existing, field) do
      current when is_binary(current) and current != "" and current != value ->
        {:error, "Conflicting #{label}"}

      _ ->
        {:ok, Map.put(existing, field, value)}
    end
  end

  defp merge_string_field(_existing, _field, {:ok, _invalid}, label),
    do: {:error, "Invalid #{label}"}

  defp maybe_emit_tool_call_delta(%{id: id, name: name} = updated, _index, _args_delta, events)
       when not is_binary(id) or id == "" or not is_binary(name) or name == "" do
    {updated, events}
  end

  defp maybe_emit_tool_call_delta(
         %{emitted_header?: false} = updated,
         index,
         _args_delta,
         events
       ) do
    event = %{
      id: updated.id,
      index: index,
      name: updated.name,
      arguments_delta: updated.arguments_buffer
    }

    {%{updated | emitted_header?: true}, [event | events]}
  end

  defp maybe_emit_tool_call_delta(updated, index, args_delta, events) when args_delta != "" do
    event = %{
      id: updated.id,
      index: index,
      name: updated.name,
      arguments_delta: args_delta
    }

    {updated, [event | events]}
  end

  defp maybe_emit_tool_call_delta(updated, _index, "", events), do: {updated, events}

  # Some Chat Completions-compatible servers (notably Gemini's OpenAI-compat
  # endpoint) omit "index" on streamed tool call deltas. Reuse an existing
  # slot when the same non-empty "id" repeats across fragments, allocate a
  # fresh slot above all existing indices for an unseen "id" (safe with sparse
  # explicit indices), and extend the most recently touched call on id-less
  # deltas, while rejecting explicit non-integer indices.
  defp resolve_tool_call_index(tc_delta, acc) do
    case Map.fetch(tc_delta, "index") do
      {:ok, index} when is_integer(index) and index >= 0 ->
        {:ok, index}

      missing when missing in [:error, {:ok, nil}] ->
        case tc_delta do
          %{"id" => id} when is_binary(id) and id != "" ->
            existing_index =
              Enum.find_value(acc.tool_calls, fn
                {i, %{id: ^id}} -> i
                _ -> nil
              end)

            {:ok, existing_index || next_unused_index(acc.tool_calls)}

          _ ->
            {:ok, acc.last_tool_call_index || next_unused_index(acc.tool_calls)}
        end

      {:ok, _invalid} ->
        {:error, "Invalid tool call index in Chat Completions SSE chunk"}
    end
  end

  defp next_unused_index(tool_calls) when map_size(tool_calls) == 0, do: 0
  defp next_unused_index(tool_calls), do: (tool_calls |> Map.keys() |> Enum.max()) + 1

  defp merge_function_delta(existing, :error), do: {:ok, existing, ""}
  defp merge_function_delta(existing, {:ok, nil}), do: {:ok, existing, ""}

  defp merge_function_delta(existing, {:ok, func}) when is_map(func) do
    with {:ok, with_name} <-
           merge_string_field(
             existing,
             :name,
             Map.fetch(func, "name"),
             "function name in Chat Completions tool call delta"
           ) do
      merge_function_args(with_name, Map.fetch(func, "arguments"))
    end
  end

  defp merge_function_delta(_existing, {:ok, _invalid}),
    do: {:error, "Invalid function payload in Chat Completions tool call delta"}

  defp merge_function_args(existing, :error), do: {:ok, existing, ""}

  defp merge_function_args(existing, {:ok, args}) when is_binary(args),
    do: {:ok, %{existing | arguments_buffer: existing.arguments_buffer <> args}, args}

  defp merge_function_args(existing, {:ok, _invalid}) do
    name = existing.name || "unknown"
    {:error, "Invalid tool call arguments delta for #{name}"}
  end

  defp record_malformed_error(acc, message),
    do: HTTP.record_sticky_error(acc, :malformed_reply, message)

  defp record_protocol_error(acc, message),
    do: HTTP.record_sticky_error(acc, :protocol_error, message)

  # ── Response Building ────────────────────────────────────────────────

  defp build_response(%{stream_error: %Error{} = error}), do: {:error, error}
  defp build_response(%{sticky_error: %Error{} = error}), do: {:error, error}

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
    case build_streamed_tool_blocks(acc.tool_calls, acc.finish_reason) do
      {:ok, tool_blocks} ->
        blocks =
          assemble_content_blocks(
            acc.reasoning_content,
            acc.content_thinking,
            acc.content,
            acc.refusal,
            tool_blocks
          )

        {:ok, completion_response(blocks, acc.finish_reason, acc.usage)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Refused output is discarded by the loop; do not fail with a retryable
  # :malformed_reply on partial tool calls cut off by content filtering.
  defp build_streamed_tool_blocks(_tool_calls, "content_filter"), do: {:ok, []}

  # Under finish_reason: "length", tool-call JSON (or id/name) may be cut off
  # mid-stream. Keep the truncated tool_use block(s) with input: %{} so Turn
  # sees stop_reason: :max_tokens and abandons them cleanly with its max_tokens
  # error instead of retrying a deterministic truncation.
  defp build_streamed_tool_blocks(tool_calls, "length") do
    blocks =
      tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {index, tc} ->
        build_truncated_tool_call(
          index,
          tc.id,
          tc.name,
          tc.arguments_buffer,
          tc.thought_signature
        )
      end)

    {:ok, blocks}
  end

  defp build_streamed_tool_blocks(tool_calls, _finish_reason) do
    tool_calls
    |> Enum.sort_by(fn {index, _} -> index end)
    |> HTTP.map_ok(fn {_index, tc} -> decode_streamed_tool_block(tc) end)
  end

  defp decode_streamed_tool_block(%{id: id, name: name} = tc)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    # Treat empty buffer as an empty-input tool call (no-arg tools send "" not "{}").
    # Treat non-empty invalid JSON or non-object JSON as :malformed_reply.
    with {:ok, input} <-
           HTTP.decode_tool_arguments(
             tc.arguments_buffer,
             name,
             message_prefix: "Invalid tool call JSON for",
             include_reason: true
           ) do
      block = %{type: "tool_use", id: id, name: name, input: input}

      {:ok,
       if(is_binary(tc.thought_signature),
         do: Map.put(block, :thought_signature, tc.thought_signature),
         else: block
       )}
    end
  end

  defp decode_streamed_tool_block(_tc) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Malformed streamed tool call: missing id or function name"
     }}
  end

  defp stop_reason("length", _blocks), do: :max_tokens
  defp stop_reason("content_filter", _blocks), do: :refusal
  defp stop_reason(reason, _blocks) when reason in ["tool_calls", "function_call"], do: :tool_use

  # Some Chat Completions-compatible servers (such as Gemini's OpenAI-compat
  # endpoint and Ollama) emit "stop", nil, or a provider-specific reason
  # alongside tool calls; treat present tool calls as :tool_use unless the
  # finish reason is "length" or "content_filter".
  defp stop_reason(_reason, blocks) do
    if Enum.any?(blocks, &match?(%{type: "tool_use"}, &1)), do: :tool_use, else: :end_turn
  end

  defp put_stop_details(response, "content_filter") do
    Map.put(response, :response_metadata, %{stop_details: %{"finish_reason" => "content_filter"}})
  end

  defp put_stop_details(response, _finish_reason), do: response
end
