defmodule Alloy.Provider.Gemini do
  @moduledoc """
  Provider for Google's Gemini GenerateContent API.

  Normalizes Gemini's `contents` / `parts` wire format to Alloy messages,
  including function calling and thinking-part round-tripping.

  ## Config

  Required:
  - `:api_key` - Gemini API key string, or a 0-arity callback returning
    `String.t() | {:ok, String.t()} | {:error, term()}` invoked per HTTP
    attempt (inside a bounded worker when `:timeout_ms` is finite or
    `:cancel_token` is set).
    When passing a callback via `Alloy.run/2`, also set `:origin_key` to a
    stable non-empty string for account isolation.
  - `:model` - Model name, for example `"gemini-3.8-flash"` or
    `"gemini-3.5-flash-lite"`. Gemini 2.5 models are open only to projects
    that already used them.

  Optional:
  - `:auth_scheme` - `:api_key` (default, sends `x-goog-api-key`) or `:bearer`
    (sends `Authorization: Bearer` for Google OAuth / ADC access tokens; pair
    with a stable `:origin_key` when passing via `Alloy.run/2`)
  - `:origin_key` - Account identifier used for cross-origin provenance hashing
    (required for function `:api_key` and `auth_scheme: :bearer`; recommended
    for static keys when persisting transcripts with file attachments across key rotation)
  - `:cached_content` - Gemini cached content resource name
    (e.g. `"cachedContents/..."`). Because Gemini requires `systemInstruction`,
    `tools`, and `toolConfig` to be baked into the cached content resource,
    setting `:cached_content` omits `systemInstruction` and `functionDeclarations`
    from the wire body (while keeping `Alloy.run/2` local tool handlers active)
    and rejects explicit provider-level `:tool_config`, `:google_search`,
    `:url_context`, or `:code_execution` conflicts.
  - `:google_search` - `true` or config map to enable Google Search grounding
  - `:url_context` - `true` or config map to enable URL context retrieval
  - `:code_execution` - `true` or config map to enable Gemini code execution
  - `:max_tokens` - Max output tokens, sent as `maxOutputTokens`. Thinking
    tokens count against it. When unset, the model's own output limit
    applies (Alloy 0.12.4 and earlier sent `4096`)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: `"https://generativelanguage.googleapis.com"`)
  - `:api_version` - API version path (default: `"v1beta"`)
  - `:generation_config` - Raw Gemini `generationConfig` fields (see Thinking)
  - `:reasoning` - Portable reasoning config (`nil | :off | :low | :medium |
    :high | :xhigh | %{effort: ..., display: :summarized | :omitted}`). `:off`
    sends `thinkingConfig.thinkingBudget: 0`; `:low`..`:xhigh` send
    `thinkingConfig.thinkingLevel` (`:xhigh` maps to `"HIGH"`) and optional
    `includeThoughts`. Explicit `:generation_config` or `:extra_body`
    `thinkingConfig` takes precedence (see Thinking).
  - `:tool_config` - Raw Gemini `toolConfig`
  - `:safety_settings` - Raw Gemini `safetySettings`
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:extra_body` - Additional top-level request body fields, merged last with
    stringified keys (`"generationConfig"` is merged one level deep so sibling
    caller keys coexist with `:max_tokens` / `:output_schema` while explicit
    caller keys win)
  - `:req_options` - Additional options passed to Req

  ## Thinking

  Gemini 3 models think by default. Set the depth with `thinkingLevel`
  (`"MINIMAL"`, `"LOW"`, `"MEDIUM"` or `"HIGH"`; each model accepts a
  subset) under `thinkingConfig`. `thinkingBudget`, a token count, is the
  older control: Gemini 2.5 models need it, and Gemini 3 still accepts it.
  Never send both; the API rejects the request. Portable `:reasoning` maps
  `:off` to `thinkingBudget: 0` and `:low..:xhigh` to `thinkingLevel` (so
  when targeting Gemini 2.5, pass explicit `generation_config: %{"thinkingConfig" => %{"thinkingBudget" => ...}}`
  or set `reasoning: nil` on the Gemini provider entry). Thinking tokens are billed
  as output and count against `:max_tokens`, so lower `thinkingLevel`
  rather than `:max_tokens` to save cost. Set `includeThoughts: true` to
  get thought summaries back as `"thinking"` blocks.

  ## Stop reasons

  `MAX_TOKENS` maps to `:max_tokens`. Safety, recitation and other content
  filters, and blocked prompts, map to `:refusal`, with the reason in
  `response_metadata.stop_details`. A malformed or unexpected function call
  returns `{:error, %Alloy.Provider.Error{}}`, which the loop retries
  unless output was already streamed.

  ## Example

      Alloy.run("Summarize this code.",
        provider: {Alloy.Provider.Gemini,
          api_key: System.get_env("GEMINI_API_KEY"),
          model: "gemini-3.8-flash",
          generation_config: %{thinkingConfig: %{thinkingLevel: "LOW"}}
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, OutputSchema}
  alias Alloy.Provider
  alias Alloy.Provider.{Auth, Error, HTTP}
  alias Alloy.Provider.Gemini.Stream, as: GeminiStream

  @placeholder_thought_signature "skip_thought_signature_validator"

  @default_api_url "https://generativelanguage.googleapis.com"
  @default_api_version "v1beta"

  # finishReason values, from ai.google.dev/api/generate-content#FinishReason.
  # Content filters and policy blocks: the output must not be used.
  @refusal_reasons ~w(SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII
                      IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_RECITATION IMAGE_OTHER
                      ESCALATION PUP_LIMITED_DISABLED)
  # The model produced output that cannot be used; sampling again usually
  # succeeds, so these are retried like a server error.
  @generation_errors ~w(MALFORMED_FUNCTION_CALL MALFORMED_RESPONSE UNEXPECTED_TOOL_CALL
                        TOO_MANY_TOOL_CALLS NO_IMAGE)
  @error_finish_reasons @generation_errors ++ ["MISSING_THOUGHT_SIGNATURE"]

  @typedoc """
  Configuration for the Gemini provider. See the module doc for field
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
          optional(:cached_content) => String.t(),
          optional(:google_search) => boolean() | map(),
          optional(:url_context) => boolean() | map(),
          optional(:code_execution) => boolean() | map(),
          optional(:generation_config) => map() | keyword() | nil,
          optional(:reasoning) => Alloy.Provider.reasoning(),
          optional(:on_event) => (term() -> :ok),
          optional(:tool_config) => map(),
          optional(:safety_settings) => [map()],
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:req_options) => keyword()
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
             request_url(config, "generateContent"),
             build_headers(config, api_key, auth_scheme),
             body,
             Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ),
         {:ok, decoded} <- Provider.decode_body(resp_body) do
      parse_response(decoded)
    end
  end

  @impl true
  @spec stream([Message.t()], [Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    initial_acc =
      GeminiStream.initial_acc(
        on_chunk,
        Map.get(config, :on_event, fn _ -> :ok end),
        &extract_candidate_blocks/1,
        @error_finish_reasons
      )

    with {:ok, auth_scheme} <- Auth.resolve_auth_scheme(config),
         {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- Auth.resolve_api_key(config),
         {:ok, acc} <-
           HTTP.stream_sse(
             request_url(config, "streamGenerateContent"),
             build_headers(config, api_key, auth_scheme),
             body,
             initial_acc,
             &GeminiStream.handle_event/2,
             [params: [alt: "sse"]] ++ Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ),
         {:ok, outcome} <- GeminiStream.finalize(acc) do
      case outcome do
        {:prompt_blocked, resp} -> prompt_blocked(resp)
        {:candidate, blocks, candidate, resp} -> respond(blocks, candidate, resp)
      end
    end
  end

  defp request_url(config, method) do
    api_url = Map.get(config, :api_url, @default_api_url)
    api_version = Map.get(config, :api_version, @default_api_version)
    model = normalize_model(Map.fetch!(config, :model))

    HTTP.join_url(api_url, "/#{api_version}/models/#{model}:#{method}")
  end

  defp normalize_model("models/" <> model), do: model
  defp normalize_model(model), do: model

  defp build_headers(config, api_key, auth_scheme) do
    [
      Auth.auth_header(api_key, auth_scheme, "x-goog-api-key"),
      {"x-goog-api-client", "alloy/#{Application.spec(:alloy, :vsn) |> to_string()}"},
      {"content-type", "application/json"}
    ] ++ Map.get(config, :extra_headers, [])
  end

  defp build_request_body(messages, tool_defs, config) do
    cached_content =
      case Map.get(config, :cached_content) do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    body =
      %{"contents" => build_contents(messages)}
      |> HTTP.maybe_put("cachedContent", cached_content)

    body =
      case {cached_content, Map.get(config, :system_prompt)} do
        {nil, prompt} when is_binary(prompt) and prompt != "" ->
          Map.put(body, "systemInstruction", %{"parts" => [%{"text" => prompt}]})

        _other ->
          body
      end

    output_schema = Map.get(config, :output_schema)

    with {:ok, raw_generation_config} <- normalize_generation_config(config),
         {:ok, reasoning} <- Provider.normalize_reasoning(Map.get(config, :reasoning)),
         :ok <- validate_cached_content_config(cached_content, config) do
      extra_body = HTTP.stringify_extra_body(Map.get(config, :extra_body, %{}))
      extra_gen_cfg = Map.get(extra_body, "generationConfig")

      # No default maxOutputTokens: the budget includes thinking, so a fixed
      # default truncates thinking models; each model's own limit is larger.
      generation_config =
        raw_generation_config
        |> HTTP.maybe_put_new("maxOutputTokens", Map.get(config, :max_tokens))
        |> maybe_put_reasoning(reasoning, extra_gen_cfg)
        |> maybe_put_output_schema(output_schema)

      body = HTTP.maybe_put_unless_empty_map(body, "generationConfig", generation_config)

      # When :cached_content is set, Gemini requires tools and toolConfig to
      # live inside the cached resource; omit client functionDeclarations from
      # the wire body while Alloy still dispatches returned calls locally.
      body =
        if is_nil(cached_content) do
          {tools, has_native_tools?} = build_tools(tool_defs, config)
          tool_config = build_tool_config(config, tool_defs != [] and has_native_tools?)

          body
          |> HTTP.maybe_put_unless_empty_list("tools", tools)
          |> HTTP.maybe_put_unless_empty_map("toolConfig", tool_config)
        else
          body
        end

      body =
        case Map.get(config, :safety_settings) do
          nil -> body
          settings -> Map.put(body, "safetySettings", Provider.stringify_keys(settings))
        end

      body =
        HTTP.merge_extra_body(
          body,
          extra_body,
          "generationConfig"
        )

      with :ok <- validate_cached_content_conflicts(body),
           :ok <- validate_tool_config_conflicts(body) do
        validate_output_schema_conflicts(body, raw_generation_config, output_schema)
      end
    end
  end

  defp validate_cached_content_config(nil, _config), do: :ok

  defp validate_cached_content_config(_cached_content, config) do
    has_conflict? =
      not is_nil(Map.get(config, :tool_config)) or
        truthy_tool?(Map.get(config, :google_search)) or
        truthy_tool?(Map.get(config, :url_context)) or
        truthy_tool?(Map.get(config, :code_execution))

    if has_conflict? do
      {:error,
       %Error{
         kind: :invalid_request,
         message:
           "Gemini :cached_content cannot be combined with :tool_config, :google_search, :url_context, or :code_execution; include them in the cached content resource instead"
       }}
    else
      :ok
    end
  end

  defp truthy_tool?(true), do: true
  defp truthy_tool?(cfg) when is_map(cfg) and not is_struct(cfg), do: true
  defp truthy_tool?(_other), do: false

  defp build_tools(tool_defs, config) do
    fn_tools =
      case tool_defs do
        [] -> []
        defs -> [%{"functionDeclarations" => Enum.map(defs, &format_tool_def/1)}]
      end

    native_tools =
      []
      |> maybe_append_native_tool("googleSearch", Map.get(config, :google_search))
      |> maybe_append_native_tool("urlContext", Map.get(config, :url_context))
      |> maybe_append_native_tool("codeExecution", Map.get(config, :code_execution))

    {fn_tools ++ native_tools, native_tools != []}
  end

  defp build_tool_config(config, combine_server_and_custom?) do
    base =
      case Map.get(config, :tool_config) do
        nil -> %{}
        tool_config -> Provider.stringify_keys(tool_config)
      end

    already_configured? =
      Map.has_key?(base, "includeServerSideToolInvocations") or
        Map.has_key?(base, "include_server_side_tool_invocations")

    if combine_server_and_custom? and not already_configured? do
      Map.put(base, "includeServerSideToolInvocations", true)
    else
      base
    end
  end

  # Gemini rejects generateContent requests that pass cachedContent together
  # with systemInstruction, tools, or toolConfig (they belong in the cache).
  defp validate_cached_content_conflicts(%{"cachedContent" => _} = body) do
    if Enum.any?(["systemInstruction", "tools", "toolConfig"], &Map.has_key?(body, &1)) do
      {:error,
       %Error{
         kind: :invalid_request,
         message:
           "Gemini :cached_content cannot be combined with :system_prompt, tools, or :tool_config; include them in the cached content resource instead"
       }}
    else
      :ok
    end
  end

  defp validate_cached_content_conflicts(_body), do: :ok

  # Google excludes functionCallingConfig.mode "AUTO" when server-side and
  # custom tools are combined via includeServerSideToolInvocations: true.
  defp validate_tool_config_conflicts(%{"toolConfig" => tool_config})
       when is_map(tool_config) do
    include_server? =
      Map.get(tool_config, "includeServerSideToolInvocations") == true or
        Map.get(tool_config, "include_server_side_tool_invocations") == true

    fc_config =
      Map.get(tool_config, "functionCallingConfig") ||
        Map.get(tool_config, "function_calling_config")

    if include_server? and is_map(fc_config) and Map.get(fc_config, "mode") == "AUTO" do
      {:error,
       %Error{
         kind: :invalid_request,
         message:
           "Gemini tool combination (includeServerSideToolInvocations: true) is incompatible with functionCallingConfig mode \"AUTO\"; use \"VALIDATED\" or omit mode instead"
       }}
    else
      :ok
    end
  end

  defp validate_tool_config_conflicts(_body), do: :ok

  defp maybe_put_output_schema(generation_config, nil), do: generation_config

  defp maybe_put_output_schema(generation_config, %OutputSchema{schema: schema}) do
    generation_config
    |> HTTP.maybe_put_new("responseMimeType", "application/json")
    |> Map.put("responseJsonSchema", schema)
  end

  defp validate_output_schema_conflicts(body, _raw_generation_config, nil), do: {:ok, body}

  defp validate_output_schema_conflicts(body, raw_generation_config, _spec) do
    if Map.has_key?(raw_generation_config, "responseJsonSchema") do
      {:error,
       %Error{
         kind: :invalid_request,
         message:
           "cannot combine :output_schema with generation_config[\"responseJsonSchema\"] on Gemini (use :output_schema alone, or override via :extra_body)"
       }}
    else
      generation_config = Map.get(body, "generationConfig", %{})
      validate_gemini_generation_config(body, generation_config)
    end
  end

  defp validate_gemini_generation_config(body, generation_config)
       when is_map(generation_config) and not is_struct(generation_config) do
    mime = Map.get(generation_config, "responseMimeType")

    cond do
      Map.has_key?(generation_config, "responseSchema") or
          Map.has_key?(generation_config, "response_schema") ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "cannot combine :output_schema with legacy generationConfig[\"responseSchema\"] on Gemini"
         }}

      Map.has_key?(generation_config, "response_json_schema") or
          Map.has_key?(generation_config, "response_mime_type") ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "cannot combine :output_schema with snake_case generationConfig keys (use camelCase responseMimeType/responseJsonSchema or omit them) on Gemini"
         }}

      mime not in [nil, "application/json"] ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "cannot combine :output_schema with non-JSON generationConfig[\"responseMimeType\"] (#{Sanitize.inspect_bounded(mime)}) on Gemini"
         }}

      true ->
        {:ok, body}
    end
  end

  defp validate_gemini_generation_config(_body, other) do
    {:error,
     %Error{
       kind: :invalid_request,
       message:
         "Invalid extra_body[\"generationConfig\"] on Gemini: expected a map, got #{Sanitize.inspect_bounded(other)}"
     }}
  end

  defp maybe_append_native_tool(tools, key, true), do: tools ++ [%{key => %{}}]

  defp maybe_append_native_tool(tools, key, cfg) when is_map(cfg) and not is_struct(cfg),
    do: tools ++ [%{key => Provider.stringify_keys(cfg)}]

  defp maybe_append_native_tool(tools, _key, _other), do: tools

  defp maybe_put_reasoning(generation_config, nil, _extra_gen_cfg), do: generation_config

  defp maybe_put_reasoning(generation_config, reasoning, extra_gen_cfg) do
    has_explicit_thinking? =
      has_thinking_config?(generation_config) or has_thinking_config?(extra_gen_cfg)

    if has_explicit_thinking? do
      generation_config
    else
      Map.put(generation_config, "thinkingConfig", gemini_thinking_config(reasoning))
    end
  end

  defp has_thinking_config?(map) when is_map(map) and not is_struct(map) do
    normalized = Provider.stringify_keys(map)
    Map.has_key?(normalized, "thinkingConfig") or Map.has_key?(normalized, "thinking_config")
  end

  defp has_thinking_config?(_other), do: false

  defp gemini_thinking_config(%{effort: :off}), do: %{"thinkingBudget" => 0}

  defp gemini_thinking_config(%{effort: effort, display: display}) do
    level =
      case effort do
        :low -> "LOW"
        :medium -> "MEDIUM"
        :high -> "HIGH"
        :xhigh -> "HIGH"
      end

    base = %{"thinkingLevel" => level}

    case display do
      :summarized -> Map.put(base, "includeThoughts", true)
      :omitted -> Map.put(base, "includeThoughts", false)
      nil -> base
    end
  end

  defp normalize_generation_config(config) do
    case Map.get(config, :generation_config) do
      nil ->
        {:ok, %{}}

      map when is_map(map) and not is_struct(map) ->
        {:ok, Provider.stringify_keys(map)}

      list when is_list(list) ->
        if Keyword.keyword?(list),
          do: {:ok, list |> Map.new() |> Provider.stringify_keys()},
          else: invalid_generation_config(list)

      other ->
        invalid_generation_config(other)
    end
  end

  defp invalid_generation_config(value) do
    {:error,
     %Error{
       kind: :invalid_request,
       message:
         "Invalid :generation_config for Gemini: expected a map or keyword list, got #{Sanitize.inspect_bounded(value)}"
     }}
  end

  defp build_contents(messages) do
    tool_names = index_tool_names(messages)
    Enum.map(messages, &format_message(&1, tool_names))
  end

  defp index_tool_names(messages) do
    Enum.reduce(messages, %{}, fn
      %Message{role: :assistant, content: blocks}, acc when is_list(blocks) ->
        blocks
        |> Enum.reverse()
        |> Enum.reduce(acc, fn
          %{type: "tool_use", id: id, name: name}, inner when not is_nil(name) ->
            Map.put(inner, id, name)

          _block, inner ->
            inner
        end)

      _other, acc ->
        acc
    end)
  end

  defp format_message(%Message{role: role, content: content}, _tool_names)
       when is_binary(content) do
    %{"role" => format_role(role), "parts" => [%{"text" => content}]}
  end

  defp format_message(%Message{role: role, content: blocks}, tool_names) when is_list(blocks) do
    parts =
      blocks
      |> Enum.map(fn
        %{type: "tool_result", tool_use_id: id, content: content} = block ->
          format_tool_result_block(id, content, block, tool_names)

        block ->
          format_content_block(block)
      end)
      |> Enum.reject(&is_nil/1)

    %{"role" => format_role(role), "parts" => sign_first_function_call(role, parts)}
  end

  # Gemini 3 rejects a step whose first function call has no thought
  # signature. A call another provider made (or one built by hand) has
  # none, so it gets the placeholder Google documents for history it did
  # not produce. Later calls in a parallel step never carry one.
  # https://docs.cloud.google.com/vertex-ai/generative-ai/docs/thought-signatures
  defp sign_first_function_call(:assistant, parts) do
    case Enum.find_index(parts, &Map.has_key?(&1, "functionCall")) do
      nil ->
        parts

      index ->
        List.update_at(
          parts,
          index,
          &Map.put_new(&1, "thoughtSignature", @placeholder_thought_signature)
        )
    end
  end

  defp sign_first_function_call(:user, parts), do: parts

  defp format_role(:assistant), do: "model"
  defp format_role(:user), do: "user"

  defp format_tool_result_block(id, content, block, tool_names) do
    %{
      "functionResponse" => %{
        "id" => id,
        "name" => Map.get(tool_names, id) || "unknown_tool",
        "response" =>
          normalize_function_response_payload(content, Map.get(block, :is_error, false))
      }
    }
  end

  defp format_content_block(%{type: "thinking", thinking: thinking} = block) do
    %{"text" => thinking, "thought" => true}
    |> maybe_put_signature("thoughtSignature", block[:signature])
  end

  defp format_content_block(%{type: "text", text: text} = block) do
    %{"text" => text}
    |> maybe_put_signature("thoughtSignature", block[:signature])
  end

  defp format_content_block(%{type: "tool_use", id: id, name: name, input: input} = block) do
    %{
      "functionCall" => %{
        "id" => id,
        "name" => name,
        "args" => Provider.stringify_keys(input)
      }
    }
    |> maybe_put_signature("thoughtSignature", block[:signature])
  end

  defp format_content_block(%{type: type, mime_type: mime_type, data: data})
       when type in ["image", "audio", "video", "document"] and is_binary(mime_type) and
              is_binary(data) do
    %{"inlineData" => %{"mimeType" => mime_type, "data" => data}}
  end

  defp format_content_block(%{type: "image", url: url} = block) when is_binary(url) do
    if HTTP.uri_with_scheme?(url, ["http", "https", "gs"]) do
      %{"fileData" => %{"fileUri" => url} |> HTTP.maybe_put("mimeType", block[:mime_type])}
    else
      %{"text" => "[Unsupported image URL scheme for Gemini provider]"}
    end
  end

  defp format_content_block(%{type: "document", mime_type: mime_type, uri: uri}) do
    %{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}}
  end

  defp format_content_block(%{type: "document", mime_type: mime_type, file_id: file_id})
       when is_binary(mime_type) and is_binary(file_id) do
    %{"fileData" => %{"mimeType" => mime_type, "fileUri" => file_id}}
  end

  # Server-side tool / code-execution parts replayed verbatim with signatures.
  defp format_content_block(%{type: "gemini_part", raw: raw}) when is_map(raw), do: raw

  # Opaque OpenAI Responses items in a transcript that switched provider;
  # they mean nothing to Gemini, so they are dropped rather than turned
  # into placeholder text the model would read.
  defp format_content_block(%{type: type}) when type in ["reasoning", "output_item"], do: nil

  defp format_content_block(block) when is_map(block) do
    %{
      "text" =>
        "[Unsupported content block for Gemini provider: #{inspect(Map.get(block, :type) || Map.get(block, "type"))}]"
    }
  end

  # Keep the tool's text intact, including JSON-looking text. Gemini recognizes
  # output/error envelopes; decoding arbitrary tool text changes its framing.
  defp normalize_function_response_payload(content, false), do: %{"output" => content}
  defp normalize_function_response_payload(content, true), do: %{"error" => content}

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "name" => name,
      "description" => desc,
      # JSON Schema keywords such as additionalProperties are not accepted by
      # Gemini's older OpenAPI-shaped parameters field.
      "parametersJsonSchema" => Provider.stringify_keys(schema)
    }
  end

  # Prioritize explicit in-band API errors before candidate parsing so a real
  # error payload is never masked by missing or malformed sibling candidates.
  defp parse_response(%{"error" => error}) when is_map(error) or is_binary(error),
    do: {:error, in_band_error(error)}

  defp parse_response(%{"candidates" => [candidate | _]} = resp) when is_map(candidate) do
    with {:ok, blocks} <- extract_candidate_blocks(candidate) do
      respond(blocks, candidate, resp)
    end
  end

  defp parse_response(%{"candidates" => [_non_map | _]}) do
    {:error, %Error{kind: :protocol_error, message: "Malformed candidate in Gemini response"}}
  end

  defp parse_response(%{"candidates" => candidates})
       when candidates != nil and not is_list(candidates) do
    {:error, %Error{kind: :protocol_error, message: "Malformed candidates in Gemini response"}}
  end

  defp parse_response(%{"promptFeedback" => %{"blockReason" => _}} = resp),
    do: prompt_blocked(resp)

  defp parse_response(other) do
    {:error,
     %Error{
       kind: :unknown,
       message: "Unexpected Gemini response payload: #{Sanitize.inspect_bounded(other)}"
     }}
  end

  # Errors can also arrive in a 200 body: as an SSE chunk mid-stream, or
  # from a proxy. Error.from_body/1 reads Google's numeric HTTP status in
  # "code" (400..599) as well as its "status" label.
  defp in_band_error(error), do: Error.from_body(%{"error" => error})

  defp respond(_blocks, %{"finishReason" => reason} = candidate, _resp)
       when reason in @generation_errors,
       do: {:error, generation_error(:server_error, reason, candidate)}

  defp respond(
         _blocks,
         %{"finishReason" => "MISSING_THOUGHT_SIGNATURE" = reason} = candidate,
         _resp
       ),
       do: {:error, generation_error(:invalid_request, reason, candidate)}

  defp respond(blocks, candidate, resp) do
    {:ok,
     %{
       stop_reason: stop_reason(candidate["finishReason"], blocks),
       messages: [%Message{role: :assistant, content: blocks}],
       usage: parse_usage(resp["usageMetadata"] || %{}),
       response_metadata: build_response_metadata(resp, candidate)
     }}
  end

  # The API returns no candidates only when the prompt itself was blocked.
  defp prompt_blocked(%{"promptFeedback" => %{"blockReason" => _} = feedback} = resp) do
    stop_details = Map.take(feedback, ["blockReason", "safetyRatings"])

    {:ok,
     %{
       stop_reason: :refusal,
       messages: [],
       usage: parse_usage(resp["usageMetadata"] || %{}),
       response_metadata: Map.put(build_response_metadata(resp, %{}), :stop_details, stop_details)
     }}
  end

  defp generation_error(kind, reason, candidate) do
    %Error{
      kind: kind,
      type: reason,
      message: candidate["finishMessage"] || "Gemini stopped without a usable response"
    }
  end

  defp extract_candidate_blocks(candidate) do
    case Map.fetch(candidate, "content") do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, content} when is_map(content) ->
        extract_content_parts(content)

      {:ok, _invalid} ->
        {:error, %Error{kind: :protocol_error, message: "Malformed content in Gemini candidate"}}
    end
  end

  defp extract_content_parts(content) do
    case Map.fetch(content, "parts") do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, parts} when is_list(parts) ->
        parse_content_parts(parts)

      {:ok, _invalid} ->
        {:error,
         %Error{kind: :protocol_error, message: "Malformed parts in Gemini candidate content"}}
    end
  end

  defp parse_content_parts(parts) do
    HTTP.map_ok(parts, &parse_content_part/1)
  end

  defp parse_content_part(%{"text" => text, "thought" => true} = part) when is_binary(text) do
    {:ok,
     %{type: "thinking", thinking: text}
     |> maybe_put_signature(:signature, part["thoughtSignature"])}
  end

  defp parse_content_part(%{"text" => text} = part) when is_binary(text) do
    {:ok,
     %{type: "text", text: text}
     |> maybe_put_signature(:signature, part["thoughtSignature"])}
  end

  defp parse_content_part(%{"functionCall" => %{"name" => name} = call} = part)
       when is_binary(name) and name != "" do
    id =
      case call["id"] do
        id when is_binary(id) and id != "" -> id
        _ -> generated_tool_call_id(name)
      end

    case Map.get(call, "args") do
      nil ->
        {:ok,
         %{type: "tool_use", id: id, name: name, input: %{}}
         |> maybe_put_signature(:signature, part["thoughtSignature"])}

      args when is_map(args) ->
        {:ok,
         %{type: "tool_use", id: id, name: name, input: args}
         |> maybe_put_signature(:signature, part["thoughtSignature"])}

      _invalid ->
        {:error,
         %Error{kind: :protocol_error, message: "Malformed functionCall args in Gemini response"}}
    end
  end

  defp parse_content_part(%{"functionCall" => _invalid}) do
    {:error, %Error{kind: :protocol_error, message: "Malformed functionCall in Gemini response"}}
  end

  defp parse_content_part(%{"inlineData" => %{"mimeType" => mime_type, "data" => data}})
       when is_binary(mime_type) and is_binary(data) do
    block =
      case String.split(mime_type, "/", parts: 2) do
        ["image", _] -> %{type: "image", mime_type: mime_type, data: data}
        ["audio", _] -> %{type: "audio", mime_type: mime_type, data: data}
        ["video", _] -> %{type: "video", mime_type: mime_type, data: data}
        _ -> %{type: "binary", mime_type: mime_type, data: data}
      end

    {:ok, block}
  end

  defp parse_content_part(%{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}})
       when is_binary(mime_type) and is_binary(uri) do
    {:ok, %{type: "document", mime_type: mime_type, uri: uri}}
  end

  defp parse_content_part(part)
       when is_map(part) and
              (is_map_key(part, "executableCode") or is_map_key(part, "codeExecutionResult") or
                 is_map_key(part, "toolCall") or is_map_key(part, "toolResponse")) do
    {:ok, %{type: "gemini_part", raw: part}}
  end

  defp parse_content_part(part) when is_map(part) do
    {:ok, %{type: "unknown"} |> Map.merge(part)}
  end

  defp parse_content_part(_invalid) do
    {:error, %Error{kind: :protocol_error, message: "Malformed part in Gemini candidate content"}}
  end

  defp build_response_metadata(resp, candidate) do
    %{}
    |> HTTP.maybe_put(:finish_reason, candidate["finishReason"])
    |> HTTP.maybe_put(:finish_message, candidate["finishMessage"])
    |> HTTP.maybe_put_unless_empty_map(:prompt_feedback, resp["promptFeedback"])
    |> HTTP.maybe_put_unless_empty_map(
      :grounding_metadata,
      candidate["groundingMetadata"] || resp["groundingMetadata"]
    )
    |> HTTP.maybe_put_unless_empty_map(:stop_details, refusal_details(candidate))
  end

  # Like every provider, the API's own fields with its own (string) keys.
  defp refusal_details(%{"finishReason" => reason} = candidate) when reason in @refusal_reasons,
    do: Map.take(candidate, ["finishReason", "finishMessage", "safetyRatings"])

  defp refusal_details(_candidate), do: nil

  # A truncated tool call stays :max_tokens: the loop must not run it.
  defp stop_reason("MAX_TOKENS", _blocks), do: :max_tokens
  defp stop_reason(reason, _blocks) when reason in @refusal_reasons, do: :refusal

  defp stop_reason(_reason, blocks) do
    if Enum.any?(blocks, &match?(%{type: "tool_use"}, &1)), do: :tool_use, else: :end_turn
  end

  # Alloy follows Anthropic's usage semantics, where input_tokens excludes
  # cache reads, so input + cache reads + output is everything billed.
  # Gemini's promptTokenCount already includes cachedContentTokenCount, so
  # the cached part is moved out of input. toolUsePromptTokenCount (results
  # of built-in tools such as URL context or code execution, fed back to the
  # model) is reported apart from the prompt but billed as input. Thinking
  # tokens are billed as output, yet candidatesTokenCount leaves them out.
  defp parse_usage(usage) when is_map(usage) do
    cached = HTTP.non_neg_int(usage["cachedContentTokenCount"])

    %{
      input_tokens:
        max(HTTP.non_neg_int(usage["promptTokenCount"]) - cached, 0) +
          HTTP.non_neg_int(usage["toolUsePromptTokenCount"]),
      output_tokens:
        HTTP.non_neg_int(usage["candidatesTokenCount"]) +
          HTTP.non_neg_int(usage["thoughtsTokenCount"]),
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: cached
    }
  end

  defp parse_usage(_usage), do: parse_usage(%{})

  # Gemini may emit %{} for an absent thoughtSignature; omit both nil and %{}.
  defp maybe_put_signature(map, key, signature),
    do: HTTP.maybe_put_unless_empty_map(map, key, signature)

  defp generated_tool_call_id(name) do
    "gemini_call_#{name}_#{System.unique_integer([:positive])}"
  end
end
