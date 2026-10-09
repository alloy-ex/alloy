defmodule Alloy.Provider.OpenAI do
  @moduledoc """
  Provider for OpenAI's Responses API.

  Normalizes OpenAI's response output items (assistant messages + function
  calls) to Alloy's content-block format. Use this provider, not
  `Alloy.Provider.OpenAICompat`, for OpenAI models: starting with GPT-5.4,
  Chat Completions does not support tool calling with reasoning enabled.

  ## Config

  Required:
  - `:api_key` - OpenAI API key
  - `:model` - Model name (e.g., "gpt-6-astra", "gpt-6.1-sol", "gpt-5.4")

  Optional:
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

  alias Alloy.Message
  alias Alloy.Provider.{Error, HTTP}

  @default_api_url "https://api.openai.com"
  @terminal_events ["response.completed", "response.incomplete", "response.failed"]

  @typedoc """
  Configuration for the OpenAI provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:provider_state) => map(),
          optional(:store) => boolean(),
          optional(:include) => [String.t()],
          optional(:tool_choice) => String.t() | map(),
          optional(:parallel_tool_calls) => boolean(),
          optional(:previous_response_id) => String.t(),
          optional(:built_in_tools) => [map()],
          optional(:web_search) => boolean() | map(),
          optional(:x_search) => boolean() | map(),
          optional(:req_options) => keyword()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    body = build_request_body(messages, tool_defs, config)

    with {:ok, resp_body} <-
           HTTP.post_json(
             responses_url(config),
             headers(config),
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
    body =
      messages
      |> build_request_body(tool_defs, config)
      |> Map.put("stream", true)

    initial_acc = %{
      buffer: "",
      response: nil,
      stream_error: nil,
      on_chunk: on_chunk
    }

    with {:ok, acc} <-
           HTTP.stream_sse(
             responses_url(config),
             headers(config),
             body,
             initial_acc,
             &handle_stream_event/2,
             Map.get(config, :req_options, [])
           ) do
      build_stream_response(acc)
    end
  end

  defp responses_url(config), do: "#{Map.get(config, :api_url, @default_api_url)}/v1/responses"

  defp headers(config) do
    [{"authorization", "Bearer #{config.api_key}"}, {"content-type", "application/json"}]
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    input_items = build_input_items(messages, config)

    body =
      %{"model" => config.model, "input" => input_items}
      |> maybe_put_optional_request_field("max_output_tokens", Map.get(config, :max_tokens))
      |> maybe_put_optional_request_field(
        "previous_response_id",
        Map.get(config, :previous_response_id)
      )
      |> maybe_put_optional_request_field("store", Map.get(config, :store))
      |> maybe_put_optional_request_field("include", Map.get(config, :include))
      |> maybe_put_reasoning_include(config)
      |> maybe_put_optional_request_field("tool_choice", Map.get(config, :tool_choice))
      |> maybe_put_optional_request_field(
        "parallel_tool_calls",
        Map.get(config, :parallel_tool_calls)
      )

    tools =
      Enum.map(tool_defs, &format_tool_def/1) ++ built_in_tools(config)

    body =
      case tools do
        [] -> body
        defs -> Map.put(body, "tools", defs)
      end

    # Merge extra_body LAST so caller can override any field (#18)
    Map.merge(body, stringify_extra_body(Map.get(config, :extra_body, %{})))
  end

  defp stringify_extra_body(extra_body) when is_map(extra_body) do
    Map.new(extra_body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_extra_body(_), do: %{}

  defp maybe_put_optional_request_field(body, _key, nil), do: body
  defp maybe_put_optional_request_field(body, _key, value) when value == [], do: body
  defp maybe_put_optional_request_field(body, key, value), do: Map.put(body, key, value)

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

  defp format_user_content_block(%{type: "audio", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "video", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(_block), do: nil

  defp format_assistant_block(%{type: "text", text: text} = block, _stateless?)
       when is_binary(text) and text != "" do
    [
      maybe_put_optional_request_field(
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

  defp handle_stream_event(acc, %{event: event_name, data: data}) do
    case Jason.decode(data) do
      {:ok, parsed} ->
        event_type = event_name || Map.get(parsed, "type")
        process_stream_event(acc, event_type, parsed)

      {:error, _} ->
        acc
    end
  end

  defp process_stream_event(acc, "response.output_text.delta", %{"delta" => delta})
       when is_binary(delta) and delta != "" do
    acc.on_chunk.(delta)
    acc
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

  defp build_stream_response(%{stream_error: %Error{} = error}), do: {:error, error}

  defp build_stream_response(%{response: response}) when is_map(response),
    do: parse_response(response)

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

    case parse_output_to_blocks(output) do
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
    {:error, %Error{message: "Unexpected OpenAI response payload: #{inspect(resp)}"}}
  end

  defp parse_output_to_blocks(output) do
    result =
      Enum.reduce_while(output, {:ok, []}, fn item, {:ok, acc} ->
        case parse_output_item(item) do
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
         %{"type" => "message", "role" => "assistant", "content" => content} = item
       )
       when is_list(content) or is_binary(content) do
    {:ok, content |> parse_assistant_content() |> Enum.map(&put_phase(&1, item["phase"]))}
  end

  defp parse_output_item(%{"type" => "function_call", "name" => name} = call) do
    case decode_function_call_arguments(call) do
      {:ok, input} ->
        {:ok, [%{type: "tool_use", id: call["call_id"] || call["id"], name: name, input: input}]}

      {:error, _} = err ->
        err
    end
  end

  defp parse_output_item(%{"type" => "reasoning"} = item) do
    {:ok, [%{type: "reasoning", raw: item}]}
  end

  # Built-in tool calls (web search, code interpreter, MCP), compaction items
  # and types added later are kept whole, so a stateless replay sends the
  # complete output back as the API expects.
  defp parse_output_item(%{"type" => _type} = item),
    do: {:ok, [%{type: "output_item", raw: item}]}

  defp parse_output_item(_item), do: {:ok, []}

  defp parse_assistant_content(""), do: []
  defp parse_assistant_content(text) when is_binary(text), do: [%{type: "text", text: text}]

  defp parse_assistant_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} = item when is_binary(text) and text != "" ->
        [%{type: "text", text: text} |> maybe_put_annotations(item["annotations"])]

      %{"type" => "refusal", "refusal" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      %{"type" => "refusal", "text" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

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

  defp decode_function_call_arguments(%{"name" => name} = call) do
    args = Map.get(call, "arguments", "")

    case args do
      "" ->
        {:ok, %{}}

      encoded when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, input} -> {:ok, input}
          {:error, _} -> {:error, "Invalid JSON in tool call arguments for #{name}"}
        end

      decoded when is_map(decoded) ->
        {:ok, decoded}

      _other ->
        {:error, "Invalid tool call arguments payload for #{name}"}
    end
  end

  # Alloy.Usage follows Anthropic: input_tokens excludes cache reads and
  # writes, which have their own fields. OpenAI counts both inside
  # input_tokens, so they are taken out here.
  defp parse_usage(%{} = usage) do
    details = usage["input_tokens_details"] || %{}
    cache_read = details["cached_tokens"] || 0
    cache_write = details["cache_write_tokens"] || 0

    %{
      input_tokens: max((usage["input_tokens"] || 0) - cache_read - cache_write, 0),
      output_tokens: usage["output_tokens"] || 0,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_write
    }
  end

  defp parse_usage(nil), do: parse_usage(%{})

  defp provider_state_from_response(%{"id" => id}) when is_binary(id) and id != "" do
    %{response_id: id}
  end

  defp provider_state_from_response(_resp), do: %{}

  defp response_metadata_from_response(resp) do
    %{}
    |> maybe_put_response_metadata(:citations, Map.get(resp, "citations"))
    |> maybe_put_response_metadata(
      :server_side_tool_usage,
      Map.get(resp, "server_side_tool_usage")
    )
    |> maybe_put_response_metadata(:stop_details, stop_details(resp))
  end

  defp stop_details(%{"status" => "incomplete"} = resp), do: resp["incomplete_details"]
  defp stop_details(_resp), do: nil

  defp maybe_put_response_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_response_metadata(metadata, _key, value) when value == [], do: metadata
  defp maybe_put_response_metadata(metadata, key, value), do: Map.put(metadata, key, value)

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
