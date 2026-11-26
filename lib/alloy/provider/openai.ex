defmodule Alloy.Provider.OpenAI do
  @moduledoc """
  Provider for OpenAI's Responses API.

  Normalizes OpenAI's response output items (assistant messages + function
  calls) to Alloy's content-block format. Use this provider, not
  `Alloy.Provider.OpenAICompat`, for OpenAI models: starting with GPT-5.4,
  Chat Completions does not support tool calling with reasoning enabled.

  ## Config

  Required:
  - `:api_key` - OpenAI API key string, or a 0-arity callback returning
    `String.t() | {:ok, String.t()} | {:error, term()}` invoked per HTTP
    attempt (inside a deadline-bounded worker when `:timeout_ms` is finite).
    When passing a callback via `Alloy.run/2`, also set `:origin_key` to a
    stable non-empty string for account isolation.
  - `:model` - Model name (e.g., "gpt-6-astra", "gpt-6.1-sol", "gpt-5.4")

  Optional:
  - `:origin_key` - Account identifier used for cross-origin provenance hashing
    (required for function `:api_key` and `auth_scheme: :bearer`; recommended
    for static keys when persisting transcripts with file attachments across key rotation)
  - `:prompt_cache_key` - Optional cache routing key for Responses prompt caching
  - `:prompt_cache_retention` - Optional cache retention policy (e.g. `"in_memory"`, `"24h"`)
  - `:max_tokens` - Max output tokens, reasoning tokens included. Omitted
    unless set, so the model's own limit applies: a small cap can leave a
    reasoning model with no tokens for its answer
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.openai.com"). Can point to
    compatible Responses APIs; for xAI use `Alloy.Provider.XAI`
  - `:provider_state` - opaque provider-owned state carried across turns.
    Each response's ID is recorded as `%{response_id: "..."}`; it is
    informational and never sent back automatically
  - `:store` - Persist the response server-side when supported
  - `:include` - Additional response fields to include
  - `:tool_choice` - Provider-native tool selection mode
  - `:parallel_tool_calls` - Whether the provider may issue tool calls in parallel
  - `:previous_response_id` - Continue a stored response (see "Chaining
    responses" below)
  - `:built_in_tools` - provider-native tool definitions to append to custom
    function tools
  - `:web_search` - `true` or a config map to append a `web_search` tool
  - `:x_search` - `true` or a config map to append an `x_search` tool
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:extra_body` - Additional request body fields, merged last
  - `:req_options` - Additional options passed to Req

  ## Conversation state

  By default every request carries the full conversation, like every other
  Alloy provider. In this stateless mode (`store` not `true` and no
  `:previous_response_id`), Alloy requests encrypted reasoning content and
  replays every output item: reasoning items are kept as
  `%{type: "reasoning", raw: item}` blocks and other non-message items
  (built-in tool calls, compaction items) as `%{type: "output_item", raw:
  item}` blocks. An assistant message's `phase` is kept on its text blocks
  and always sent back.

  ## Chaining responses

  To continue a response stored server-side instead, pass its ID as
  `:previous_response_id` together with only the messages added since that
  response. The server prepends the stored conversation, so sending the full
  history as well would duplicate it (and bill it twice). The ID of the
  latest response is in `result.metadata.provider_state.response_id`. A
  chained response must have been created with `store` enabled (the API's
  default). Tool-loop turns within one run keep the same
  `:previous_response_id`, so they still send only the run's new messages.

  ## Example

      Alloy.run("Summarize this code.",
        provider: {Alloy.Provider.OpenAI,
          api_key: System.get_env("OPENAI_API_KEY"),
          model: "gpt-5.4"
        }
      )

  """

  @behaviour Alloy.Provider

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, OutputSchema}
  alias Alloy.Provider.{Error, HTTP}

  @default_api_url "https://api.openai.com"
  @terminal_events ["response.completed", "response.incomplete", "response.failed"]

  @typedoc """
  Configuration for the OpenAI provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => Alloy.Provider.api_key(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:origin_key) => String.t(),
          optional(:provider_state) => map(),
          optional(:store) => boolean(),
          optional(:include) => [String.t()],
          optional(:tool_choice) => String.t() | map(),
          optional(:parallel_tool_calls) => boolean(),
          optional(:previous_response_id) => String.t(),
          optional(:prompt_cache_key) => String.t(),
          optional(:prompt_cache_retention) => String.t(),
          optional(:reasoning) => Alloy.Provider.reasoning(),
          optional(:on_event) => (term() -> :ok),
          optional(:built_in_tools) => [map()],
          optional(:web_search) => boolean() | map(),
          optional(:x_search) => boolean() | map(),
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:req_options) => keyword()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- HTTP.resolve_api_key(config),
         {:ok, resp_body} <-
           HTTP.post_json(
             responses_url(config),
             headers(config, api_key),
             body,
             Map.get(config, :req_options, []),
             deadline: Map.get(config, :alloy_request_deadline)
           ) do
      parse_response(resp_body)
    end
  end

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    initial_acc = %{
      buffer: "",
      response: nil,
      stream_error: nil,
      sticky_error: nil,
      function_calls: %{},
      pending_function_deltas: %{},
      pending_delta_seq: 0,
      on_chunk: on_chunk,
      on_event: Map.get(config, :on_event, fn _ -> :ok end)
    }

    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- HTTP.resolve_api_key(config),
         body = Map.put(body, "stream", true),
         {:ok, acc} <-
           HTTP.stream_sse(
             responses_url(config),
             headers(config, api_key),
             body,
             initial_acc,
             &handle_stream_event/2,
             Map.get(config, :req_options, []),
             deadline: Map.get(config, :alloy_request_deadline)
           ) do
      build_stream_response(acc)
    end
  end

  defp responses_url(config),
    do: HTTP.join_url(Map.get(config, :api_url, @default_api_url), "/v1/responses")

  defp headers(config, api_key) do
    [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}] ++
      Map.get(config, :extra_headers, [])
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    with {:ok, reasoning} <- Alloy.Provider.normalize_reasoning(Map.get(config, :reasoning)) do
      input_items = build_input_items(messages, config)

      body =
        %{"model" => config.model, "input" => input_items}
        |> HTTP.maybe_put_unless_empty_list("max_output_tokens", Map.get(config, :max_tokens))
        |> HTTP.maybe_put_unless_empty_list(
          "previous_response_id",
          Map.get(config, :previous_response_id)
        )
        |> HTTP.maybe_put_unless_empty_list("store", Map.get(config, :store))
        |> HTTP.maybe_put_unless_empty_list("include", Map.get(config, :include))
        |> maybe_put_reasoning_include(config)
        |> HTTP.maybe_put_unless_empty_list("tool_choice", Map.get(config, :tool_choice))
        |> HTTP.maybe_put_unless_empty_list(
          "parallel_tool_calls",
          Map.get(config, :parallel_tool_calls)
        )
        |> maybe_put_non_empty_string("prompt_cache_key", Map.get(config, :prompt_cache_key))
        |> maybe_put_non_empty_string(
          "prompt_cache_retention",
          Map.get(config, :prompt_cache_retention)
        )

      tools = Enum.map(tool_defs, &format_tool_def/1) ++ built_in_tools(config)

      body =
        body
        |> HTTP.maybe_put_unless_empty_list("tools", tools)
        |> maybe_put_output_schema(config)
        |> maybe_put_reasoning(reasoning)

      # Merge extra_body LAST so caller can override any field (#18), preserving
      # sibling keys inside "text" (e.g. verbosity alongside format).
      {:ok,
       HTTP.merge_extra_body(
         body,
         HTTP.stringify_extra_body(Map.get(config, :extra_body, %{})),
         "text"
       )}
    end
  end

  defp maybe_put_reasoning(body, nil), do: body

  defp maybe_put_reasoning(body, %{effort: effort, display: display}) do
    reasoning =
      %{"effort" => openai_reasoning_effort(effort)}
      |> then(fn map ->
        if effort != :off and display == :summarized,
          do: Map.put(map, "summary", "auto"),
          else: map
      end)

    Map.put(body, "reasoning", reasoning)
  end

  defp openai_reasoning_effort(:off), do: "none"
  defp openai_reasoning_effort(:low), do: "low"
  defp openai_reasoning_effort(:medium), do: "medium"
  defp openai_reasoning_effort(:high), do: "high"
  defp openai_reasoning_effort(:xhigh), do: "xhigh"

  defp maybe_put_non_empty_string(body, key, value) when is_binary(value) and value != "",
    do: Map.put(body, key, value)

  defp maybe_put_non_empty_string(body, _key, _other), do: body

  defp maybe_put_output_schema(body, config) do
    case Map.get(config, :output_schema) do
      nil ->
        body

      %OutputSchema{name: name, schema: schema, strict: strict} ->
        Map.put(body, "text", %{
          "format" => %{
            "type" => "json_schema",
            "name" => name,
            "schema" => schema,
            "strict" => strict
          }
        })
    end
  end

  defp maybe_put_reasoning_include(body, config) do
    if stateless_reasoning_echo?(config) do
      put_reasoning_include(body)
    else
      body
    end
  end

  defp put_reasoning_include(body) do
    includes = body |> Map.get("include", []) |> List.wrap()
    Map.put(body, "include", Enum.uniq(includes ++ ["reasoning.encrypted_content"]))
  end

  defp built_in_tools(config) do
    []
    |> maybe_append_built_in_tool("web_search", Map.get(config, :web_search))
    |> maybe_append_built_in_tool("x_search", Map.get(config, :x_search))
    |> Kernel.++(normalize_built_in_tools(Map.get(config, :built_in_tools, [])))
  end

  defp maybe_append_built_in_tool(tools, _type, nil), do: tools
  defp maybe_append_built_in_tool(tools, _type, false), do: tools
  defp maybe_append_built_in_tool(tools, type, true), do: tools ++ [%{"type" => type}]

  defp maybe_append_built_in_tool(tools, "web_search", config) when is_map(config) do
    tools ++ [normalize_web_search_tool(config)]
  end

  defp maybe_append_built_in_tool(tools, type, config) when is_map(config) do
    tools ++ [Map.put(Alloy.Provider.stringify_keys(config), "type", type)]
  end

  defp normalize_built_in_tools(tools) when is_list(tools) do
    Enum.map(tools, &normalize_built_in_tool/1)
  end

  defp normalize_built_in_tools(_), do: []

  defp normalize_built_in_tool(%{"type" => _type} = tool), do: Alloy.Provider.stringify_keys(tool)

  defp normalize_built_in_tool(%{type: _type} = tool), do: Alloy.Provider.stringify_keys(tool)

  defp normalize_web_search_tool(config) do
    config
    |> Alloy.Provider.stringify_keys()
    |> Map.put("type", "web_search")
  end

  defp build_input_items(messages, config) do
    system_items =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    stateless? = stateless_reasoning_echo?(config)
    convo_items = Enum.flat_map(messages, &format_input_item(&1, stateless?))
    system_items ++ convo_items
  end

  defp stateless_reasoning_echo?(config) do
    Map.get(config, :store) != true and is_nil(Map.get(config, :previous_response_id))
  end

  defp format_input_item(%Message{role: :user, content: content}, _stateless?)
       when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: content}, _stateless?)
       when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: blocks}, stateless?)
       when is_list(blocks) do
    Enum.flat_map(blocks, &format_assistant_block(&1, stateless?))
  end

  defp format_input_item(%Message{role: :user, content: blocks}, _stateless?)
       when is_list(blocks) do
    if Enum.any?(blocks, &(&1[:type] == "tool_result")) do
      blocks
      |> Enum.map(fn
        %{type: "tool_result", tool_use_id: tool_call_id, content: content} ->
          %{"type" => "function_call_output", "call_id" => tool_call_id, "output" => content}

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      parts = blocks |> Enum.map(&format_user_content_block/1) |> Enum.reject(&is_nil/1)

      case parts do
        [] -> []
        _ -> [%{"role" => "user", "content" => parts}]
      end
    end
  end

  defp format_user_content_block(%{type: "text", text: text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp format_user_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{"type" => "input_image", "image_url" => "data:#{mime_type};base64,#{data}"}
  end

  defp format_user_content_block(%{type: "image", url: url}) when is_binary(url) do
    if HTTP.http_url?(url) and not HTTP.provider_file_uri?(url) do
      %{"type" => "input_image", "image_url" => url}
    else
      unsupported_media_notice("image")
    end
  end

  defp format_user_content_block(%{type: "audio", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "video", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type, data: data} = block)
       when is_binary(mime_type) and is_binary(data) do
    %{
      "type" => "input_file",
      "filename" => block[:filename] || block[:title] || default_document_filename(mime_type),
      "file_data" => "data:#{mime_type};base64,#{data}"
    }
  end

  defp format_user_content_block(%{type: "document", file_id: file_id})
       when is_binary(file_id) do
    %{"type" => "input_file", "file_id" => file_id}
  end

  defp format_user_content_block(%{type: "document", uri: uri} = block) when is_binary(uri) do
    if HTTP.http_url?(uri) and not HTTP.provider_file_uri?(uri) do
      %{"type" => "input_file", "file_url" => uri}
    else
      unsupported_media_notice(Map.get(block, :mime_type, "document"))
    end
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(_block), do: nil

  defp default_document_filename("application/pdf"), do: "document.pdf"
  defp default_document_filename("text/plain"), do: "document.txt"
  defp default_document_filename("text/markdown"), do: "document.md"
  defp default_document_filename("text/csv"), do: "document.csv"
  defp default_document_filename(_mime_type), do: "document"

  defp format_assistant_block(%{type: "text", text: text} = block, _stateless?)
       when is_binary(text) and text != "" do
    [
      HTTP.maybe_put_unless_empty_list(
        %{"role" => "assistant", "content" => text},
        "phase",
        block[:phase]
      )
    ]
  end

  defp format_assistant_block(%{type: "tool_use"} = block, _stateless?) do
    [format_assistant_function_call_item(block)]
  end

  defp format_assistant_block(%{type: type, raw: raw}, true)
       when type in ["reasoning", "output_item"] and is_map(raw) do
    [raw]
  end

  defp format_assistant_block(_block, _stateless?), do: []

  defp unsupported_media_notice(mime_type) do
    %{
      "type" => "input_text",
      "text" => "[Unsupported media type for OpenAI provider: #{mime_type}]"
    }
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema} = def_map) do
    tool = %{
      "type" => "function",
      "name" => name,
      "description" => desc,
      "parameters" => Alloy.Provider.stringify_keys(schema)
    }

    if Map.get(def_map, :strict) == true, do: Map.put(tool, "strict", true), else: tool
  end

  defp format_assistant_function_call_item(%{id: id, name: name, input: input}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(input)
    }
  end

  # --- Streaming ---

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

  # Every terminal event carries the whole response, and parse_response/1
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

  defp register_function_call_item(acc, item, index, event_type) do
    raw_call_id = Map.get(item, "call_id")
    item_id = item["id"]
    name = item["name"]
    existing = lookup_function_call_meta(acc.function_calls, item_id, index)

    # During streaming (output_item.added / output_item.done), require the true
    # call_id so consumers never receive item_id when call_id arrives later.
    # Only the terminal response.completed payload may fall back to item["id"]
    # (matching parse_output_to_blocks/2).
    call_id =
      if event_type == "response.completed",
        do: raw_call_id || item_id,
        else: raw_call_id

    cond do
      existing == :rejected ->
        acc

      event_type == "response.output_item.added" and not valid_added_item_args?(item) ->
        mark_rejected_function_call(acc, item_id, index)

      valid_function_call_header?(index, call_id, name) ->
        emit_and_store_function_call(
          acc,
          existing,
          item,
          item_id,
          call_id,
          index,
          name,
          event_type
        )

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

  defp emit_and_store_function_call(
         acc,
         existing,
         item,
         item_id,
         call_id,
         index,
         name,
         event_type
       ) do
    header_emitted? = match?(%{id: ^call_id, name: ^name}, existing)
    emitted_args = if is_map(existing), do: Map.get(existing, :emitted_args, ""), else: ""

    if event_type == "response.output_item.done" and not header_emitted? and
         invalid_whole_item_args?(item) do
      # Defer malformed whole-item calls so response.completed / parse_response
      # can fail with :malformed_reply before chunks_emitted? is flipped.
      acc
    else
      base_meta = %{id: call_id, index: index, name: name}

      unless header_emitted? do
        header_event = Map.put(base_meta, :arguments_delta, "")
        acc.on_event.({:tool_call_delta, header_event})
      end

      {pending_deltas, next_pending} =
        pop_pending_deltas(acc.pending_function_deltas, item_id, index)

      emitted_args = emit_buffered_args(acc.on_event, base_meta, pending_deltas, emitted_args)

      emitted_args =
        maybe_emit_whole_item_args(acc.on_event, base_meta, item, event_type, emitted_args)

      meta = Map.merge(base_meta, %{item_id: item_id, emitted_args: emitted_args})

      function_calls =
        acc.function_calls
        |> maybe_put_call_meta(item_id, meta)
        |> Map.put({:index, index}, meta)

      %{acc | function_calls: function_calls, pending_function_deltas: next_pending}
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
    not match?({:ok, _}, decode_function_call_arguments(item))
  end

  defp maybe_buffer_added_args(acc, "response.output_item.added", item, item_id, index) do
    case item_args_delta(item, "response.output_item.added") do
      "" -> acc
      prefix -> buffer_pending_delta(acc, item_id, index, prefix)
    end
  end

  defp maybe_buffer_added_args(acc, _event_type, _item, _item_id, _index), do: acc

  defp maybe_emit_whole_item_args(on_event, base_meta, item, event_type, emitted_args)
       when event_type in [
              "response.output_item.added",
              "response.output_item.done",
              "response.completed"
            ] do
    args = item_args_delta(item, event_type)

    cond do
      args == "" or args == emitted_args ->
        emitted_args

      String.starts_with?(args, emitted_args) ->
        prefix_len = byte_size(emitted_args)
        suffix = binary_part(args, prefix_len, byte_size(args) - prefix_len)
        event = Map.put(base_meta, :arguments_delta, suffix)
        on_event.({:tool_call_delta, event})
        args

      true ->
        emitted_args
    end
  end

  defp maybe_emit_whole_item_args(_on_event, _base_meta, _item, _event_type, emitted_args),
    do: emitted_args

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

  defp lookup_function_call_meta(calls, item_id, index) do
    case maybe_get_by_id(calls, item_id) do
      nil -> lookup_call_by_index(calls, index)
      found -> found
    end
  end

  defp maybe_get_by_id(calls, id) when is_binary(id) and id != "", do: Map.get(calls, id)
  defp maybe_get_by_id(_calls, _id), do: nil

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
        acc.on_event.(
          {:tool_call_delta,
           %{
             id: id,
             index: raw_index || idx,
             name: name,
             arguments_delta: delta
           }}
        )

        updated_meta = %{meta | emitted_args: Map.get(meta, :emitted_args, "") <> delta}

        function_calls =
          acc.function_calls
          |> maybe_put_call_meta(item_id, updated_meta)
          |> maybe_put_call_meta(Map.get(meta, :item_id), updated_meta)
          |> Map.put({:index, idx}, updated_meta)

        %{acc | function_calls: function_calls}

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

  defp emit_buffered_args(on_event, meta, deltas, emitted_args) do
    Enum.reduce(deltas, emitted_args, fn {raw_index, delta}, acc_args ->
      on_event.(
        {:tool_call_delta,
         %{
           id: meta.id,
           index: raw_index || meta.index,
           name: meta.name,
           arguments_delta: delta
         }}
      )

      acc_args <> delta
    end)
  end

  defp flush_pending_from_response(acc, %{"output" => output}) when is_list(output) do
    output
    |> Enum.with_index()
    |> Enum.reduce(acc, fn
      {%{"type" => "function_call"} = item, idx}, current ->
        register_function_call_item(current, item, idx, "response.completed")

      _other, current ->
        current
    end)
  end

  defp flush_pending_from_response(acc, _response), do: acc

  defp build_stream_response(%{stream_error: %Error{} = error}), do: {:error, error}
  defp build_stream_response(%{sticky_error: %Error{} = error}), do: {:error, error}

  defp build_stream_response(%{response: response} = acc) when is_map(response) do
    case parse_response(response) do
      {:ok, parsed} ->
        _ = flush_pending_from_response(acc, response)
        {:ok, parsed}

      {:error, _} = err ->
        err
    end
  end

  # Without a terminal event the connection was cut mid-response; returning
  # the text received so far would pass off a fragment as a complete answer.
  defp build_stream_response(_acc) do
    {:error,
     %Error{kind: :network, message: "Responses stream ended before the response completed"}}
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"status" => "failed"} = resp), do: {:error, Error.from_body(resp)}

  defp parse_response(%{"output" => output} = resp) when is_list(output) do
    provider_state = provider_state_from_response(resp)
    mode = parse_output_mode(resp)

    case parse_output_to_blocks(output, mode) do
      {:ok, content_blocks} ->
        stop_reason = parse_stop_reason(resp, content_blocks)

        alloy_msg = %Message{
          role: :assistant,
          content: content_blocks
        }

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [alloy_msg],
           usage: parse_usage(resp["usage"]),
           provider_state: provider_state,
           response_metadata: response_metadata_from_response(resp)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp parse_response(%{"output_text" => text} = resp) when is_binary(text) do
    provider_state = provider_state_from_response(resp)

    content_blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [%Message{role: :assistant, content: content_blocks}],
       usage: parse_usage(resp["usage"]),
       provider_state: provider_state,
       response_metadata: response_metadata_from_response(resp)
     }}
  end

  defp parse_response(%{"error" => error} = resp) when is_map(error) or is_binary(error) do
    {:error, Error.from_body(resp)}
  end

  defp parse_response(resp) do
    {:error,
     %Error{
       message: "Unexpected OpenAI response payload: #{Sanitize.inspect_bounded(resp)}"
     }}
  end

  defp parse_output_mode(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "content_filter"}
       }),
       do: :refusal

  defp parse_output_mode(%{"status" => "incomplete"}), do: :truncated
  defp parse_output_mode(_resp), do: :normal

  defp parse_output_to_blocks(output, mode) do
    result =
      output
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, idx}, {:ok, acc} ->
        case parse_output_item(item, idx, mode) do
          {:ok, blocks} -> {:cont, {:ok, [blocks | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, nested} -> {:ok, nested |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp parse_output_item(
         %{"type" => "message", "role" => "assistant", "content" => content} = item,
         _idx,
         _mode
       )
       when is_list(content) or is_binary(content) do
    {:ok, content |> parse_assistant_content() |> Enum.map(&put_phase(&1, item["phase"]))}
  end

  # Refused output is discarded by the loop; drop partial function calls so the
  # refusal reaches Turn without triggering retries.
  defp parse_output_item(%{"type" => "function_call"}, _idx, :refusal), do: {:ok, []}

  # Under status: "incomplete" (e.g. max_output_tokens), a function_call may be
  # cut off mid-JSON or before id/name arrived. Parse leniently so Turn sees
  # stop_reason: :max_tokens and abandons the call cleanly instead of retrying
  # a deterministic truncation.
  defp parse_output_item(%{"type" => "function_call"} = call, idx, :truncated) do
    id =
      case call["call_id"] || call["id"] do
        value when is_binary(value) and value != "" -> value
        _ -> "truncated_#{idx}_#{System.unique_integer([:positive])}"
      end

    name =
      case call["name"] do
        value when is_binary(value) and value != "" -> value
        _ -> "truncated"
      end

    input =
      case decode_function_call_arguments(call) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    {:ok, [%{type: "tool_use", id: id, name: name, input: input}]}
  end

  defp parse_output_item(%{"type" => "function_call"} = call, _idx, :normal) do
    with {:ok, id} <- fetch_function_call_id(call),
         {:ok, name} <- fetch_function_call_name(call),
         {:ok, input} <- decode_function_call_arguments(call) do
      {:ok, [%{type: "tool_use", id: id, name: name, input: input}]}
    end
  end

  defp parse_output_item(%{"type" => "reasoning"} = item, _idx, _mode) do
    {:ok, [%{type: "reasoning", raw: item}]}
  end

  # Built-in tool calls (web search, code interpreter, MCP), compaction items
  # and types added later are kept whole, so a stateless replay sends the
  # complete output back as the API expects.
  defp parse_output_item(%{"type" => _type} = item, _idx, _mode),
    do: {:ok, [%{type: "output_item", raw: item}]}

  defp parse_output_item(_item, _idx, _mode), do: {:ok, []}

  defp fetch_function_call_id(call) do
    case call["call_id"] || call["id"] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _missing ->
        {:error,
         %Error{
           kind: :protocol_error,
           message: "OpenAI function_call missing non-empty call_id/id"
         }}
    end
  end

  defp fetch_function_call_name(call) do
    case call["name"] do
      name when is_binary(name) and name != "" ->
        {:ok, name}

      _missing ->
        {:error,
         %Error{
           kind: :protocol_error,
           message: "OpenAI function_call missing non-empty name"
         }}
    end
  end

  defp parse_assistant_content(""), do: []
  defp parse_assistant_content(text) when is_binary(text), do: [%{type: "text", text: text}]

  defp parse_assistant_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} = item when is_binary(text) and text != "" ->
        [%{type: "text", text: text} |> maybe_put_annotations(item["annotations"])]

      %{"type" => "refusal", "refusal" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text, refusal: true}]

      %{"type" => "refusal", "text" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text, refusal: true}]

      _ ->
        []
    end)
  end

  defp parse_stop_reason(
         %{"status" => "incomplete", "incomplete_details" => %{"reason" => "content_filter"}},
         _content_blocks
       ),
       do: :refusal

  # Every other incomplete reason (max_output_tokens, max_messages) means the
  # output was cut short.
  defp parse_stop_reason(%{"status" => "incomplete"}, _content_blocks), do: :max_tokens

  defp parse_stop_reason(_resp, content_blocks) do
    if Enum.any?(content_blocks, &(&1.type == "tool_use")), do: :tool_use, else: :end_turn
  end

  defp decode_function_call_arguments(call) do
    name = Map.get(call, "name", "truncated")
    args = Map.get(call, "arguments", "")

    case args do
      "" ->
        {:ok, %{}}

      encoded when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, input} when is_map(input) ->
            {:ok, input}

          {:ok, _non_map} ->
            {:error,
             %Error{
               kind: :malformed_reply,
               message: "Tool call arguments for #{name} must be a JSON object"
             }}

          {:error, _} ->
            {:error,
             %Error{
               kind: :malformed_reply,
               message: "Invalid JSON in tool call arguments for #{name}"
             }}
        end

      decoded when is_map(decoded) ->
        {:ok, decoded}

      _other ->
        {:error,
         %Error{
           kind: :malformed_reply,
           message: "Invalid tool call arguments payload for #{name}"
         }}
    end
  end

  # Alloy.Usage follows Anthropic: input_tokens excludes cache reads and
  # writes, which have their own fields. OpenAI counts both inside
  # input_tokens, so they are taken out here.
  defp parse_usage(%{} = usage) do
    details = usage["input_tokens_details"] || %{}
    cache_read = details["cached_tokens"] || 0
    cache_write = details["cache_write_tokens"] || 0

    HTTP.cache_adjusted_usage(
      usage["input_tokens"] || 0,
      usage["output_tokens"] || 0,
      cache_read,
      cache_write
    )
  end

  defp parse_usage(nil), do: parse_usage(%{})

  defp provider_state_from_response(%{"id" => id}) when is_binary(id) and id != "" do
    %{response_id: id}
  end

  defp provider_state_from_response(_resp), do: %{}

  defp response_metadata_from_response(resp) do
    %{}
    |> HTTP.maybe_put_unless_empty_list(:citations, Map.get(resp, "citations"))
    |> HTTP.maybe_put_unless_empty_list(
      :server_side_tool_usage,
      Map.get(resp, "server_side_tool_usage")
    )
    |> HTTP.maybe_put_unless_empty_list(:stop_details, stop_details(resp))
  end

  defp stop_details(%{"status" => "incomplete"} = resp), do: resp["incomplete_details"]
  defp stop_details(_resp), do: nil

  defp maybe_put_annotations(block, annotations)
       when is_list(annotations) and annotations != [] do
    Map.put(block, :annotations, annotations)
  end

  defp maybe_put_annotations(block, _annotations), do: block

  # gpt-5.3-codex and later label assistant messages as "commentary" or
  # "final_answer" and need the label back on every replayed message.
  defp put_phase(block, phase) when is_binary(phase), do: Map.put(block, :phase, phase)
  defp put_phase(block, _phase), do: block
end
