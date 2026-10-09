defmodule Alloy.Provider.Anthropic do
  @moduledoc """
  Provider for Anthropic's Claude Messages API.

  Uses Req for HTTP calls. Since Anthropic's wire format uses content blocks
  (the most expressive format), this provider has the simplest normalization.

  ## Config

  Required:
  - `:api_key` - Anthropic API key
  - `:model` - Model name (e.g., "claude-opus-4-6",
    "claude-sonnet-4-6", "claude-haiku-4-5")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.anthropic.com")
  - `:api_version` - API version header (default: "2023-06-01")
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:extra_body` - Additional request body fields, merged last
  - `:req_options` - Additional options passed to Req (useful for testing)
  - `:extended_thinking` - Enable extended thinking. Pass a keyword list with
    `:budget_tokens` (e.g., `[budget_tokens: 5000]`). Thinking blocks are
    returned in the message content and must be round-tripped verbatim in
    subsequent turns (Anthropic requires the `signature` field).
  - `:on_event` - Streaming event callback `(event -> :ok)`. Called for each
    streaming delta. When used via `Server.stream_chat/4`, `event` is a
    normalized envelope map:
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :text_delta, payload: text}`
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :thinking_delta, payload: text}`
    Pass via `Server.stream_chat/4` opts: `on_event: fn event -> ... end`.
    Note: direct callers of `Alloy.Provider.Anthropic.stream/4` (without Turn)
    receive provider-native tuples (for example `{:thinking_delta, text}`).

  ## Example

      Alloy.run("What is Elixir?",
        provider: {Alloy.Provider.Anthropic,
          api_key: System.get_env("ANTHROPIC_API_KEY"),
          model: "claude-sonnet-4-6"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.{Error, HTTP}

  @default_api_url "https://api.anthropic.com"
  @default_api_version "2023-06-01"
  @default_max_tokens 4096
  @code_execution_tool_type "code_execution_20250825"
  @code_execution_beta "code-execution-2025-08-25"
  @memory_tool_type "memory_20250818"
  @memory_beta "context-management-2025-06-27"
  @advanced_tool_use_beta "advanced-tool-use-2025-11-20"

  @typedoc """
  Configuration for the Anthropic provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:api_version) => String.t(),
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:req_options) => keyword(),
          optional(:extended_thinking) => keyword(),
          optional(:on_event) => (term() -> :ok),
          optional(:cache) => boolean(),
          optional(:memory) => {module(), term()}
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    with {:ok, resp_body} <-
           HTTP.post_json(
             messages_url(config),
             build_headers(config, tool_defs),
             body,
             Map.get(config, :req_options, [])
           ) do
      parse_response(resp_body)
    end
  end

  @doc """
  Stream a completion using Anthropic's SSE streaming API.

  Calls `on_chunk` for each text delta as it arrives. Accumulates all
  content blocks and returns the same `{:ok, completion_response()}` shape
  as `complete/3` once the stream finishes.
  """
  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    body =
      build_request_body(messages, tool_defs, config)
      |> Map.put("stream", true)

    on_event = Map.get(config, :on_event, fn _ -> :ok end)

    initial_acc = %{
      buffer: "",
      error: nil,
      message: %{},
      content_blocks: %{},
      input_json_buffers: %{},
      on_chunk: on_chunk,
      on_event: on_event
    }

    with {:ok, sse_acc} <-
           HTTP.stream_sse(
             messages_url(config),
             build_headers(config, tool_defs),
             body,
             initial_acc,
             &handle_sse_raw_event/2,
             Map.get(config, :req_options, [])
           ) do
      build_stream_response(sse_acc)
    end
  end

  defp messages_url(config), do: "#{Map.get(config, :api_url, @default_api_url)}/v1/messages"

  # Bridge from SSE module's raw events to Anthropic's typed event handler.
  # Anthropic events always have an event type and JSON-decodable data.
  defp handle_sse_raw_event(acc, %{event: event_type, data: data}) when is_binary(event_type) do
    case Jason.decode(data) do
      {:ok, parsed} -> handle_sse_event(acc, event_type, parsed)
      {:error, _} -> acc
    end
  end

  defp handle_sse_raw_event(acc, _event), do: acc

  defp handle_sse_event(acc, "message_start", %{"message" => msg}) do
    %{acc | message: msg}
  end

  defp handle_sse_event(acc, "content_block_start", %{
         "index" => index,
         "content_block" => block
       }) do
    put_in(acc.content_blocks[index], block)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "thinking_delta", "thinking" => text}
       }) do
    acc.on_event.({:thinking_delta, text})

    current = Map.get(acc.content_blocks, index, %{"type" => "thinking", "thinking" => ""})
    updated = Map.update!(current, "thinking", &(&1 <> text))
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "signature_delta", "signature" => sig}
       }) do
    current = Map.get(acc.content_blocks, index, %{"type" => "thinking", "thinking" => ""})
    updated = Map.put(current, "signature", sig)
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    # :text_delta on_event is emitted by Turn.wrapped_chunk universally.
    acc.on_chunk.(text)

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

  # The delta carries the message's final top-level fields (stop_reason,
  # stop_details, container). Its usage is cumulative, so it replaces the
  # message_start counts rather than adding to them.
  defp handle_sse_event(acc, "message_delta", %{"delta" => delta} = event) do
    usage = put_present(Map.get(acc.message, "usage", %{}), Map.get(event, "usage", %{}))
    message = acc.message |> put_present(delta) |> Map.put("usage", usage)
    %{acc | message: message}
  end

  # The response was already a 200 when the failure arrived in-band, so the
  # error is classified by its type: overloaded_error becomes :overloaded,
  # which Retry retries when no output was streamed yet.
  defp handle_sse_event(acc, "error", event) do
    %{acc | error: Error.from_response(200, [], event)}
  end

  defp handle_sse_event(acc, _event_type, _data), do: acc

  # A null in a later event means "not reported here", not "reset".
  defp put_present(map, updates) do
    Map.merge(map, Map.reject(updates, fn {_key, value} -> is_nil(value) end))
  end

  defp build_stream_response(%{error: %Error{} = error}), do: {:error, error}

  defp build_stream_response(%{message: %{"stop_reason" => stop_reason}} = acc)
       when is_binary(stop_reason) do
    content =
      acc.content_blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} -> block end)

    acc.message
    |> Map.put("content", content)
    |> message_response()
  end

  # Only the final message_delta carries a stop_reason, so a stream that ends
  # without one was cut off and its content is incomplete.
  defp build_stream_response(_acc) do
    {:error,
     %Error{
       kind: :network,
       message: "Anthropic stream ended before a stop_reason was received"
     }}
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    body = %{
      "model" => config.model,
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => Enum.map(messages, &format_message/1)
    }

    cache? = Map.get(config, :cache, false)
    body = maybe_add_cache_to_conversation_tail(body, cache?)

    body =
      case Map.get(config, :system_prompt) do
        nil ->
          body

        prompt when cache? ->
          Map.put(body, "system", [
            %{
              "type" => "text",
              "text" => prompt,
              "cache_control" => %{"type" => "ephemeral"}
            }
          ])

        prompt ->
          Map.put(body, "system", prompt)
      end

    body =
      case tool_defs do
        [] ->
          body

        defs ->
          tools = Enum.map(defs, &format_tool_def/1)
          tools = maybe_add_cache_to_last_tool(tools, cache?)
          Map.put(body, "tools", tools)
      end

    body =
      body
      |> maybe_add_code_execution(config)
      |> maybe_add_memory_tool(config)

    body =
      case Map.get(config, :extended_thinking) do
        nil ->
          body

        opts when is_list(opts) ->
          budget = Keyword.get(opts, :budget_tokens)

          unless is_integer(budget) and budget > 0 do
            raise ArgumentError,
                  "extended_thinking requires a positive integer :budget_tokens, got: #{inspect(budget)}"
          end

          Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})

        _opts ->
          # Non-list value (e.g., extended_thinking: true) — silently ignore
          body
      end

    Map.merge(body, stringify_extra_body(Map.get(config, :extra_body, %{})))
  end

  defp stringify_extra_body(extra_body) when is_map(extra_body) do
    Map.new(extra_body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_extra_body(_), do: %{}

  defp maybe_add_code_execution(body, config) do
    if Map.get(config, :code_execution, false) do
      code_exec_tool = %{
        "type" => @code_execution_tool_type,
        "name" => "code_execution"
      }

      existing_tools = Map.get(body, "tools", [])
      Map.put(body, "tools", existing_tools ++ [code_exec_tool])
    else
      body
    end
  end

  defp maybe_add_memory_tool(body, config) do
    case Map.get(config, :memory) do
      nil ->
        body

      {_module, _store} ->
        memory_tool = %{"type" => @memory_tool_type, "name" => "memory"}
        existing_tools = Map.get(body, "tools", [])
        Map.put(body, "tools", existing_tools ++ [memory_tool])
    end
  end

  defp build_headers(config, tool_defs) do
    extra_headers = Map.get(config, :extra_headers, [])
    {beta_values, other_headers} = split_anthropic_beta_headers(extra_headers)

    beta_values =
      if Map.get(config, :code_execution, false) do
        [@code_execution_beta | beta_values]
      else
        beta_values
      end

    beta_values =
      case Map.get(config, :memory) do
        nil -> beta_values
        {_module, _store} -> [@memory_beta | beta_values]
      end

    beta_values =
      if advanced_tool_use?(tool_defs) do
        [@advanced_tool_use_beta | beta_values]
      else
        beta_values
      end

    [
      {"x-api-key", config.api_key},
      {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
      {"content-type", "application/json"}
    ] ++ build_beta_headers(beta_values) ++ other_headers
  end

  defp advanced_tool_use?(tool_defs) do
    Enum.any?(tool_defs, fn tool_def ->
      Map.get(tool_def, :defer_loading) == true or
        match?([_ | _], Map.get(tool_def, :input_examples))
    end)
  end

  defp split_anthropic_beta_headers(headers) do
    Enum.reduce(headers, {[], []}, fn
      {"anthropic-beta", value}, {betas, others} -> {[value | betas], others}
      {name, value}, {betas, others} -> {betas, [{name, value} | others]}
    end)
  end

  defp build_beta_headers([]), do: []

  defp build_beta_headers(beta_values) do
    merged_value =
      beta_values
      |> Enum.reverse()
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(",")

    [{"anthropic-beta", merged_value}]
  end

  defp maybe_add_cache_to_conversation_tail(body, false), do: body

  defp maybe_add_cache_to_conversation_tail(%{"messages" => []} = body, true), do: body

  defp maybe_add_cache_to_conversation_tail(%{"messages" => messages} = body, true) do
    {init, [last]} = Enum.split(messages, -1)
    Map.put(body, "messages", init ++ [add_cache_to_message_tail(last)])
  end

  defp add_cache_to_message_tail(%{"content" => content} = message) when is_binary(content) do
    Map.put(message, "content", [
      %{"type" => "text", "text" => content, "cache_control" => %{"type" => "ephemeral"}}
    ])
  end

  defp add_cache_to_message_tail(%{"content" => blocks} = message)
       when is_list(blocks) and blocks != [] do
    Map.put(message, "content", add_cache_to_last_cacheable_block(blocks))
  end

  defp add_cache_to_message_tail(message), do: message

  defp add_cache_to_last_cacheable_block(blocks) do
    {blocks, _added?} =
      blocks
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn
        block, false ->
          if cacheable_message_block?(block) do
            {Map.put(block, "cache_control", %{"type" => "ephemeral"}), true}
          else
            {block, false}
          end

        block, true ->
          {block, true}
      end)

    Enum.reverse(blocks)
  end

  defp cacheable_message_block?(%{"type" => type}) when type in ["thinking", "redacted_thinking"],
    do: false

  defp cacheable_message_block?(block) when is_map(block), do: true
  defp cacheable_message_block?(_block), do: false

  defp format_message(%Message{role: role, content: content}) when is_binary(content) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    content =
      blocks
      |> Enum.reject(&legacy_server_tool_result?/1)
      |> Enum.map(&format_content_block/1)

    %{"role" => to_string(role), "content" => content}
  end

  # Alloy <= 0.12.4 answered server_tool_use blocks with a client-side
  # "server_tool_result", which the API rejects. Dropping them lets
  # transcripts persisted by those versions continue.
  defp legacy_server_tool_result?(%{type: "server_tool_result"}), do: true
  defp legacy_server_tool_result?(_block), do: false

  defp format_content_block(%{type: "thinking", thinking: thinking} = block) do
    %{"type" => "thinking", "thinking" => thinking}
    |> maybe_put("signature", block[:signature])
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

  defp format_content_block(%{type: "server_tool_use", id: id, name: name, input: input}) do
    %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp format_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => mime_type,
        "data" => data
      }
    }
  end

  # Anthropic does not support audio or video inline. Convert to a text notice
  # so the conversation can continue without crashing the turn loop.
  defp format_content_block(%{type: type}) when type in ["audio", "video"] do
    %{"type" => "text", "text" => "[Unsupported media type for Anthropic provider: #{type}]"}
  end

  # Document blocks require Anthropic's Files API (separate upload step). Convert
  # to a text notice in the same spirit as the audio/video fallback above.
  defp format_content_block(%{type: "document", mime_type: mime_type}) do
    %{
      "type" => "text",
      "text" =>
        "[Unsupported inline document (#{mime_type}) for Anthropic provider: use the Files API]"
    }
  end

  defp format_content_block(block) when is_map(block) do
    # Pass through any other block types as-is, converting atom keys to strings
    Map.new(block, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_add_cache_to_last_tool([], _cache?), do: []
  defp maybe_add_cache_to_last_tool(tools, false), do: tools

  defp maybe_add_cache_to_last_tool(tools, true) do
    {init, [last]} = Enum.split(tools, -1)
    init ++ [Map.put(last, "cache_control", %{"type" => "ephemeral"})]
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema} = def_map) do
    base =
      %{
        "name" => name,
        "description" => desc,
        "input_schema" => Alloy.Provider.stringify_keys(schema)
      }
      |> maybe_put_strict(def_map)
      |> maybe_put_input_examples(def_map)
      |> maybe_put_defer_loading(def_map)

    case Map.get(def_map, :allowed_callers) do
      nil -> base
      callers -> Map.put(base, "allowed_callers", Enum.map(callers, &to_string/1))
    end
  end

  defp maybe_put_strict(tool, %{strict: true}), do: Map.put(tool, "strict", true)
  defp maybe_put_strict(tool, _def_map), do: tool

  defp maybe_put_input_examples(tool, %{input_examples: examples}) when is_list(examples) do
    Map.put(tool, "input_examples", examples)
  end

  defp maybe_put_input_examples(tool, _def_map), do: tool

  defp maybe_put_defer_loading(tool, %{defer_loading: true}) do
    Map.put(tool, "defer_loading", true)
  end

  defp maybe_put_defer_loading(tool, _def_map), do: tool

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"type" => "message"} = resp), do: message_response(resp)

  defp parse_response(%{"type" => "error"} = resp) do
    error = resp["error"] || %{}
    {:error, "#{error["type"]}: #{error["message"]}"}
  end

  # Shared by complete/3 and stream/4: `resp` is a Messages API message, or
  # the equivalent assembled from stream events.
  defp message_response(resp) do
    response =
      %{
        stop_reason: parse_stop_reason(resp["stop_reason"]),
        messages: [
          %Message{role: :assistant, content: parse_content_blocks(resp["content"] || [])}
        ],
        usage: parse_usage(resp["usage"] || %{})
      }
      |> maybe_put(:response_metadata, response_metadata(resp))

    {:ok, response}
  end

  # https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("stop_sequence"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("model_context_window_exceeded"), do: :max_tokens
  defp parse_stop_reason("refusal"), do: :refusal
  defp parse_stop_reason("pause_turn"), do: :pause_turn
  # The API may add stop reasons; an unknown one ends the turn rather than
  # failing a run that produced a usable response.
  defp parse_stop_reason(_stop_reason), do: :end_turn

  # stop_details is null for every stop reason except refusal.
  defp response_metadata(%{"stop_details" => %{} = details}), do: %{stop_details: details}
  defp response_metadata(_resp), do: nil

  defp parse_content_blocks(blocks) do
    Enum.map(blocks, &parse_content_block/1)
  end

  defp parse_content_block(%{"type" => "thinking", "thinking" => thinking} = block) do
    %{type: "thinking", thinking: thinking}
    |> maybe_put(:signature, block["signature"])
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    %{type: "text", text: text}
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp parse_content_block(%{
         "type" => "server_tool_use",
         "id" => id,
         "name" => name,
         "input" => input
       }) do
    %{type: "server_tool_use", id: id, name: name, input: input}
  end

  defp parse_content_block(block) do
    # Unknown block type — preserve with string keys to avoid atom table
    # pollution from untrusted API responses. Only convert known keys.
    type = Map.get(block, "type", "unknown")
    %{type: type} |> Map.merge(Map.delete(block, "type"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp parse_usage(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens", 0),
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens", 0)
    }
  end
end
