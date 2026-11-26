defmodule Alloy.Provider.OpenAICompat do
  @moduledoc """
  Generic OpenAI-compatible provider.

  Works with any API that implements the OpenAI chat completions format:
  DeepSeek, Mistral, Kimi, GLM, Ollama, OpenRouter, Together, Groq, etc.

  Reasoning returned as `reasoning_content` (DeepSeek, Kimi, GLM) becomes a
  `"thinking"` block and is sent back on later assistant messages, which
  DeepSeek's thinking mode requires during tool calls. Thinking returned inside
  array-of-parts `content` (such as Mistral Magistral) is also preserved as a
  `"thinking"` block (`source: "content_part"`) for inspection via
  `Alloy.Message.thinking/1`, but is withheld from top-level `reasoning_content`
  on later turns so strict OpenAI-compatible APIs do not reject unknown keys.

  Two providers have better native options:

  - OpenAI: use `Alloy.Provider.OpenAI`. Starting with GPT-5.4, Chat
    Completions does not support tool calling with reasoning enabled.
  - xAI: use `Alloy.Provider.XAI`. xAI's Chat Completions endpoint is
    deprecated and returns no reasoning content.

  ## Config

  Required:
  - `:api_url` - Base URL (e.g., "https://api.deepseek.com",
    "https://api.mistral.ai", "http://localhost:11434")
  - `:model` - Model name

  Optional:
  - `:api_key` - API key string or 0-arity callback returning
    `String.t() | {:ok, String.t()} | {:error, term()}` (omit for local
    providers like Ollama; set `:origin_key` when passing a callback via
    `Alloy.run/2`)
  - `:origin_key` - Account identifier used for cross-origin provenance hashing
    (required when `:api_key` is a function)
  - `:max_tokens` - Max output tokens. Omitted unless set, so the server's
    default applies
  - `:system_prompt` - System prompt string
  - `:chat_path` - Path to completions endpoint (default: "/v1/chat/completions")
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:extra_body` - Additional body fields, merged last
  - `:stream_options` - Set to `false` to omit usage-request options from
    streaming requests. Custom option maps can be supplied through
    `extra_body: %{"stream_options" => options}`.
  - `:req_options` - Additional options passed to Req

  ## Examples

      # DeepSeek
      Alloy.run("Hello",
        provider: {Alloy.Provider.OpenAICompat,
          api_key: System.get_env("DEEPSEEK_API_KEY"),
          api_url: "https://api.deepseek.com",
          model: "deepseek-v4-pro"
        }
      )

      # Ollama (no API key)
      Alloy.run("Hello",
        provider: {Alloy.Provider.OpenAICompat,
          api_url: "http://localhost:11434",
          model: "llama4"
        }
      )

      # Mistral (mistral-large-latest and -2512 are in the built-in
      # model catalog, so context budgeting works out of the box)
      Alloy.run("Hello",
        provider: {Alloy.Provider.OpenAICompat,
          api_key: System.get_env("MISTRAL_API_KEY"),
          api_url: "https://api.mistral.ai",
          model: "mistral-large-latest"
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, OutputSchema}
  alias Alloy.Provider.{Error, HTTP, OpenAIStream}

  @default_chat_path "/v1/chat/completions"

  @typedoc """
  Configuration for the OpenAI-compatible provider. `:api_key` is optional
  (omit for local providers like Ollama). See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_url) => String.t(),
          required(:model) => String.t(),
          optional(:api_key) => Alloy.Provider.api_key(),
          optional(:origin_key) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:chat_path) => String.t(),
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:extra_body) => map(),
          optional(:reasoning) => Alloy.Provider.reasoning(),
          optional(:on_event) => (term() -> :ok),
          optional(:stream_options) => false,
          optional(:req_options) => keyword()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- HTTP.resolve_optional_api_key(config),
         {:ok, resp_body} <-
           HTTP.post_json(
             chat_url(config),
             build_headers(config, api_key),
             body,
             Map.get(config, :req_options, []),
             HTTP.request_opts(config)
           ) do
      parse_response(resp_body)
    end
  end

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, body} <- build_request_body(messages, tool_defs, config),
         {:ok, api_key} <- HTTP.resolve_optional_api_key(config) do
      body =
        if config[:stream_options] == false,
          do: Map.put(body, "stream_options", false),
          else: body

      OpenAIStream.stream(
        chat_url(config),
        build_headers(config, api_key),
        body,
        on_chunk,
        Map.get(config, :req_options, []),
        Keyword.put(
          HTTP.request_opts(config),
          :on_event,
          Map.get(config, :on_event, fn _ -> :ok end)
        )
      )
    end
  end

  defp chat_url(config),
    do: HTTP.join_url(config.api_url, Map.get(config, :chat_path, @default_chat_path))

  defp build_headers(config, api_key) do
    base = [{"content-type", "application/json"}]

    base =
      case api_key do
        nil -> base
        key -> [{"authorization", "Bearer #{key}"} | base]
      end

    base ++ Map.get(config, :extra_headers, [])
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    with {:ok, reasoning} <- Alloy.Provider.normalize_reasoning(Map.get(config, :reasoning)) do
      openai_messages = build_messages(messages, config)

      body =
        %{"model" => config.model, "messages" => openai_messages}
        |> HTTP.maybe_put("max_tokens", Map.get(config, :max_tokens))
        |> HTTP.maybe_put_unless_empty_list("tools", Enum.map(tool_defs, &format_tool_def/1))
        |> maybe_put_output_schema(config)
        |> maybe_put_reasoning(reasoning)

      # Merge extra_body LAST so caller can override any field. Keys are
      # stringified first: an atom key would sit beside the string key it
      # meant to replace and be encoded as a duplicate JSON key.
      {:ok, Map.merge(body, HTTP.stringify_extra_body(Map.get(config, :extra_body, %{})))}
    end
  end

  defp maybe_put_reasoning(body, nil), do: body

  defp maybe_put_reasoning(body, %{effort: effort}) do
    effort_str =
      case effort do
        :off -> "none"
        :low -> "low"
        :medium -> "medium"
        :high -> "high"
        :xhigh -> "xhigh"
      end

    Map.put(body, "reasoning_effort", effort_str)
  end

  defp maybe_put_output_schema(body, config) do
    case Map.get(config, :output_schema) do
      nil ->
        body

      %OutputSchema{name: name, schema: schema, strict: strict} ->
        Map.put(body, "response_format", %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => name,
            "schema" => schema,
            "strict" => strict
          }
        })
    end
  end

  defp build_messages(messages, config) do
    system_msgs =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    conv_msgs = Enum.flat_map(messages, &format_message/1)
    system_msgs ++ conv_msgs
  end

  defp format_message(%Message{role: :user, content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp format_message(%Message{role: :assistant, content: content}) when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

  defp format_message(%Message{role: :assistant, content: blocks})
       when is_list(blocks) do
    tool_calls =
      blocks
      |> Enum.filter(&(is_map(&1) and &1[:type] == "tool_use"))
      |> Enum.map(fn call ->
        tc = %{
          "id" => call.id,
          "type" => "function",
          "function" => %{
            "name" => call.name,
            "arguments" => Jason.encode!(call.input)
          }
        }

        # Echo Gemini 3.x thought signatures back for multi-turn tool calls.
        # Required or the API returns 400 (PR #24).
        case Map.get(call, :thought_signature) do
          nil -> tc
          sig -> Map.put(tc, "extra_content", %{"google" => %{"thought_signature" => sig}})
        end
      end)

    text_parts =
      blocks
      |> Enum.filter(&(is_map(&1) and &1[:type] == "text" and is_binary(&1[:text])))
      |> Enum.map_join("\n", & &1[:text])

    msg =
      %{"role" => "assistant", "content" => if(text_parts == "", do: nil, else: text_parts)}
      |> HTTP.maybe_put_unless_empty_list("tool_calls", tool_calls)

    # Thinking modes (DeepSeek, Kimi, GLM) need earlier reasoning back to
    # keep continuity; DeepSeek rejects a tool loop without it (HTTP 400).
    # Skip blocks sourced from array-of-parts content (e.g. Mistral Magistral),
    # whose API rejects unknown top-level assistant keys like reasoning_content.
    reasoning_text =
      blocks
      |> Enum.filter(fn block ->
        is_map(block) and block[:type] == "thinking" and
          Map.get(block, :source) not in ["content_part", :content_part] and
          is_binary(block[:thinking])
      end)
      |> Enum.map_join("\n", & &1[:thinking])

    reasoning_content = if reasoning_text == "", do: nil, else: reasoning_text

    [HTTP.maybe_put(msg, "reasoning_content", reasoning_content)]
  end

  defp format_message(%Message{role: :user, content: blocks}) when is_list(blocks) do
    if Enum.any?(blocks, &(is_map(&1) and &1[:type] == "tool_result")) do
      blocks
      |> Enum.flat_map(fn
        %{type: "tool_result", tool_use_id: id, content: content} ->
          [%{"role" => "tool", "tool_call_id" => id, "content" => content}]

        _ ->
          []
      end)
    else
      parts = blocks |> Enum.map(&format_user_content_block/1) |> Enum.reject(&is_nil/1)
      [%{"role" => "user", "content" => parts}]
    end
  end

  defp format_user_content_block(%{type: "text", text: text}),
    do: %{"type" => "text", "text" => text}

  defp format_user_content_block(%{type: "image", mime_type: mime, data: data}),
    do: %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime};base64,#{data}"}}

  defp format_user_content_block(%{type: "image", url: url}) when is_binary(url) do
    if HTTP.http_url?(url) and not HTTP.provider_file_uri?(url) do
      %{"type" => "image_url", "image_url" => %{"url" => url}}
    else
      %{"type" => "text", "text" => "[Unsupported image URL scheme for OpenAICompat provider]"}
    end
  end

  defp format_user_content_block(_), do: nil

  defp format_tool_def(%{name: name, description: desc, input_schema: schema} = def_map) do
    function = %{
      "name" => name,
      "description" => desc,
      "parameters" => Alloy.Provider.stringify_keys(schema)
    }

    function =
      if Map.get(def_map, :strict) == true,
        do: Map.put(function, "strict", true),
        else: function

    %{"type" => "function", "function" => function}
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Alloy.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"error" => error} = resp) when is_map(error) or is_binary(error) do
    {:error, Error.from_body(resp)}
  end

  defp parse_response(%{"choices" => [choice | _]} = resp) when is_map(choice) do
    finish_reason = choice["finish_reason"]

    case parse_message_to_blocks(Map.get(choice, "message"), finish_reason) do
      {:ok, content_blocks} ->
        usage = if is_map(resp["usage"]), do: resp["usage"], else: %{}
        {:ok, OpenAIStream.completion_response(content_blocks, finish_reason, usage)}

      {:error, _} = err ->
        err
    end
  end

  defp parse_response(%{"choices" => [_non_map | _]}) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Invalid choice in Chat Completions response"
     }}
  end

  defp parse_response(resp) do
    {:error,
     %Error{
       message: "Unexpected chat completion payload: #{Sanitize.inspect_bounded(resp)}"
     }}
  end

  defp parse_message_to_blocks(message, finish_reason) when is_map(message) do
    with {:ok, reasoning_field} <-
           parse_optional_string_field(Map.get(message, "reasoning_content"), "reasoning_content"),
         {:ok, refusal_field} <-
           parse_optional_string_field(Map.get(message, "refusal"), "refusal"),
         {:ok, content_text, content_thinking, content_refusal} <-
           parse_message_content(Map.get(message, "content")),
         {:ok, tool_blocks} <- parse_tool_calls(Map.get(message, "tool_calls"), finish_reason) do
      reasoning_blocks =
        if reasoning_field != "",
          do: [%{type: "thinking", thinking: reasoning_field}],
          else: []

      content_thinking_blocks =
        if content_thinking != "",
          do: [%{type: "thinking", thinking: content_thinking, source: "content_part"}],
          else: []

      text_blocks = if content_text != "", do: [%{type: "text", text: content_text}], else: []
      combined_refusal = content_refusal <> refusal_field

      refusal_blocks =
        if combined_refusal != "",
          do: [%{type: "text", text: combined_refusal, refusal: true}],
          else: []

      {:ok,
       reasoning_blocks ++ content_thinking_blocks ++ text_blocks ++ refusal_blocks ++ tool_blocks}
    end
  end

  defp parse_message_to_blocks(_invalid, _finish_reason) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Invalid choice message in Chat Completions response"
     }}
  end

  defp parse_optional_string_field(nil, _field), do: {:ok, ""}
  defp parse_optional_string_field(text, _field) when is_binary(text), do: {:ok, text}

  defp parse_optional_string_field(_invalid, field) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Invalid #{field} in Chat Completions response"
     }}
  end

  defp parse_message_content(content) do
    case OpenAIStream.extract_content_parts(content) do
      {:ok, text, thinking, refusal} -> {:ok, text, thinking, refusal}
      {:error, msg} -> {:error, %Error{kind: :protocol_error, message: msg}}
    end
  end

  defp parse_tool_calls(_tool_calls, "content_filter"), do: {:ok, []}
  defp parse_tool_calls(nil, _finish_reason), do: {:ok, []}

  defp parse_tool_calls(tool_calls, "length") when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> map_tool_calls(fn {tc, idx} -> parse_truncated_tool_call(tc, idx) end)
  end

  defp parse_tool_calls(tool_calls, _finish_reason) when is_list(tool_calls) do
    map_tool_calls(tool_calls, &parse_tool_call/1)
  end

  defp parse_tool_calls(_invalid, _finish_reason) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Malformed tool_calls payload: expected a list"
     }}
  end

  defp map_tool_calls(items, parser) do
    case Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
           case parser.(item) do
             {:ok, block} -> {:cont, {:ok, [block | acc]}}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      {:error, _} = err -> err
    end
  end

  defp parse_truncated_tool_call(tc, idx) when is_map(tc) do
    with {:ok, func} <- fetch_optional_map(tc, "function", "Malformed tool call function"),
         {:ok, name} <- fetch_optional_string(func, "name", "truncated") do
      id =
        if is_binary(tc["id"]) and tc["id"] != "",
          do: tc["id"],
          else: "truncated_#{idx}_#{System.unique_integer([:positive])}"

      # Truncated tool calls under finish_reason: "length" are always abandoned
      # by Turn on :max_tokens; fall back to %{} if arguments are missing,
      # cut-off JSON, or non-string/non-object.
      input =
        case Map.get(func, "arguments") do
          args when is_binary(args) and args != "" ->
            case Jason.decode(args) do
              {:ok, map} when is_map(map) -> map
              _ -> %{}
            end

          _ ->
            %{}
        end

      block = %{type: "tool_use", id: id, name: name, input: input}

      block =
        case OpenAIStream.extract_thought_signature(tc) do
          {:ok, sig} when is_binary(sig) -> Map.put(block, :thought_signature, sig)
          _ -> block
        end

      {:ok, block}
    end
  end

  defp parse_truncated_tool_call(_invalid, _idx) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Malformed tool call: expected a map"
     }}
  end

  defp fetch_optional_map(map, key, err_msg) do
    case Map.get(map, key) do
      nil -> {:ok, %{}}
      val when is_map(val) -> {:ok, val}
      _invalid -> {:error, %Error{kind: :protocol_error, message: err_msg}}
    end
  end

  defp fetch_optional_string(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      "" -> {:ok, default}
      val when is_binary(val) -> {:ok, val}
      _invalid -> {:error, %Error{kind: :protocol_error, message: "Malformed tool call #{key}"}}
    end
  end

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name} = func} = tc)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    args_result =
      case Map.fetch(func, "arguments") do
        :error -> {:ok, %{}}
        {:ok, args} -> decode_tool_arguments(args, name)
      end

    with {:ok, input} <- args_result,
         {:ok, sig} <- OpenAIStream.extract_thought_signature(tc) do
      block = %{type: "tool_use", id: id, name: name, input: input}
      {:ok, if(sig, do: Map.put(block, :thought_signature, sig), else: block)}
    else
      {:error, %Error{} = err} -> {:error, err}
      {:error, msg} -> {:error, %Error{kind: :protocol_error, message: msg}}
    end
  end

  defp parse_tool_call(_invalid) do
    {:error,
     %Error{
       kind: :protocol_error,
       message: "Malformed tool call: missing valid id or function definition"
     }}
  end

  defp decode_tool_arguments("", _name), do: {:ok, %{}}

  defp decode_tool_arguments(args, name) when is_binary(args) do
    case Jason.decode(args) do
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
  end

  defp decode_tool_arguments(args, _name) when is_map(args), do: {:ok, args}

  defp decode_tool_arguments(_args, name) do
    {:error,
     %Error{kind: :malformed_reply, message: "Invalid tool call arguments payload for #{name}"}}
  end
end
