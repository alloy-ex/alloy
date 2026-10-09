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
  - `:max_tokens` - Max output tokens, thinking included (default: 16_000).
    Thinking is on by default on Claude 5.x models and counts toward this
    limit, so a low value can cut off the answer (`stop_reason: :max_tokens`).
    Raise it for long outputs or high effort.
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.anthropic.com")
  - `:api_version` - API version header (default: "2023-06-01")
  - `:extra_headers` - Additional headers as `[{name, value}]`. Every
    `anthropic-beta` value is merged into a single `anthropic-beta` header.
    Alloy adds `context-management-2025-06-27` itself when `:extra_body`
    sets `context_management`; the other features it drives are GA and
    need no beta.
  - `:extra_body` - Additional request body fields, merged last. A `"tools"`
    key here replaces every tool Alloy generates; use `:server_tools` to add
    tools instead.
  - `:server_tools` - Raw tool maps sent after Alloy's own tools, for
    Anthropic-run tools such as web search, web fetch, tool search or an
    `mcp_toolset` (default: `[]`). For example
    `[%{"type" => "web_search_20260209", "name" => "web_search"}]`. Add any
    request fields or beta headers they need through `:extra_body` and
    `:extra_headers`.
  - `:req_options` - Additional options passed to Req (useful for testing)
  - `:extended_thinking` - *Deprecated; configure thinking through
    `:extra_body` instead (see "Thinking" below).* A keyword list with a
    positive `:budget_tokens` (e.g., `[budget_tokens: 5000]`) sends
    `"thinking": {"type": "enabled", "budget_tokens": ...}`. It still works on
    the models that accept manual budgets (Claude Opus 4.5, Sonnet 4.5,
    Haiku 4.5, and Opus 4.6 and Sonnet 4.6, where Anthropic deprecates it),
    but Claude Opus 4.7 and later and every Claude 5.x model reject it with
    HTTP 400.
  - `:on_event` - Streaming event callback `(event -> :ok)`. Called for each
    streaming delta. When used via `Server.stream_chat/4`, `event` is a
    normalized envelope map:
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :text_delta, payload: text}`
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :thinking_delta, payload: text}`
    Pass via `Server.stream_chat/4` opts: `on_event: fn event -> ... end`.
    Note: direct callers of `Alloy.Provider.Anthropic.stream/4` (without Turn)
    receive provider-native tuples (for example `{:thinking_delta, text}`).
  - `:code_execution` - `true` adds the server-side code execution tool
    (`code_execution_20260521`)

  ## Thinking

  Claude 5.x models think by default (adaptive thinking); Claude Opus 4.6 to
  4.8 and Sonnet 4.6 think once asked. Configure thinking with `:extra_body`:

      extra_body: %{
        "thinking" => %{"type" => "adaptive", "display" => "summarized"},
        "output_config" => %{"effort" => "high"}
      }

  `"display" => "summarized"` returns the thinking text; most current models
  default to `"omitted"`, which returns thinking blocks with an empty
  `thinking` field and only the signature. `output_config.effort` (`"low"`,
  `"medium"`, `"high"`, and on some models `"xhigh"` or `"max"`) sets how
  much the model thinks. Thinking counts toward `:max_tokens`. Thinking
  blocks come back in the message content and are sent back verbatim on
  later turns, as the API requires. See
  <https://platform.claude.com/docs/en/build-with-claude/thinking> and
  <https://platform.claude.com/docs/en/build-with-claude/effort>.

  ## Programmatic tool calling

  With `code_execution: true`, Claude can call your tools from code it runs
  in the sandbox. Opt a tool in with `allowed_callers: [:code_execution]`
  (sent as `"code_execution_20260120"`); `:human` and `:direct` are sent as
  `"direct"`, and strings pass through unchanged. Such calls arrive as
  ordinary tool calls with a `:caller` field, which Alloy sends back with the
  history. The response's container id is kept in `provider_state` as
  `:container_id` (with `:container_expires_at`) and sent as `"container"` on
  the next request, which the API requires while a programmatic call is
  waiting for its result. An expired container is not sent, so a session that
  resumes after the container was reclaimed gets a fresh one. See
  <https://platform.claude.com/docs/en/agents-and-tools/tool-use/programmatic-tool-calling>.

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
  # Thinking counts toward max_tokens and is on by default on Claude 5.x;
  # this is the value Anthropic's thinking examples use.
  @default_max_tokens 16_000
  # code_execution_20260120 and later support programmatic tool calling;
  # every model that has code execution accepts this version.
  @code_execution_tool_type "code_execution_20260521"
  # The caller name that lets code execution call a tool. The API accepts it
  # with either newer tool version and tags programmatic calls with it.
  @code_execution_caller "code_execution_20260120"
  @memory_tool_type "memory_20250818"
  @context_management_beta "context-management-2025-06-27"

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
          optional(:server_tools) => [map()],
          optional(:req_options) => keyword(),
          optional(:extended_thinking) => keyword(),
          optional(:on_event) => (term() -> :ok),
          optional(:cache) => boolean(),
          optional(:memory) => {module(), term()},
          optional(:code_execution) => boolean(),
          optional(:provider_state) => map()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    with {:ok, resp_body} <-
           HTTP.post_json(
             messages_url(config),
             build_headers(config, body),
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
             build_headers(config, body),
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

  # Retry retries a retryable error only when no output was streamed yet.
  defp handle_sse_event(acc, "error", event), do: %{acc | error: in_band_error(event)}

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

    client_tools =
      tool_defs
      |> Enum.map(&format_tool_def/1)
      |> maybe_add_cache_to_last_tool(cache?)

    tools =
      client_tools ++ code_execution_tools(config) ++ memory_tools(config) ++ server_tools(config)

    body =
      body
      |> maybe_put_tools(tools)
      |> maybe_put_container(config)

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

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, tools), do: Map.put(body, "tools", tools)

  defp code_execution_tools(%{code_execution: true}),
    do: [%{"type" => @code_execution_tool_type, "name" => "code_execution"}]

  defp code_execution_tools(_config), do: []

  defp memory_tools(%{memory: {_module, _store}}),
    do: [%{"type" => @memory_tool_type, "name" => "memory"}]

  defp memory_tools(_config), do: []

  # Anthropic runs these tools itself, so they are sent exactly as given.
  defp server_tools(config),
    do: config |> Map.get(:server_tools, []) |> Alloy.Provider.stringify_keys()

  # Reusing the container keeps code execution state between turns, and the
  # API rejects a continuation of a pending programmatic tool call without it.
  # Idle containers are reclaimed after about 5 minutes, so an expired one is
  # not sent: the API then starts a fresh container instead of the session
  # failing on every later request.
  defp maybe_put_container(body, %{provider_state: %{container_id: id} = state})
       when is_binary(id) do
    if container_live?(state), do: Map.put(body, "container", id), else: body
  end

  defp maybe_put_container(body, _config), do: body

  defp container_live?(%{container_expires_at: expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires, _offset} -> DateTime.compare(DateTime.utc_now(), expires) == :lt
      {:error, _reason} -> true
    end
  end

  defp container_live?(_state), do: true

  defp build_headers(config, body) do
    {user_betas, other_headers} =
      config
      |> Map.get(:extra_headers, [])
      |> Enum.split_with(fn {name, _value} -> String.downcase(name) == "anthropic-beta" end)

    betas = Enum.map(user_betas, fn {_name, value} -> value end) ++ required_betas(body)

    [
      {"x-api-key", config.api_key},
      {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
      {"content-type", "application/json"}
    ] ++ beta_header(betas) ++ other_headers
  end

  # Code execution, memory, tool search and tool use examples went GA on
  # 2026-02-17 and need no header; context editing is still in beta.
  defp required_betas(%{"context_management" => _}), do: [@context_management_beta]
  defp required_betas(_body), do: []

  # The API reads one comma-separated anthropic-beta header.
  defp beta_header(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> joined_beta_header()
  end

  defp joined_beta_header([]), do: []
  defp joined_beta_header(betas), do: [{"anthropic-beta", Enum.join(betas, ",")}]

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
    Map.put(message, "content", put_cache_on_last(blocks, &cacheable_message_block?/1))
  end

  defp add_cache_to_message_tail(message), do: message

  # Marks the last item that may carry a breakpoint; none if no item may.
  defp put_cache_on_last(items, cacheable?) do
    {items, _added?} =
      items
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn
        item, false ->
          if cacheable?.(item) do
            {Map.put(item, "cache_control", %{"type" => "ephemeral"}), true}
          else
            {item, false}
          end

        item, true ->
          {item, true}
      end)

    Enum.reverse(items)
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
      |> Enum.reject(&unsendable_block?/1)
      |> Enum.map(&format_content_block/1)

    %{"role" => to_string(role), "content" => content}
  end

  # Blocks the Messages API rejects, dropped so the transcript still works:
  # "server_tool_result" was written by Alloy <= 0.12.4, which answered
  # server tools client-side; "reasoning" and "output_item" are opaque
  # OpenAI Responses items in a transcript that switched provider.
  defp unsendable_block?(%{type: type})
       when type in ["server_tool_result", "reasoning", "output_item"],
       do: true

  defp unsendable_block?(_block), do: false

  defp format_content_block(%{type: "thinking", thinking: thinking} = block) do
    %{"type" => "thinking", "thinking" => thinking}
    |> maybe_put("signature", block[:signature])
  end

  defp format_content_block(%{type: "text", text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: "tool_use", id: id, name: name, input: input} = block) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    |> maybe_put("caller", block[:caller])
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

  defp maybe_add_cache_to_last_tool(tools, false), do: tools
  defp maybe_add_cache_to_last_tool(tools, true), do: put_cache_on_last(tools, &cacheable_tool?/1)

  # The API rejects cache_control on a tool with defer_loading: true.
  defp cacheable_tool?(%{"defer_loading" => true}), do: false
  defp cacheable_tool?(_tool), do: true

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

    maybe_put_allowed_callers(base, def_map)
  end

  defp maybe_put_allowed_callers(tool, %{allowed_callers: callers}) when is_list(callers),
    do: Map.put(tool, "allowed_callers", Enum.map(callers, &allowed_caller/1))

  defp maybe_put_allowed_callers(tool, _def_map), do: tool

  # Alloy's :human and :code_execution predate the API's caller names.
  defp allowed_caller(caller) when caller in [:human, :direct], do: "direct"
  defp allowed_caller(:code_execution), do: @code_execution_caller
  defp allowed_caller(caller), do: to_string(caller)

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

  defp parse_response(%{"type" => "error"} = resp), do: {:error, in_band_error(resp)}

  # The HTTP status was already 200 when the failure arrived in the body or
  # the stream, so it is classified by its error type: overloaded_error
  # becomes :overloaded, which Retry retries like an HTTP 529.
  defp in_band_error(body), do: Error.from_response(200, [], body)

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
      |> maybe_put(:provider_state, provider_state(resp))

    {:ok, response}
  end

  # Turn feeds provider_state back in config, so the next request reuses
  # the container (see maybe_put_container/2).
  defp provider_state(%{"container" => %{"id" => id} = container}) when is_binary(id),
    do: maybe_put(%{container_id: id}, :container_expires_at, container["expires_at"])

  defp provider_state(_resp), do: nil

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

  # A programmatic call's `caller` must go back unchanged with the history.
  defp parse_content_block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block
       ) do
    %{type: "tool_use", id: id, name: name, input: input}
    |> maybe_put(:caller, block["caller"])
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
