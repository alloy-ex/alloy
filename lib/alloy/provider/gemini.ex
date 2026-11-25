defmodule Alloy.Provider.Gemini do
  @moduledoc """
  Provider for Google's Gemini GenerateContent API.

  Normalizes Gemini's `contents` / `parts` wire format to Alloy messages,
  including function calling and thinking-part round-tripping.

  ## Config

  Required:
  - `:api_key` - Gemini API key
  - `:model` - Model name, for example `"gemini-3.8-flash"` or
    `"gemini-3.5-flash-lite"`. Gemini 2.5 models are open only to projects
    that already used them.

  Optional:
  - `:max_tokens` - Max output tokens, sent as `maxOutputTokens`. Thinking
    tokens count against it. When unset, the model's own output limit
    applies (Alloy 0.12.4 and earlier sent `4096`)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: `"https://generativelanguage.googleapis.com"`)
  - `:api_version` - API version path (default: `"v1beta"`)
  - `:generation_config` - Raw Gemini `generationConfig` fields (see Thinking)
  - `:tool_config` - Raw Gemini `toolConfig`
  - `:safety_settings` - Raw Gemini `safetySettings`
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:extra_body` - Additional top-level request body fields, shallow-merged last
    (a key in `:extra_body` replaces any provider-built key of the same name,
    such as `"generationConfig"`)
  - `:req_options` - Additional options passed to Req

  ## Thinking

  Gemini 3 models think by default. Set the depth with `thinkingLevel`
  (`"MINIMAL"`, `"LOW"`, `"MEDIUM"` or `"HIGH"`; each model accepts a
  subset) under `thinkingConfig`. `thinkingBudget`, a token count, is the
  older control: Gemini 2.5 models need it, and Gemini 3 still accepts it.
  Never send both; the API rejects the request. Thinking tokens are billed
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
  alias Alloy.Provider.{Error, HTTP}

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

  @typedoc """
  Configuration for the Gemini provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:api_version) => String.t(),
          optional(:generation_config) => map(),
          optional(:tool_config) => map(),
          optional(:safety_settings) => [map()],
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:req_options) => keyword()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, resp_body} <-
           HTTP.post_json(
             request_url(config, "generateContent"),
             build_headers(config),
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
    # content_blocks is newest first. response and candidate hold the latest
    # top-level and candidate fields (usage, finishReason, promptFeedback).
    initial_acc = %{
      buffer: "",
      content_blocks: [],
      response: %{},
      candidate: %{},
      stream_error: nil,
      on_chunk: on_chunk
    }

    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, acc} <-
           HTTP.stream_sse(
             request_url(config, "streamGenerateContent"),
             build_headers(config),
             body,
             initial_acc,
             &handle_sse_event/2,
             [params: [alt: "sse"]] ++ Map.get(config, :req_options, []),
             deadline: Map.get(config, :alloy_request_deadline)
           ) do
      build_stream_response(acc)
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

  defp build_headers(config) do
    [
      {"x-goog-api-key", config.api_key},
      {"x-goog-api-client", "alloy/#{Application.spec(:alloy, :vsn) |> to_string()}"},
      {"content-type", "application/json"}
    ] ++ Map.get(config, :extra_headers, [])
  end

  defp build_request_body(messages, tool_defs, config) do
    body = %{"contents" => build_contents(messages)}

    body =
      case Map.get(config, :system_prompt) do
        prompt when is_binary(prompt) and prompt != "" ->
          Map.put(body, "systemInstruction", %{"parts" => [%{"text" => prompt}]})

        _other ->
          body
      end

    # No default maxOutputTokens: the budget includes thinking, so a fixed
    # default truncates thinking models; each model's own limit is larger.
    generation_config =
      Map.get(config, :generation_config, %{})
      |> Alloy.Provider.stringify_keys()
      |> maybe_put_new("maxOutputTokens", Map.get(config, :max_tokens))
      |> maybe_put_output_schema(config)

    body = maybe_put(body, "generationConfig", generation_config)

    body =
      case tool_defs do
        [] ->
          body

        defs ->
          Map.put(body, "tools", [%{"functionDeclarations" => Enum.map(defs, &format_tool_def/1)}])
      end

    body =
      case Map.get(config, :tool_config) do
        nil -> body
        tool_config -> Map.put(body, "toolConfig", Alloy.Provider.stringify_keys(tool_config))
      end

    body =
      case Map.get(config, :safety_settings) do
        nil -> body
        settings -> Map.put(body, "safetySettings", Provider.stringify_keys(settings))
      end

    body =
      HTTP.merge_extra_body(
        body,
        HTTP.stringify_extra_body(Map.get(config, :extra_body, %{})),
        "generationConfig"
      )

    validate_output_schema_conflicts(body, config)
  end

  defp build_contents(messages) do
    Enum.map(messages, &format_message(&1, messages))
  end

  defp format_message(%Message{role: role, content: content}, _messages)
       when is_binary(content) do
    %{"role" => format_role(role), "parts" => [%{"text" => content}]}
  end

  defp format_message(%Message{role: role, content: blocks}, messages) when is_list(blocks) do
    parts = blocks |> Enum.map(&format_content_block(&1, messages)) |> Enum.reject(&is_nil/1)
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

  defp format_content_block(%{type: "thinking", thinking: thinking} = block, _messages) do
    %{"text" => thinking, "thought" => true}
    |> maybe_put("thoughtSignature", block[:signature])
  end

  defp format_content_block(%{type: "text", text: text} = block, _messages) do
    %{"text" => text}
    |> maybe_put("thoughtSignature", block[:signature])
  end

  defp format_content_block(
         %{type: "tool_use", id: id, name: name, input: input} = block,
         _messages
       ) do
    %{
      "functionCall" => %{
        "id" => id,
        "name" => name,
        "args" => Alloy.Provider.stringify_keys(input)
      }
    }
    |> maybe_put("thoughtSignature", block[:signature])
  end

  defp format_content_block(
         %{type: "tool_result", tool_use_id: id, content: content} = block,
         messages
       ) do
    %{
      "functionResponse" => %{
        "id" => id,
        "name" => lookup_tool_name(messages, id) || "unknown_tool",
        "response" =>
          normalize_function_response_payload(content, Map.get(block, :is_error, false))
      }
    }
  end

  defp format_content_block(%{type: "image", mime_type: mime_type, data: data}, _messages) do
    %{"inlineData" => %{"mimeType" => mime_type, "data" => data}}
  end

  defp format_content_block(%{type: type, mime_type: mime_type, data: data}, _messages)
       when type in ["audio", "video"] do
    %{"inlineData" => %{"mimeType" => mime_type, "data" => data}}
  end

  defp format_content_block(%{type: "document", mime_type: mime_type, uri: uri}, _messages) do
    %{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}}
  end

  # Opaque OpenAI Responses items in a transcript that switched provider;
  # they mean nothing to Gemini, so they are dropped rather than turned
  # into placeholder text the model would read.
  defp format_content_block(%{type: type}, _messages) when type in ["reasoning", "output_item"],
    do: nil

  defp format_content_block(block, _messages) when is_map(block) do
    %{
      "text" =>
        "[Unsupported content block for Gemini provider: #{inspect(Map.get(block, :type) || Map.get(block, "type"))}]"
    }
  end

  defp lookup_tool_name(messages, tool_use_id) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, content: blocks} when is_list(blocks) ->
        Enum.find_value(blocks, fn
          %{type: "tool_use", id: ^tool_use_id, name: name} -> name
          _ -> nil
        end)

      _other ->
        nil
    end)
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
      "parametersJsonSchema" => Alloy.Provider.stringify_keys(schema)
    }
  end

  defp parse_response(body) when is_binary(body) do
    case Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
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
    result =
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
        case parse_content_part(part) do
          {:ok, block} -> {:cont, {:ok, [block | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      {:error, _} = err -> err
    end
  end

  defp parse_content_part(%{"text" => text, "thought" => true} = part) when is_binary(text) do
    {:ok, %{type: "thinking", thinking: text} |> maybe_put(:signature, part["thoughtSignature"])}
  end

  defp parse_content_part(%{"text" => text} = part) when is_binary(text) do
    {:ok, %{type: "text", text: text} |> maybe_put(:signature, part["thoughtSignature"])}
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
         |> maybe_put(:signature, part["thoughtSignature"])}

      args when is_map(args) ->
        {:ok,
         %{type: "tool_use", id: id, name: name, input: args}
         |> maybe_put(:signature, part["thoughtSignature"])}

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

  defp parse_content_part(part) when is_map(part) do
    {:ok, %{type: "unknown"} |> Map.merge(part)}
  end

  defp parse_content_part(_invalid) do
    {:error, %Error{kind: :protocol_error, message: "Malformed part in Gemini candidate content"}}
  end

  defp build_response_metadata(resp, candidate) do
    %{}
    |> maybe_put(:finish_reason, candidate["finishReason"])
    |> maybe_put(:finish_message, candidate["finishMessage"])
    |> maybe_put(:prompt_feedback, resp["promptFeedback"])
    |> maybe_put(:grounding_metadata, candidate["groundingMetadata"] || resp["groundingMetadata"])
    |> maybe_put(:stop_details, refusal_details(candidate))
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
    cached = non_neg_int(usage["cachedContentTokenCount"])

    %{
      input_tokens:
        max(non_neg_int(usage["promptTokenCount"]) - cached, 0) +
          non_neg_int(usage["toolUsePromptTokenCount"]),
      output_tokens:
        non_neg_int(usage["candidatesTokenCount"]) + non_neg_int(usage["thoughtsTokenCount"]),
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: cached
    }
  end

  defp parse_usage(_usage) do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp handle_sse_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_sse_event(%{response: %{"error" => error}} = acc, _event)
       when is_map(error) or is_binary(error),
       do: acc

  # Once a malformed chunk is recorded, stop emitting text deltas so Retry can
  # still recover if nothing was streamed yet, while still capturing an
  # in-band API error chunk so it takes precedence over malformed siblings.
  defp handle_sse_event(%{stream_error: %Error{}} = acc, %{data: data}) do
    case decode_sse_chunk(data) do
      {:ok, %{"error" => error} = decoded} when is_map(error) or is_binary(error) ->
        merge_response_fields(acc, decoded)

      _ ->
        acc
    end
  end

  defp handle_sse_event(acc, %{data: data}) do
    if String.trim(data) == "" do
      acc
    else
      case decode_sse_chunk(data) do
        {:ok, decoded} -> handle_stream_chunk(acc, decoded)
        {:error, %Error{} = error} -> %{acc | stream_error: error}
      end
    end
  end

  defp decode_sse_chunk(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, [%{"error" => error} = wrapper | _]} when is_map(error) or is_binary(error) ->
        {:ok, wrapper}

      {:ok, _non_map} ->
        {:error, %Error{kind: :protocol_error, message: "Malformed JSON in Gemini SSE chunk"}}

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
    case extract_candidate_blocks(candidate) do
      {:ok, blocks} ->
        Enum.each(blocks, &emit_text_delta(&1, acc.on_chunk))

        candidate_updates =
          candidate
          |> Map.delete("content")
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        %{
          merge_response_fields(acc, chunk)
          | content_blocks: Enum.reduce(blocks, acc.content_blocks, &merge_stream_block/2),
            candidate: Map.merge(acc.candidate, candidate_updates)
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

  defp emit_text_delta(%{type: "text", text: text}, on_chunk) when text != "", do: on_chunk.(text)
  defp emit_text_delta(_block, _on_chunk), do: :ok

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

  # Prioritize explicit in-band API errors over malformed-chunk errors so a
  # real quota/safety error is never masked by a garbled sibling chunk.
  defp build_stream_response(%{response: %{"error" => error}})
       when is_map(error) or is_binary(error),
       do: {:error, in_band_error(error)}

  defp build_stream_response(%{stream_error: %Error{} = error}), do: {:error, error}

  defp build_stream_response(%{
         content_blocks: [],
         response: %{"promptFeedback" => %{"blockReason" => _}} = resp
       }),
       do: prompt_blocked(resp)

  # A finished stream always ends with a non-empty finishReason; without one
  # the connection was cut and the output is incomplete.
  defp build_stream_response(%{candidate: %{"finishReason" => reason}} = acc)
       when is_binary(reason) and reason != "",
       do: acc.content_blocks |> Enum.reverse() |> respond(acc.candidate, acc.response)

  defp build_stream_response(_acc),
    do: {:error, %Error{kind: :network, message: "Gemini stream ended before a finishReason"}}

  defp generated_tool_call_id(name) do
    "gemini_call_#{name}_#{System.unique_integer([:positive])}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp maybe_put_output_schema(generation_config, config) do
    case OutputSchema.wire(Map.get(config, :output_schema)) do
      nil ->
        generation_config

      %{schema: schema} ->
        generation_config
        |> maybe_put_new("responseMimeType", "application/json")
        |> maybe_put_new("responseJsonSchema", schema)
    end
  end

  defp validate_output_schema_conflicts(body, config) do
    case OutputSchema.wire(Map.get(config, :output_schema)) do
      nil ->
        {:ok, body}

      _spec ->
        generation_config = Map.get(body, "generationConfig", %{})
        validate_gemini_generation_config(body, generation_config)
    end
  end

  defp validate_gemini_generation_config(body, generation_config)
       when is_map(generation_config) do
    invalid_mime =
      [
        Map.get(generation_config, "responseMimeType"),
        Map.get(generation_config, "response_mime_type")
      ]
      |> Enum.find(&(&1 not in [nil, "application/json"]))

    cond do
      Map.has_key?(generation_config, "responseSchema") or
          Map.has_key?(generation_config, "response_schema") ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "cannot combine :output_schema with legacy generationConfig[\"responseSchema\"] on Gemini"
         }}

      not is_nil(invalid_mime) ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "cannot combine :output_schema with non-JSON generationConfig[\"responseMimeType\"] (#{inspect(invalid_mime)}) on Gemini"
         }}

      true ->
        {:ok, body}
    end
  end

  defp validate_gemini_generation_config(body, _other), do: {:ok, body}
end
