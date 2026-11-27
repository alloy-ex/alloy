defmodule Alloy.Provider.OpenAI.Stream do
  @moduledoc false
  # OpenAI Responses API SSE stream parser and function-call delta/reconciliation
  # state machine. Shared by `Alloy.Provider.OpenAI` (and `Alloy.Provider.XAI`).

  alias Alloy.Provider.{Error, HTTP, OpenAI}
  alias Alloy.Provider.OpenAI.JSONPrefix

  @terminal_events ["response.completed", "response.incomplete", "response.failed"]

  # Executes a streaming Responses API request, emitting text chunks via
  # `on_chunk` and reasoning / tool-call deltas via `config[:on_event]`.
  @spec stream(
          String.t(),
          HTTP.headers(),
          map(),
          (String.t() -> :ok),
          OpenAI.config()
        ) :: {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(url, headers, body, on_chunk, config) when is_function(on_chunk, 1) do
    has_on_event? = is_function(Map.get(config, :on_event), 1)

    initial_acc = %{
      buffer: "",
      response: nil,
      stream_error: nil,
      sticky_error: nil,
      function_calls: %{},
      pending_function_deltas: %{},
      pending_delta_seq: 0,
      has_on_event?: has_on_event?,
      on_chunk: on_chunk,
      on_event: if(has_on_event?, do: config.on_event, else: fn _ -> :ok end)
    }

    with {:ok, acc} <-
           HTTP.stream_sse(
             url,
             headers,
             Map.put(body, "stream", true),
             initial_acc,
             &handle_stream_event/2,
             Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ) do
      build_stream_response(acc)
    end
  end

  # --- SSE Event Dispatch ---

  defp handle_stream_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_stream_event(%{stream_error: %Error{}} = acc, _event), do: acc

  # Once a malformed chunk is recorded, suppress text deltas while still
  # accepting explicit API errors ("error" / "response.failed") so they take
  # precedence over malformed sibling chunks.
  defp handle_stream_event(%{sticky_error: %Error{}} = acc, %{event: event_name, data: data}) do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) ->
        event_type = event_name || Map.get(parsed, "type")
        handle_post_malformed_event(acc, event_type, parsed)

      _ ->
        acc
    end
  end

  defp handle_stream_event(acc, %{event: event_name, data: data}) do
    if String.trim(data) == "" do
      acc
    else
      case Jason.decode(data) do
        {:ok, parsed} when is_map(parsed) ->
          event_type = event_name || Map.get(parsed, "type")
          process_stream_event(acc, event_type, parsed)

        {:ok, _non_map} ->
          HTTP.record_sticky_error(acc, :protocol_error, "Malformed payload in OpenAI SSE event")

        {:error, _} ->
          HTTP.record_sticky_error(acc, :malformed_reply, "Malformed JSON in OpenAI SSE event")
      end
    end
  end

  defp handle_post_malformed_event(acc, "error", payload),
    do: process_stream_event(acc, "error", payload)

  defp handle_post_malformed_event(
         acc,
         "response.failed",
         %{"response" => %{"error" => _}} = payload
       ),
       do: %{acc | stream_error: Error.from_body(payload["response"])}

  defp handle_post_malformed_event(acc, _event_type, _payload), do: acc

  defp process_stream_event(acc, "response.output_text.delta", %{"delta" => delta})
       when is_binary(delta) and delta != "" do
    acc.on_chunk.(delta)
    acc
  end

  defp process_stream_event(acc, event_type, %{"delta" => delta})
       when event_type in [
              "response.reasoning_summary_text.delta",
              "response.reasoning_text.delta"
            ] and
              is_binary(delta) and delta != "" do
    acc.on_event.({:thinking_delta, delta})
    acc
  end

  defp process_stream_event(
         acc,
         event_type,
         %{"item" => %{"type" => "function_call"} = item} = payload
       )
       when event_type in ["response.output_item.added", "response.output_item.done"] do
    register_function_call_item(acc, item, Map.get(payload, "output_index"), event_type)
  end

  defp process_stream_event(
         acc,
         "response.function_call_arguments.delta",
         %{"delta" => delta} = payload
       )
       when is_binary(delta) and delta != "" do
    raw_index = Map.get(payload, "output_index")

    if valid_optional_output_index?(raw_index) do
      handle_function_call_args_delta(acc, payload, raw_index, delta)
    else
      acc
    end
  end

  # Every terminal event carries the whole response, and OpenAI.parse_response/1
  # reads its status, so completed, incomplete and failed share one path.
  defp process_stream_event(acc, event_type, %{"response" => response})
       when event_type in @terminal_events and is_map(response) do
    %{acc | response: response}
  end

  # The documented event is flat ({"type": "error", "code", "message"});
  # some compatible servers nest the details under "error".
  defp process_stream_event(acc, "error", %{"error" => %{}} = payload) do
    %{acc | stream_error: Error.from_body(payload)}
  end

  defp process_stream_event(acc, "error", payload) do
    %{acc | stream_error: Error.from_body(%{"error" => payload})}
  end

  defp process_stream_event(acc, _event_type, _payload), do: acc

  # --- Function Call Registration & Argument Reconciliation ---

  defp register_function_call_item(acc, item, index, event_type) do
    raw_call_id = Map.get(item, "call_id")
    item_id = item["id"]
    name = item["name"]

    # During streaming (output_item.added / output_item.done), require the true
    # call_id so consumers never receive item_id when call_id arrives later.
    # Terminal response.completed fallback to item["id"] happens in
    # plan_completed_function_call/4 (matching OpenAI response parsing).
    call_id = raw_call_id
    existing = lookup_function_call_item(acc.function_calls, item_id, call_id, index)

    cond do
      existing == :rejected ->
        acc

      event_type == "response.output_item.added" and not valid_added_item_args?(item) ->
        mark_rejected_function_call(acc, item_id, index)

      valid_function_call_header?(index, call_id, name) ->
        call_info = %{
          existing: existing,
          item: item,
          item_id: item_id,
          call_id: call_id,
          index: index,
          name: name
        }

        {:ok, updated, events} =
          plan_and_store_function_call(acc, call_info, event_type, false)

        Enum.each(events, acc.on_event)
        updated

      deferred_call_id_header?(event_type, index, raw_call_id, item_id, name) ->
        # Legitimate partial header waiting for call_id: preserve any initial
        # arguments prefix on .added and buffer deltas until call_id resolves.
        maybe_buffer_added_args(acc, event_type, item, item_id, index)

      event_type == "response.output_item.added" ->
        # Record rejected headers so subsequent argument deltas for the same
        # item_id or output_index cannot bypass suppression and trip chunks_emitted?.
        mark_rejected_function_call(acc, item_id, index)

      true ->
        acc
    end
  end

  defp plan_and_store_function_call(acc, call_info, event_type, strict?) do
    %{
      existing: existing,
      item: item,
      item_id: item_id,
      call_id: call_id,
      index: index,
      name: name
    } = call_info

    header_emitted? = match?(%{id: ^call_id, name: ^name}, existing)
    emitted_args = if is_map(existing), do: Map.get(existing, :emitted_args, ""), else: ""
    stable_index = if is_map(existing), do: Map.get(existing, :index, index), else: index

    cond do
      conflicting_existing_header?(existing, call_id, name) ->
        if strict? do
          {:error,
           %Error{
             kind: :malformed_reply,
             message: "Streamed tool call header for #{name} does not match completed call"
           }}
        else
          {:ok, acc, []}
        end

      event_type == "response.output_item.done" and not header_emitted? and
          invalid_whole_item_args?(item) ->
        # Defer malformed whole-item calls so response.completed / parse_response
        # can fail with :malformed_reply before chunks_emitted? is flipped.
        {:ok, acc, []}

      true ->
        base_meta = %{id: call_id, index: stable_index, name: name}

        {pending_deltas, next_pending} =
          pop_pending_deltas(acc.pending_function_deltas, item_id, stable_index)

        plan_opts = %{
          header_emitted?: header_emitted?,
          event_type: event_type,
          emitted_args: emitted_args,
          strict?: strict?
        }

        case plan_call_events(base_meta, item, pending_deltas, plan_opts) do
          {:ok, events, next_emitted_args} ->
            existing_item_ids =
              if is_map(existing),
                do: Map.get(existing, :item_ids, MapSet.new()),
                else: MapSet.new()

            next_item_ids =
              if is_binary(item_id) and item_id != "",
                do: MapSet.put(existing_item_ids, item_id),
                else: existing_item_ids

            meta =
              Map.merge(base_meta, %{
                item_ids: next_item_ids,
                emitted_args: next_emitted_args
              })

            function_calls =
              acc.function_calls
              |> Map.put({:call_id, call_id}, meta)
              |> maybe_put_call_alias(item_id, call_id)
              |> Map.put({:index, stable_index}, {:alias, call_id})

            {:ok, %{acc | function_calls: function_calls, pending_function_deltas: next_pending},
             events}

          :conflict ->
            {:error,
             %Error{
               kind: :malformed_reply,
               message:
                 "Streamed tool call arguments for #{name} do not match completed arguments"
             }}
        end
    end
  end

  defp conflicting_existing_header?(%{id: id, name: existing_name}, call_id, name) do
    id != call_id or existing_name != name
  end

  defp conflicting_existing_header?(_existing, _call_id, _name), do: false

  defp plan_call_events(base_meta, item, pending_deltas, plan_opts) do
    %{
      header_emitted?: header_emitted?,
      event_type: event_type,
      emitted_args: emitted_args,
      strict?: strict?
    } = plan_opts

    header_events =
      if header_emitted?,
        do: [],
        else: [{:tool_call_delta, Map.put(base_meta, :arguments_delta, "")}]

    {pending_events, emitted_after_pending} =
      plan_reconciled_pending_args(base_meta, pending_deltas, item, event_type, emitted_args)

    case reconcile_whole_item_args(item, event_type, emitted_after_pending, strict?) do
      {:ok, "", next_emitted} ->
        {:ok, header_events ++ pending_events, next_emitted}

      {:ok, suffix, next_emitted} ->
        suffix_event = {:tool_call_delta, Map.put(base_meta, :arguments_delta, suffix)}
        {:ok, header_events ++ pending_events ++ [suffix_event], next_emitted}

      :conflict ->
        :conflict
    end
  end

  defp valid_added_item_args?(item) do
    case Map.fetch(item, "arguments") do
      :error -> true
      {:ok, args} when is_binary(args) or is_map(args) -> true
      {:ok, _invalid} -> false
    end
  end

  defp invalid_whole_item_args?(item) do
    not match?({:ok, _}, decode_item_arguments(item))
  end

  defp decode_item_arguments(item) do
    name =
      case Map.get(item, "name") do
        value when is_binary(value) -> value
        _ -> "truncated"
      end

    HTTP.decode_tool_arguments(Map.get(item, "arguments", ""), name)
  end

  defp maybe_buffer_added_args(acc, "response.output_item.added", item, item_id, index) do
    case item_args_delta(item, "response.output_item.added") do
      "" -> acc
      prefix -> buffer_pending_delta(acc, item_id, index, prefix)
    end
  end

  defp maybe_buffer_added_args(acc, _event_type, _item, _item_id, _index), do: acc

  defp reconcile_whole_item_args(item, "response.output_item.added", emitted_args, _strict?) do
    reconcile_prefix_only(item_args_delta(item, "response.output_item.added"), emitted_args)
  end

  defp reconcile_whole_item_args(item, event_type, emitted_args, strict?)
       when event_type in ["response.output_item.done", "response.completed"] do
    case decode_item_arguments(item) do
      {:ok, expected_input} ->
        args = item_args_delta(item, event_type)

        case reconcile_decoded_args(emitted_args, args, expected_input) do
          {:ok, suffix, next_emitted} ->
            {:ok, suffix, next_emitted}

          :conflict when strict? ->
            :conflict

          :conflict ->
            {:ok, "", emitted_args}
        end

      {:error, _} ->
        reconcile_prefix_only(item_args_delta(item, event_type), emitted_args)
    end
  end

  defp reconcile_whole_item_args(_item, _event_type, emitted_args, _strict?),
    do: {:ok, "", emitted_args}

  defp reconcile_prefix_only(args, emitted_args) do
    cond do
      args == "" or args == emitted_args ->
        {:ok, "", emitted_args}

      String.starts_with?(args, emitted_args) ->
        prefix_len = byte_size(emitted_args)
        suffix = binary_part(args, prefix_len, byte_size(args) - prefix_len)
        {:ok, suffix, args}

      true ->
        {:ok, "", emitted_args}
    end
  end

  defp reconcile_decoded_args("", "", _expected_input), do: {:ok, "", ""}
  defp reconcile_decoded_args("", args, _expected_input), do: {:ok, args, args}
  defp reconcile_decoded_args(emitted, emitted, _expected_input), do: {:ok, "", emitted}

  defp reconcile_decoded_args(emitted, args, expected_input) do
    cond do
      args != "" and String.starts_with?(args, emitted) ->
        prefix_len = byte_size(emitted)
        suffix = binary_part(args, prefix_len, byte_size(args) - prefix_len)
        {:ok, suffix, args}

      json_equal?(emitted, expected_input) ->
        {:ok, "", emitted}

      true ->
        JSONPrefix.reconcile(emitted, expected_input)
    end
  end

  defp json_equal?(json, expected) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded == expected
      {:error, _} -> false
    end
  end

  defp item_args_delta(item, event_type) do
    case Map.get(item, "arguments") do
      args when is_binary(args) and args != "" ->
        args

      args when is_map(args) and map_size(args) > 0 ->
        Jason.encode!(args)

      args when is_map(args) and event_type != "response.output_item.added" ->
        Jason.encode!(args)

      _ ->
        ""
    end
  end

  defp deferred_call_id_header?(event_type, index, nil, item_id, name)
       when event_type in ["response.output_item.added", "response.output_item.done"] do
    is_integer(index) and index >= 0 and is_binary(item_id) and item_id != "" and
      is_binary(name) and name != ""
  end

  defp deferred_call_id_header?(_event_type, _index, _raw_call_id, _item_id, _name), do: false

  defp valid_function_call_header?(index, call_id, name) do
    is_integer(index) and index >= 0 and is_binary(call_id) and call_id != "" and
      is_binary(name) and name != ""
  end

  defp mark_rejected_function_call(acc, item_id, index) do
    function_calls =
      acc.function_calls
      |> maybe_put_call_meta(item_id, :rejected)
      |> then(fn map ->
        if is_integer(index) and index >= 0,
          do: Map.put(map, {:index, index}, :rejected),
          else: map
      end)

    {_dropped, next_pending} = pop_pending_deltas(acc.pending_function_deltas, item_id, index)
    %{acc | function_calls: function_calls, pending_function_deltas: next_pending}
  end

  defp lookup_function_call_item(calls, item_id, call_id, index) do
    resolve_call_entry(calls, maybe_get_by_id(calls, item_id)) ||
      resolve_call_entry(calls, maybe_get_by_call_id(calls, call_id)) ||
      resolve_call_entry(calls, lookup_call_by_index(calls, index))
  end

  defp lookup_function_call_meta(calls, item_id, index) do
    case resolve_call_entry(calls, maybe_get_by_id(calls, item_id)) do
      nil ->
        case resolve_call_entry(calls, lookup_call_by_index(calls, index)) do
          %{item_ids: item_ids} = found ->
            if is_binary(item_id) and item_id != "" and MapSet.size(item_ids) > 0 and
                 not MapSet.member?(item_ids, item_id) do
              nil
            else
              found
            end

          other ->
            other
        end

      found ->
        found
    end
  end

  defp resolve_call_entry(calls, {:alias, call_id}), do: Map.get(calls, {:call_id, call_id})
  defp resolve_call_entry(_calls, entry), do: entry

  defp maybe_get_by_id(calls, id) when is_binary(id) and id != "", do: Map.get(calls, id)
  defp maybe_get_by_id(_calls, _id), do: nil

  defp maybe_get_by_call_id(calls, call_id) when is_binary(call_id) and call_id != "",
    do: Map.get(calls, {:call_id, call_id})

  defp maybe_get_by_call_id(_calls, _call_id), do: nil

  defp maybe_put_call_alias(map, id, call_id) when is_binary(id) and id != "",
    do: Map.put(map, id, {:alias, call_id})

  defp maybe_put_call_alias(map, _id, _call_id), do: map

  defp maybe_put_call_meta(map, id, meta) when is_binary(id) and id != "",
    do: Map.put(map, id, meta)

  defp maybe_put_call_meta(map, _id, _meta), do: map

  defp lookup_call_by_index(calls, index) when is_integer(index),
    do: Map.get(calls, {:index, index})

  defp lookup_call_by_index(_calls, _index), do: nil

  defp valid_optional_output_index?(nil), do: true
  defp valid_optional_output_index?(index) when is_integer(index) and index >= 0, do: true
  defp valid_optional_output_index?(_other), do: false

  defp handle_function_call_args_delta(acc, payload, raw_index, delta) do
    item_id = payload["item_id"]

    case lookup_function_call_meta(acc.function_calls, item_id, raw_index) do
      :rejected ->
        acc

      %{id: id, index: idx, name: name} = meta ->
        if is_nil(raw_index) or raw_index == idx do
          acc.on_event.(
            {:tool_call_delta,
             %{
               id: id,
               index: idx,
               name: name,
               arguments_delta: delta
             }}
          )

          updated_meta = %{meta | emitted_args: Map.get(meta, :emitted_args, "") <> delta}
          function_calls = Map.put(acc.function_calls, {:call_id, id}, updated_meta)

          %{acc | function_calls: function_calls}
        else
          acc
        end

      nil ->
        buffer_pending_delta(acc, item_id, raw_index, delta)
    end
  end

  defp buffer_pending_delta(acc, item_id, raw_index, delta) do
    key =
      cond do
        is_binary(item_id) and item_id != "" -> item_id
        is_integer(raw_index) and raw_index >= 0 -> {:index, raw_index}
        true -> nil
      end

    if is_nil(key) do
      acc
    else
      seq = acc.pending_delta_seq + 1
      entry = {seq, raw_index, delta}
      updated = Map.update(acc.pending_function_deltas, key, [entry], &[entry | &1])
      %{acc | pending_function_deltas: updated, pending_delta_seq: seq}
    end
  end

  defp pop_pending_deltas(pending, item_id, index) do
    {by_id, pending} =
      if is_binary(item_id) and item_id != "",
        do: Map.pop(pending, item_id, []),
        else: {[], pending}

    {by_index, pending} =
      if is_integer(index) and index >= 0,
        do: Map.pop(pending, {:index, index}, []),
        else: {[], pending}

    ordered =
      (by_id ++ by_index)
      |> Enum.sort_by(fn {seq, _raw_index, _delta} -> seq end)
      |> Enum.map(fn {_seq, raw_index, delta} -> {raw_index, delta} end)

    {ordered, pending}
  end

  # When nothing has been emitted yet and a terminal/done item carries the
  # authoritative complete arguments, only emit buffered fragments if they are
  # a byte-exact prefix of the authoritative arguments; otherwise discard the
  # inconsistent buffered data so reconcile_whole_item_args emits the exact
  # validated arguments matching the final tool input.
  defp plan_reconciled_pending_args(meta, pending_deltas, item, event_type, emitted) do
    matching =
      Enum.filter(pending_deltas, fn {raw_index, _delta} ->
        is_nil(raw_index) or raw_index == meta.index
      end)

    joined = Enum.map_join(matching, fn {_raw_index, delta} -> delta end)

    if emitted == "" and event_type in ["response.output_item.done", "response.completed"] and
         discard_inconsistent_pending?(item, event_type, joined) do
      {[], ""}
    else
      {to_delta_events(meta, matching), emitted <> joined}
    end
  end

  defp discard_inconsistent_pending?(item, event_type, buffered) do
    whole_args = item_args_delta(item, event_type)
    whole_args != "" and not String.starts_with?(whole_args, buffered)
  end

  defp to_delta_events(meta, deltas) do
    Enum.map(deltas, fn {_raw_index, delta} ->
      {:tool_call_delta,
       %{
         id: meta.id,
         index: meta.index,
         name: meta.name,
         arguments_delta: delta
       }}
    end)
  end

  # --- Terminal Flush & Response Building ---

  defp flush_pending_from_response(%{has_on_event?: false}, _response), do: :ok

  defp flush_pending_from_response(acc, %{"output" => output} = response) when is_list(output) do
    case OpenAI.parse_output_mode(response) do
      :refusal ->
        :ok

      mode ->
        strict? = mode == :normal
        result = reduce_completed_output(output, acc, strict?)
        finish_completed_flush(result, acc, strict?)
    end
  end

  defp flush_pending_from_response(acc, response) when is_map(response) do
    if OpenAI.parse_output_mode(response) == :normal do
      check_missing_emitted_calls(acc.function_calls, MapSet.new())
    else
      :ok
    end
  end

  defp reduce_completed_output(output, acc, strict?) do
    output
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, acc, [], MapSet.new()}, fn
      {%{"type" => "function_call"} = item, idx}, {:ok, current, rev_events, seen} ->
        case plan_completed_function_call(current, item, idx, strict?) do
          {:ok, updated, events, seen_call_id} ->
            next_seen = if seen_call_id, do: MapSet.put(seen, seen_call_id), else: seen
            {:cont, {:ok, updated, Enum.reverse(events, rev_events), next_seen}}

          {:error, _} = err ->
            {:halt, err}
        end

      _other, state ->
        {:cont, state}
    end)
  end

  defp finish_completed_flush({:error, _} = err, _acc, _strict?), do: err

  defp finish_completed_flush({:ok, _final_acc, rev_events, seen}, acc, true) do
    case check_missing_emitted_calls(acc.function_calls, seen) do
      :ok ->
        rev_events |> Enum.reverse() |> Enum.each(acc.on_event)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp finish_completed_flush({:ok, _final_acc, rev_events, _seen}, acc, false) do
    rev_events |> Enum.reverse() |> Enum.each(acc.on_event)
    :ok
  end

  defp check_missing_emitted_calls(function_calls, seen_call_ids) do
    case Enum.find_value(function_calls, fn
           {{:call_id, call_id}, %{}} ->
             if MapSet.member?(seen_call_ids, call_id), do: nil, else: call_id

           _other ->
             nil
         end) do
      nil ->
        :ok

      missing_id ->
        {:error,
         %Error{
           kind: :malformed_reply,
           message: "Streamed tool call #{missing_id} missing from completed response"
         }}
    end
  end

  defp plan_completed_function_call(acc, item, idx, strict?) do
    item_id = item["id"]
    call_id = Map.get(item, "call_id") || item_id
    name = item["name"]
    existing = lookup_function_call_item(acc.function_calls, item_id, call_id, idx)

    cond do
      existing == :rejected ->
        {:ok, acc, [], nil}

      not valid_function_call_header?(idx, call_id, name) ->
        {:ok, acc, [], nil}

      true ->
        call_info = %{
          existing: existing,
          item: item,
          item_id: item_id,
          call_id: call_id,
          index: idx,
          name: name
        }

        case plan_and_store_function_call(acc, call_info, "response.completed", strict?) do
          {:ok, updated, events} -> {:ok, updated, events, call_id}
          {:error, _} = err -> err
        end
    end
  end

  defp build_stream_response(%{stream_error: %Error{} = error}), do: {:error, error}
  defp build_stream_response(%{sticky_error: %Error{} = error}), do: {:error, error}

  defp build_stream_response(%{response: response} = acc) when is_map(response) do
    with {:ok, parsed} <- OpenAI.parse_response(response),
         :ok <- flush_pending_from_response(acc, response) do
      {:ok, parsed}
    end
  end

  # Without a terminal event the connection was cut mid-response; returning
  # the text received so far would pass off a fragment as a complete answer.
  defp build_stream_response(_acc) do
    {:error,
     %Error{kind: :network, message: "Responses stream ended before the response completed"}}
  end
end
