defmodule Alloy.Provider.Gemini do
  @moduledoc """
  Provider for Google's Gemini GenerateContent API.

  Normalizes Gemini's `contents` / `parts` wire format to Alloy messages,
  including function calling and thinking-part round-tripping.

  ## Config

  Required:
  - `:api_key` - Gemini API key
  - `:model` - Model name (for example `"gemini-2.5-flash"`)

  Optional:
  - `:max_tokens` - Max output tokens, sent as `maxOutputTokens`. Thinking
    tokens count against it. When unset, the model's own output limit
    applies (Alloy 0.12.4 and earlier sent `4096`)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: `"https://generativelanguage.googleapis.com"`)
  - `:api_version` - API version path (default: `"v1beta"`)
  - `:generation_config` - Raw Gemini `generationConfig` fields
  - `:tool_config` - Raw Gemini `toolConfig`
  - `:safety_settings` - Raw Gemini `safetySettings`
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:req_options` - Additional options passed to Req

  ## Example

      Alloy.run("Summarize this code.",
        provider: {Alloy.Provider.Gemini,
          api_key: System.get_env("GEMINI_API_KEY"),
          model: "gemini-2.5-flash"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.{Error, HTTP}

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
          optional(:req_options) => keyword()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    with {:ok, resp_body} <-
           HTTP.post_json(
             request_url(config, "generateContent"),
             build_headers(config),
             body,
             Map.get(config, :req_options, [])
           ) do
      parse_response(resp_body)
    end
  end

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    body = build_request_body(messages, tool_defs, config)

    # content_blocks is newest first. response and candidate hold the latest
    # top-level and candidate fields (usage, finishReason, promptFeedback).
    initial_acc = %{
      buffer: "",
      content_blocks: [],
      response: %{},
      candidate: %{},
      on_chunk: on_chunk
    }

    with {:ok, acc} <-
           HTTP.stream_sse(
             request_url(config, "streamGenerateContent"),
             build_headers(config),
             body,
             initial_acc,
             &handle_sse_event/2,
             [params: [alt: "sse"]] ++ Map.get(config, :req_options, [])
           ) do
      build_stream_response(acc)
    end
  end

  defp request_url(config, method) do
    api_url = Map.get(config, :api_url, @default_api_url) |> String.trim_trailing("/")
    api_version = Map.get(config, :api_version, @default_api_version)
    model = normalize_model(Map.fetch!(config, :model))

    "#{api_url}/#{api_version}/models/#{model}:#{method}"
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

    case Map.get(config, :safety_settings) do
      nil -> body
      settings -> Map.put(body, "safetySettings", Alloy.Provider.stringify_keys(settings))
    end
  end

  defp build_contents(messages) do
    Enum.map(messages, &format_message(&1, messages))
  end

  defp format_message(%Message{role: role, content: content}, _messages)
       when is_binary(content) do
    %{"role" => format_role(role), "parts" => [%{"text" => content}]}
  end

  defp format_message(%Message{role: role, content: blocks}, messages) when is_list(blocks) do
    %{
      "role" => format_role(role),
      "parts" => blocks |> Enum.map(&format_content_block(&1, messages)) |> Enum.reject(&is_nil/1)
    }
  end

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

  defp normalize_function_response_payload(content, is_error) do
    payload =
      case Jason.decode(content) do
        {:ok, decoded} when is_map(decoded) -> decoded
        {:ok, decoded} -> %{"result" => decoded}
        {:error, _} -> %{"content" => content}
      end

    if is_error, do: Map.put(payload, "is_error", true), else: payload
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "name" => name,
      "description" => desc,
      "parameters" => Alloy.Provider.stringify_keys(schema)
    }
  end

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, message} -> {:error, %Error{kind: :unknown, message: message}}
    end
  end

  defp parse_response(%{"candidates" => [candidate | _]} = resp) do
    candidate
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.map(&parse_content_part/1)
    |> respond(candidate, resp)
  end

  defp parse_response(%{"promptFeedback" => %{"blockReason" => _}} = resp),
    do: prompt_blocked(resp)

  defp parse_response(%{"error" => error}), do: {:error, in_band_error(error)}

  defp parse_response(other) do
    {:error,
     %Error{kind: :unknown, message: "Unexpected Gemini response payload: #{inspect(other)}"}}
  end

  # Errors can also arrive in a 200 body: as an SSE chunk mid-stream, or
  # from a proxy. Google's error object carries the HTTP status it stands
  # for in "code"; without one the error is classified by its "status"
  # label alone and keeps no HTTP status.
  defp in_band_error(%{"code" => status} = error) when is_integer(status) and status >= 400,
    do: Error.from_response(status, [], %{"error" => error})

  defp in_band_error(error),
    do: %{Error.from_response(200, [], %{"error" => error}) | status: nil}

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
  defp prompt_blocked(%{"promptFeedback" => %{"blockReason" => reason} = feedback} = resp) do
    stop_details = maybe_put(%{block_reason: reason}, :safety_ratings, feedback["safetyRatings"])

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

  defp parse_content_part(%{"text" => text, "thought" => true} = part) do
    %{type: "thinking", thinking: text}
    |> maybe_put(:signature, part["thoughtSignature"])
  end

  defp parse_content_part(%{"text" => text} = part) do
    %{type: "text", text: text}
    |> maybe_put(:signature, part["thoughtSignature"])
  end

  defp parse_content_part(%{"functionCall" => call} = part) do
    id = call["id"] || generated_tool_call_id(call["name"])

    %{type: "tool_use", id: id, name: call["name"], input: call["args"] || %{}}
    |> maybe_put(:signature, part["thoughtSignature"])
  end

  defp parse_content_part(%{"inlineData" => %{"mimeType" => mime_type, "data" => data}}) do
    case String.split(mime_type, "/", parts: 2) do
      ["image", _] -> %{type: "image", mime_type: mime_type, data: data}
      ["audio", _] -> %{type: "audio", mime_type: mime_type, data: data}
      ["video", _] -> %{type: "video", mime_type: mime_type, data: data}
      _ -> %{type: "binary", mime_type: mime_type, data: data}
    end
  end

  defp parse_content_part(%{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}}) do
    %{type: "document", mime_type: mime_type, uri: uri}
  end

  defp parse_content_part(part) do
    %{type: "unknown"} |> Map.merge(part)
  end

  defp build_response_metadata(resp, candidate) do
    %{}
    |> maybe_put(:finish_reason, candidate["finishReason"])
    |> maybe_put(:finish_message, candidate["finishMessage"])
    |> maybe_put(:prompt_feedback, resp["promptFeedback"])
    |> maybe_put(:grounding_metadata, candidate["groundingMetadata"] || resp["groundingMetadata"])
    |> maybe_put(:stop_details, refusal_details(candidate))
  end

  defp refusal_details(%{"finishReason" => reason} = candidate) when reason in @refusal_reasons do
    %{finish_reason: reason}
    |> maybe_put(:finish_message, candidate["finishMessage"])
    |> maybe_put(:safety_ratings, candidate["safetyRatings"])
  end

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
  defp parse_usage(usage) do
    cached = Map.get(usage, "cachedContentTokenCount", 0)

    %{
      input_tokens:
        Map.get(usage, "promptTokenCount", 0) - cached +
          Map.get(usage, "toolUsePromptTokenCount", 0),
      output_tokens:
        Map.get(usage, "candidatesTokenCount", 0) + Map.get(usage, "thoughtsTokenCount", 0),
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: cached
    }
  end

  defp handle_sse_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_sse_event(acc, %{data: data}) do
    case Alloy.Provider.decode_body(data) do
      {:ok, decoded} -> handle_stream_chunk(acc, decoded)
      {:error, _} -> acc
    end
  end

  defp handle_stream_chunk(acc, %{"candidates" => [candidate | _]} = chunk) do
    blocks =
      candidate
      |> get_in(["content", "parts"])
      |> List.wrap()
      |> Enum.map(&parse_content_part/1)

    Enum.each(blocks, &emit_text_delta(&1, acc.on_chunk))

    %{
      merge_response_fields(acc, chunk)
      | content_blocks: Enum.reduce(blocks, acc.content_blocks, &merge_stream_block/2),
        candidate: Map.merge(acc.candidate, Map.delete(candidate, "content"))
    }
  end

  defp handle_stream_chunk(acc, %{} = chunk), do: merge_response_fields(acc, chunk)

  # Usage counts are running totals: a later chunk's count replaces the
  # earlier one, and a count it leaves out keeps its last value.
  defp merge_response_fields(acc, chunk) do
    fields = Map.delete(chunk, "candidates")

    response =
      Map.merge(acc.response, fields, fn
        "usageMetadata", previous, latest -> Map.merge(previous, latest)
        _key, _previous, latest -> latest
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

  defp build_stream_response(%{response: %{"error" => error}}), do: {:error, in_band_error(error)}

  defp build_stream_response(%{
         content_blocks: [],
         response: %{"promptFeedback" => %{"blockReason" => _}} = resp
       }),
       do: prompt_blocked(resp)

  # A finished stream always ends with a finishReason; without one the
  # connection was cut and the output is incomplete.
  defp build_stream_response(%{candidate: candidate})
       when not is_map_key(candidate, "finishReason"),
       do: {:error, %Error{kind: :network, message: "Gemini stream ended before a finishReason"}}

  defp build_stream_response(acc),
    do: acc.content_blocks |> Enum.reverse() |> respond(acc.candidate, acc.response)

  defp generated_tool_call_id(name) do
    "gemini_call_#{name || "tool"}_#{System.unique_integer([:positive])}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
end
