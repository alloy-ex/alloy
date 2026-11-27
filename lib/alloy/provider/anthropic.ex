defmodule Alloy.Provider.Anthropic do
  @moduledoc """
  Provider for Anthropic's Claude Messages API.

  Uses Req for HTTP calls. Since Anthropic's wire format uses content blocks
  (the most expressive format), this provider has the simplest normalization.

  ## Config

  Required:
  - `:api_key` - Anthropic API key string, or a 0-arity callback returning
    `String.t() | {:ok, String.t()} | {:error, term()}` invoked per HTTP
    attempt (inside a bounded worker when `:timeout_ms` is finite or
    `:cancel_token` is set).
    When passing a callback via `Alloy.run/2`, also set `:origin_key` to a
    stable non-empty string for account isolation.
  - `:model` - Model name (e.g., "claude-opus-4-6",
    "claude-sonnet-4-6", "claude-haiku-4-5")

  Optional:
  - `:auth_scheme` - `:api_key` (default, sends `x-api-key`) or `:bearer`
    (sends `Authorization: Bearer` for bearer-auth gateways/proxies or OAuth;
    pair with a stable `:origin_key` when passing via `Alloy.run/2`; Anthropic
    OAuth may also require an `anthropic-beta` header via `:extra_headers`)
  - `:origin_key` - Account identifier used for cross-origin provenance hashing
    (required for function `:api_key` and `auth_scheme: :bearer`; recommended
    for static keys when persisting transcripts with file attachments across key rotation)
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
  - `:web_search` - `true` or config map to append Anthropic's web search tool
    (defaults to `type: "web_search_20260209"`, `name: "web_search"`; override
    with `web_search: %{type: "web_search_20250305"}` on older models)
  - `:cache` - `true` / `"5m"` / `%{ttl: "5m"}` for 5-minute ephemeral prompt
    caching, `"1h"` / `%{ttl: "1h"}` for 1-hour TTL, or `false` (default)
  - `:reasoning` - portable reasoning config (`nil | :off | :low | :medium |
    :high | :xhigh | %{effort: ..., display: :summarized | :omitted}`). `:off`
    sends `thinking: %{"type" => "disabled"}` (note: models that cannot disable
    thinking reject `"disabled"`, so pass `reasoning: nil` or override via
    `:extra_body`); `:low`..`:xhigh` send `thinking: %{"type" => "adaptive"}`
    and `output_config.effort` (`:xhigh` maps to `"max"`). Explicit `:extra_body`
    takes precedence.
  - `:server_tools` - Raw tool maps sent after Alloy's own tools, for
    Anthropic-run tools such as web search, web fetch, tool search or an
    `mcp_toolset` (default: `[]`). For example
    `[%{"type" => "web_search_20260209", "name" => "web_search"}]`. Add any
    request fields or beta headers they need through `:extra_body` and
    `:extra_headers`.
  - `:req_options` - Additional options passed to Req (useful for testing)
  - `:on_event` - Streaming event callback `(event -> :ok)`. Called for each
    streaming delta. When used via `Alloy.stream/3`, `event` is a
    normalized envelope map:
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :text_delta, payload: text}`
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :thinking_delta, payload: text}`
      - `%{v: 1, seq:, correlation_id:, turn:, ts_ms:, event: :tool_call_delta, payload: %{id:, index:, name:, arguments_delta:}}`
    Pass it as the `:on_event` option of `Alloy.stream/3`.
    Note: direct callers of `Alloy.Provider.Anthropic.stream/4` (without Turn)
    receive provider-native tuples (for example `{:thinking_delta, text}` and
    `{:tool_call_delta, %{id:, index:, name:, arguments_delta:}}`).
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

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, OutputSchema}
  alias Alloy.Provider
  alias Alloy.Provider.Anthropic.Stream, as: AnthropicStream
  alias Alloy.Provider.{Auth, Error, HTTP}

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
  @context_management_beta "context-management-2025-06-27"
  @files_api_beta "files-api-2025-04-14"
  @web_search_tool_type "web_search_20260209"

  @typedoc """
  Configuration for the Anthropic provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => Alloy.Provider.api_key(),
          required(:model) => String.t(),
          optional(:auth_scheme) => :api_key | :bearer,
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:api_version) => String.t(),
          optional(:origin_key) => String.t(),
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:server_tools) => [map()],
          optional(:web_search) => boolean() | map(),
          optional(:req_options) => keyword(),
          optional(:on_event) => (term() -> :ok),
          optional(:cache) => boolean() | String.t() | map(),
          optional(:reasoning) => Alloy.Provider.reasoning(),
          optional(:code_execution) => boolean(),
          optional(:provider_state) => map()
        }

  @impl true
  @spec complete([Message.t()], [Provider.tool_def()], config()) ::
          {:ok, Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    with {:ok, auth_scheme} <- Auth.resolve_auth_scheme(config),
         {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- Auth.resolve_api_key(config),
         {:ok, resp_body} <-
           HTTP.post_json(
             messages_url(config),
             build_headers(config, api_key, auth_scheme, body),
             body,
             Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ),
         {:ok, decoded} <- HTTP.decode_response_body(resp_body) do
      parse_response(decoded)
    end
  end

  @doc """
  Stream a completion using Anthropic's SSE streaming API.

  Calls `on_chunk` for each text delta as it arrives. Accumulates all
  content blocks and returns the same `{:ok, completion_response()}` shape
  as `complete/3` once the stream finishes.
  """
  @impl true
  @spec stream([Message.t()], [Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    on_event = Map.get(config, :on_event, fn _ -> :ok end)

    with {:ok, auth_scheme} <- Auth.resolve_auth_scheme(config),
         {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- Auth.resolve_api_key(config),
         body = Map.put(body, "stream", true),
         {:ok, sse_acc} <-
           HTTP.stream_sse(
             messages_url(config),
             build_headers(config, api_key, auth_scheme, body),
             body,
             AnthropicStream.initial_acc(on_chunk, on_event),
             &AnthropicStream.handle_raw_event/2,
             Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ),
         {:ok, raw_message} <- AnthropicStream.assemble_message(sse_acc) do
      message_response(raw_message)
    end
  end

  defp messages_url(config),
    do: HTTP.join_url(Map.get(config, :api_url, @default_api_url), "/v1/messages")

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    reject_extended_thinking!(config)

    with {:ok, cache_control} <- normalize_cache(config),
         {:ok, reasoning} <- Provider.normalize_reasoning(Map.get(config, :reasoning)) do
      body = %{
        "model" => config.model,
        "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
        "messages" => Enum.map(messages, &format_message/1)
      }

      body = maybe_add_cache_to_conversation_tail(body, cache_control)

      body =
        case Map.get(config, :system_prompt) do
          nil ->
            body

          prompt when is_map(cache_control) ->
            Map.put(body, "system", [
              %{
                "type" => "text",
                "text" => prompt,
                "cache_control" => cache_control
              }
            ])

          prompt ->
            Map.put(body, "system", prompt)
        end

      client_tools =
        tool_defs
        |> Enum.map(&format_tool_def/1)
        |> maybe_add_cache_to_last_tool(cache_control)

      extra_server_tools = server_tools(config)

      search_tools =
        if Enum.any?(extra_server_tools, &(Map.get(&1, "name") == "web_search")) do
          []
        else
          web_search_tools(config)
        end

      tools =
        client_tools ++
          code_execution_tools(config) ++ search_tools ++ extra_server_tools

      extra_body = HTTP.stringify_extra_body(Map.get(config, :extra_body, %{}))

      body =
        body
        |> HTTP.maybe_put_unless_empty_list("tools", tools)
        |> maybe_put_container(config)
        |> maybe_put_output_schema(config)
        |> maybe_put_reasoning(reasoning, extra_body)

      {:ok, HTTP.merge_extra_body(body, extra_body, "output_config")}
    end
  end

  defp maybe_put_reasoning(body, nil, _extra_body), do: body

  defp maybe_put_reasoning(body, reasoning, extra_body) do
    if Map.has_key?(extra_body, "thinking") do
      body
    else
      put_reasoning_fields(body, reasoning)
    end
  end

  defp put_reasoning_fields(body, %{effort: :off}) do
    Map.put(body, "thinking", %{"type" => "disabled"})
  end

  defp put_reasoning_fields(body, %{effort: effort, display: display}) do
    thinking =
      %{"type" => "adaptive"}
      |> HTTP.maybe_put("display", anthropic_reasoning_display(display))

    output_config =
      body
      |> Map.get("output_config", %{})
      |> Map.put("effort", anthropic_reasoning_effort(effort))

    body
    |> Map.put("thinking", thinking)
    |> Map.put("output_config", output_config)
  end

  defp anthropic_reasoning_effort(:low), do: "low"
  defp anthropic_reasoning_effort(:medium), do: "medium"
  defp anthropic_reasoning_effort(:high), do: "high"
  defp anthropic_reasoning_effort(:xhigh), do: "max"

  defp anthropic_reasoning_display(:summarized), do: "summarized"
  defp anthropic_reasoning_display(:omitted), do: "omitted"
  defp anthropic_reasoning_display(nil), do: nil

  defp normalize_cache(config) do
    case Map.get(config, :cache, false) do
      val when val in [false, nil] ->
        {:ok, nil}

      val when val in [true, "5m"] ->
        {:ok, %{"type" => "ephemeral"}}

      "1h" ->
        {:ok, %{"type" => "ephemeral", "ttl" => "1h"}}

      %{ttl: "5m"} ->
        {:ok, %{"type" => "ephemeral"}}

      %{"ttl" => "5m"} ->
        {:ok, %{"type" => "ephemeral"}}

      %{ttl: "1h"} ->
        {:ok, %{"type" => "ephemeral", "ttl" => "1h"}}

      %{"ttl" => "1h"} ->
        {:ok, %{"type" => "ephemeral", "ttl" => "1h"}}

      other ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "Invalid :cache for Anthropic: expected boolean, \"5m\", \"1h\", or %{ttl: \"5m\" | \"1h\"}, got #{Sanitize.inspect_bounded(other)}"
         }}
    end
  end

  defp maybe_put_output_schema(body, config) do
    case Map.get(config, :output_schema) do
      nil ->
        body

      %OutputSchema{schema: schema} ->
        Map.put(body, "output_config", %{
          "format" => %{"type" => "json_schema", "schema" => schema}
        })
    end
  end

  # Ignoring the removed option would silently turn thinking off.
  defp reject_extended_thinking!(%{extended_thinking: _opts}) do
    raise ArgumentError,
          ":extended_thinking was removed in Alloy 0.13. Configure thinking through " <>
            ":extra_body, for example extra_body: %{\"thinking\" => %{\"type\" => \"adaptive\"}}"
  end

  defp reject_extended_thinking!(_config), do: :ok

  defp code_execution_tools(%{code_execution: true}),
    do: [%{"type" => @code_execution_tool_type, "name" => "code_execution"}]

  defp code_execution_tools(_config), do: []

  defp web_search_tools(%{web_search: true}),
    do: [%{"type" => @web_search_tool_type, "name" => "web_search"}]

  defp web_search_tools(%{web_search: cfg}) when is_map(cfg) and not is_struct(cfg) do
    [
      cfg
      |> Provider.stringify_keys()
      |> Map.put_new("type", @web_search_tool_type)
      |> Map.put_new("name", "web_search")
    ]
  end

  defp web_search_tools(_config), do: []

  # Anthropic runs these tools itself, so they are sent exactly as given.
  defp server_tools(config),
    do: config |> Map.get(:server_tools, []) |> Provider.stringify_keys()

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

  defp build_headers(config, api_key, auth_scheme, body) do
    {user_betas, other_headers} =
      config
      |> Map.get(:extra_headers, [])
      |> Enum.split_with(fn {name, _value} -> String.downcase(name) == "anthropic-beta" end)

    betas = Enum.map(user_betas, fn {_name, value} -> value end) ++ required_betas(body)

    [
      Auth.auth_header(api_key, auth_scheme, "x-api-key"),
      {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
      {"content-type", "application/json"}
    ] ++ beta_header(betas) ++ other_headers
  end

  # Code execution, memory, tool search and tool use examples went GA on
  # 2026-02-17 and need no header; context editing and Files API require betas.
  defp required_betas(body) do
    betas = []

    betas =
      if Map.has_key?(body, "context_management"),
        do: [@context_management_beta | betas],
        else: betas

    betas = if has_file_document?(body), do: [@files_api_beta | betas], else: betas
    Enum.reverse(betas)
  end

  defp has_file_document?(%{"messages" => messages}) when is_list(messages) do
    Enum.any?(messages, fn
      %{"content" => blocks} when is_list(blocks) ->
        Enum.any?(blocks, &match?(%{"type" => "document", "source" => %{"type" => "file"}}, &1))

      _ ->
        false
    end)
  end

  defp has_file_document?(_body), do: false

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

  defp maybe_add_cache_to_conversation_tail(body, nil), do: body

  defp maybe_add_cache_to_conversation_tail(%{"messages" => []} = body, _cache_control), do: body

  defp maybe_add_cache_to_conversation_tail(%{"messages" => messages} = body, cache_control) do
    {init, [last]} = Enum.split(messages, -1)
    Map.put(body, "messages", init ++ [add_cache_to_message_tail(last, cache_control)])
  end

  defp add_cache_to_message_tail(%{"content" => content} = message, cache_control)
       when is_binary(content) do
    Map.put(message, "content", [
      %{"type" => "text", "text" => content, "cache_control" => cache_control}
    ])
  end

  defp add_cache_to_message_tail(%{"content" => blocks} = message, cache_control)
       when is_list(blocks) and blocks != [] do
    Map.put(
      message,
      "content",
      put_cache_on_last(blocks, &cacheable_message_block?/1, cache_control)
    )
  end

  defp add_cache_to_message_tail(message, _cache_control), do: message

  # Marks the last item that may carry a breakpoint; none if no item may.
  defp put_cache_on_last(items, cacheable?, cache_control) do
    {items, _added?} =
      items
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn
        item, false ->
          if cacheable?.(item) do
            {Map.put(item, "cache_control", cache_control), true}
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
       when type in ["server_tool_result", "reasoning", "output_item", "gemini_part"],
       do: true

  defp unsendable_block?(%{type: "thinking", thinking: thinking} = block),
    do: not signed?(block) and String.trim(thinking) == ""

  defp unsendable_block?(_block), do: false

  defp signed?(%{signature: signature}) when is_binary(signature) and signature != "", do: true
  defp signed?(_block), do: false

  defp format_content_block(%{type: "thinking", thinking: thinking, signature: signature})
       when is_binary(signature) and signature != "",
       do: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}

  # The API requires a signature on every thinking block. Unsigned thinking
  # (written by hand, or by a reasoning model behind OpenAICompat) is kept
  # as text rather than failing the request.
  defp format_content_block(%{type: "thinking", thinking: thinking}),
    do: %{"type" => "text", "text" => thinking}

  defp format_content_block(%{type: "text", text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: "tool_use", id: id, name: name, input: input} = block) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    |> HTTP.maybe_put("caller", block[:caller])
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

  defp format_content_block(%{type: "image", url: url}) when is_binary(url) do
    if HTTP.public_http_url?(url) do
      %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
    else
      %{"type" => "text", "text" => "[Unsupported image URL scheme for Anthropic provider]"}
    end
  end

  # Anthropic does not support audio or video inline. Convert to a text notice
  # so the conversation can continue without crashing the turn loop.
  defp format_content_block(%{type: type}) when type in ["audio", "video"] do
    %{"type" => "text", "text" => "[Unsupported media type for Anthropic provider: #{type}]"}
  end

  defp format_content_block(%{type: "document", mime_type: "application/pdf", data: data} = block)
       when is_binary(data) do
    document_block(
      %{"type" => "base64", "media_type" => "application/pdf", "data" => data},
      block
    )
  end

  defp format_content_block(%{type: "document", mime_type: "text/plain", data: data} = block)
       when is_binary(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, decoded} ->
        if String.valid?(decoded) do
          document_block(
            %{"type" => "text", "media_type" => "text/plain", "data" => decoded},
            block
          )
        else
          unsupported_inline_document_notice("text/plain")
        end

      :error ->
        unsupported_inline_document_notice("text/plain")
    end
  end

  defp format_content_block(%{type: "document", mime_type: mime_type, data: data})
       when is_binary(mime_type) and is_binary(data) do
    unsupported_inline_document_notice(mime_type)
  end

  defp format_content_block(%{type: "document", file_id: file_id} = block)
       when is_binary(file_id) do
    document_block(%{"type" => "file", "file_id" => file_id}, block)
  end

  defp format_content_block(%{type: "document", mime_type: "application/pdf", uri: uri} = block)
       when is_binary(uri) do
    if HTTP.public_http_url?(uri) do
      document_block(%{"type" => "url", "url" => uri}, block)
    else
      %{
        "type" => "text",
        "text" =>
          "[Unsupported document URI (application/pdf) for Anthropic provider: use HTTPS URL, base64 data, or Files API]"
      }
    end
  end

  defp format_content_block(%{type: "document", uri: uri} = block) when is_binary(uri) do
    mime = Map.get(block, :mime_type, "document")

    %{
      "type" => "text",
      "text" =>
        "[Unsupported document URI (#{mime}) for Anthropic provider: URL documents require application/pdf over HTTPS]"
    }
  end

  defp format_content_block(%{type: "document", mime_type: mime_type}) do
    unsupported_inline_document_notice(mime_type)
  end

  defp format_content_block(block) when is_map(block) do
    # Pass through any other block types as-is, converting atom keys to strings
    Map.new(block, fn {k, v} -> {to_string(k), v} end)
  end

  defp document_block(source, block) do
    %{"type" => "document", "source" => source}
    |> HTTP.maybe_put("title", block[:title] || block[:filename])
  end

  defp unsupported_inline_document_notice(mime_type) do
    %{
      "type" => "text",
      "text" =>
        "[Unsupported inline document (#{mime_type}) for Anthropic provider: base64 documents require application/pdf, or use text/plain or the Files API]"
    }
  end

  defp maybe_add_cache_to_last_tool(tools, nil), do: tools

  defp maybe_add_cache_to_last_tool(tools, cache_control),
    do: put_cache_on_last(tools, &cacheable_tool?/1, cache_control)

  # The API rejects cache_control on a tool with defer_loading: true.
  defp cacheable_tool?(%{"defer_loading" => true}), do: false
  defp cacheable_tool?(_tool), do: true

  # An Anthropic-defined client tool, such as the memory tool, is sent as its
  # type: the model already knows its schema, and the client still runs it.
  defp format_tool_def(%{name: name, native_types: %{anthropic: type}}),
    do: %{"type" => type, "name" => name}

  defp format_tool_def(%{name: name, description: desc, input_schema: schema} = def_map) do
    input_examples = Map.get(def_map, :input_examples)
    allowed_callers = Map.get(def_map, :allowed_callers)

    %{
      "name" => name,
      "description" => desc,
      "input_schema" => Provider.stringify_keys(schema)
    }
    |> HTTP.maybe_put("strict", if(Map.get(def_map, :strict) == true, do: true))
    |> HTTP.maybe_put("input_examples", if(is_list(input_examples), do: input_examples))
    |> HTTP.maybe_put("defer_loading", if(Map.get(def_map, :defer_loading) == true, do: true))
    |> HTTP.maybe_put(
      "allowed_callers",
      if(is_list(allowed_callers), do: Enum.map(allowed_callers, &allowed_caller/1))
    )
  end

  # Alloy's :human and :code_execution predate the API's caller names.
  defp allowed_caller(caller) when caller in [:human, :direct], do: "direct"
  defp allowed_caller(:code_execution), do: @code_execution_caller
  defp allowed_caller(caller), do: to_string(caller)

  # --- Response Parsing ---

  defp parse_response(%{"type" => "message"} = resp), do: message_response(resp)

  defp parse_response(%{"type" => "error"} = resp), do: {:error, Error.from_body(resp)}

  defp parse_response(resp) do
    {:error,
     %Error{
       kind: :unknown,
       message: "Unexpected Anthropic response payload: #{Sanitize.inspect_bounded(resp)}"
     }}
  end

  # The HTTP status was already 200 when the failure arrived in the body or
  # the stream, so it is classified by its error type: overloaded_error
  # becomes :overloaded, which Retry retries like an HTTP 529.
  # Shared by complete/3 and stream/4: `resp` is a Messages API message, or
  # the equivalent assembled from stream events.
  defp message_response(resp) do
    stop_reason = parse_stop_reason(resp["stop_reason"])

    with {:ok, blocks} <- parse_content_blocks(resp["content"] || [], stop_reason) do
      response =
        %{
          stop_reason: stop_reason,
          messages: [%Message{role: :assistant, content: blocks}],
          usage: parse_usage(resp["usage"] || %{})
        }
        |> HTTP.maybe_put(:response_metadata, response_metadata(resp))
        |> HTTP.maybe_put(:provider_state, provider_state(resp))

      {:ok, response}
    end
  end

  # Turn feeds provider_state back in config, so the next request reuses
  # the container (see maybe_put_container/2).
  defp provider_state(%{"container" => %{"id" => id} = container}) when is_binary(id),
    do: HTTP.maybe_put(%{container_id: id}, :container_expires_at, container["expires_at"])

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

  defp parse_content_blocks(blocks, :refusal) when is_list(blocks) do
    {:ok, Enum.map(blocks, &parse_refusal_block/1)}
  end

  defp parse_content_blocks(blocks, _stop_reason) when is_list(blocks) do
    HTTP.map_ok(blocks, &parse_content_block/1)
  end

  defp parse_content_blocks(_non_list, _stop_reason) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Invalid content list in Anthropic response"
     }}
  end

  defp parse_refusal_block(block) do
    case parse_content_block(block) do
      {:ok, parsed} -> parsed
      {:error, _} -> preserve_unknown_block(block)
    end
  end

  defp parse_content_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) do
    case Map.get(block, "signature") do
      sig when is_nil(sig) or is_binary(sig) ->
        {:ok, %{type: "thinking", thinking: thinking} |> HTTP.maybe_put(:signature, sig)}

      _invalid ->
        {:error,
         %Error{kind: :protocol_error, message: "Invalid thinking block in Anthropic response"}}
    end
  end

  defp parse_content_block(%{"type" => "thinking"}) do
    {:error,
     %Error{kind: :protocol_error, message: "Invalid thinking block in Anthropic response"}}
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    {:ok, %{type: "text", text: text}}
  end

  defp parse_content_block(%{"type" => "text"}) do
    {:error, %Error{kind: :protocol_error, message: "Invalid text block in Anthropic response"}}
  end

  # A programmatic call's `caller` must go back unchanged with the history.
  defp parse_content_block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block
       )
       when is_binary(id) and is_binary(name) and is_map(input) do
    {:ok,
     %{type: "tool_use", id: id, name: name, input: input}
     |> HTTP.maybe_put(:caller, block["caller"])}
  end

  defp parse_content_block(%{"type" => "tool_use"}) do
    {:error,
     %Error{kind: :protocol_error, message: "Invalid tool_use block in Anthropic response"}}
  end

  defp parse_content_block(%{
         "type" => "server_tool_use",
         "id" => id,
         "name" => name,
         "input" => input
       })
       when is_binary(id) and is_binary(name) and is_map(input) do
    {:ok, %{type: "server_tool_use", id: id, name: name, input: input}}
  end

  defp parse_content_block(%{"type" => "server_tool_use"}) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Invalid server_tool_use block in Anthropic response"
     }}
  end

  defp parse_content_block(block) when is_map(block), do: {:ok, preserve_unknown_block(block)}

  defp parse_content_block(_non_map) do
    {:error,
     %Error{kind: :protocol_error, message: "Invalid content block in Anthropic response"}}
  end

  defp preserve_unknown_block(block) when is_map(block) do
    # Unknown block type — preserve with string keys to avoid atom table
    # pollution from untrusted API responses. Only convert known keys.
    type = Map.get(block, "type", "unknown")
    %{type: type} |> Map.merge(Map.delete(block, "type"))
  end

  defp preserve_unknown_block(_other), do: %{type: "unknown"}

  defp parse_usage(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens", 0),
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens", 0)
    }
  end
end
