defmodule Alloy.Message do
  @moduledoc """
  Normalized message struct used throughout Alloy.

  All providers translate their wire format to/from this struct.
  Internal format uses content blocks (similar to Anthropic's API)
  since it's the most expressive.

  ## Content Block Types

  ### Text and tool blocks
  - `%{type: "text", text: "..."}` - Plain text
  - `%{type: "tool_use", id: "...", name: "...", input: %{}}` - Tool call from assistant
  - `%{type: "tool_result", tool_use_id: "...", content: "..."}` - Tool execution result

  ### Media blocks (pass-through — providers map these to their wire format)
  - `%{type: "image", mime_type: "image/jpeg", data: "base64..."}` - Inline image
  - `%{type: "audio", mime_type: "audio/mp3", data: "base64..."}` - Inline audio
  - `%{type: "video", mime_type: "video/mp4", data: "base64..."}` - Inline video
  - `%{type: "document", mime_type: "application/pdf", uri: "..."}` - URI-referenced document

  Alloy Core does not read, transcode, or base64-encode media. It expects callers
  (e.g. Anvil connectors) to supply pre-encoded data or provider-specific URIs.

  ### Reasoning and provider-specific blocks

  Assistant messages can also hold blocks only their own provider can read
  back: `"thinking"` with a `:signature` (Anthropic, Gemini), `"redacted_thinking"`,
  `"reasoning"` and `"output_item"` (OpenAI and xAI raw items), `"server_tool_use"`
  and server tool results (Anthropic), and `:signature` or
  `:thought_signature` on text and tool-call blocks (Gemini).

  ## Provenance

  The loop records which provider and model wrote each assistant message in
  `:provider` and `:model`, and in `:origin` a fingerprint of the provider
  module, its `:api_url` and its `:api_key` (a hash; the key itself is never
  stored). All three are `nil` for messages you build yourself. When a
  conversation moves to a different origin — a fallback provider, another
  account or endpoint, or a different provider after a model switch —
  `normalize_for/3` rewrites the other origin's messages so the new one can
  read them; see its docs. Persist these fields with your transcripts:
  without them a reloaded message is sent as it is.
  """

  @type role :: :user | :assistant
  @type content_block :: map()

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [content_block()],
          provider: module() | nil,
          model: String.t() | nil,
          origin: String.t() | nil
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, provider: nil, model: nil, origin: nil]

  # Blocks every provider can read. Anything else in another provider's
  # message is that provider's own (signed reasoning, raw items, server tool
  # records) and cannot be sent to a different one.
  @portable_blocks ["text", "tool_use", "image", "audio", "video", "document"]

  # Signatures bind a block to the model that produced it.
  @signature_keys [:signature, :thought_signature]

  # Anthropic accepts tool-use ids matching ^[a-zA-Z0-9_-]+$; OpenAI accepts
  # at most 64 characters. Kimi, for one, uses ids like "functions.read:0".
  @portable_tool_id ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @doc """
  Creates a user message with text content.
  """
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text) do
    %__MODULE__{role: :user, content: text}
  end

  @doc """
  Creates an assistant message with text content.
  """
  @spec assistant(String.t()) :: t()
  def assistant(text) when is_binary(text) do
    %__MODULE__{role: :assistant, content: text}
  end

  @doc """
  Creates an assistant message with content blocks (used for tool calls).
  """
  @spec assistant_blocks([content_block()]) :: t()
  def assistant_blocks(blocks) when is_list(blocks) do
    %__MODULE__{role: :assistant, content: blocks}
  end

  @doc """
  Creates a user message containing tool results.
  """
  @spec tool_results([content_block()]) :: t()
  def tool_results(results) when is_list(results) do
    %__MODULE__{role: :user, content: results}
  end

  @doc """
  Extracts plain text from a message, ignoring tool blocks.

  Joins the message's text blocks with newlines. Returns `""` (never `nil`)
  when the message has no text blocks, for example when it only calls tools.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && &1[:type] == "text"))
    |> Enum.map_join("\n", & &1[:text])
  end

  @doc """
  Extracts thinking/reasoning text from a message, joining all thinking blocks.

  Returns `nil` when the message carries no thinking content (plain-text
  messages and messages without `"thinking"` blocks).
  """
  @spec thinking(t()) :: String.t() | nil
  def thinking(%__MODULE__{content: content}) when is_binary(content), do: nil

  def thinking(%__MODULE__{content: blocks}) when is_list(blocks) do
    case Enum.filter(blocks, &(is_map(&1) && &1[:type] == "thinking")) do
      [] -> nil
      thinking_blocks -> Enum.map_join(thinking_blocks, "\n", & &1[:thinking])
    end
  end

  @doc """
  Extracts tool_use blocks from an assistant message.
  """
  @spec tool_calls(t()) :: [content_block()]
  def tool_calls(%__MODULE__{content: blocks}) when is_list(blocks) do
    # server_tool_use blocks were already executed by the provider (code
    # execution, web search, tool search); the client must not answer them.
    Enum.filter(blocks, &(is_map(&1) && &1[:type] == "tool_use"))
  end

  def tool_calls(%__MODULE__{}), do: []

  @doc """
  Builds a tool_result content block.
  """
  @spec tool_result_block(String.t(), String.t(), boolean()) :: content_block()
  def tool_result_block(tool_use_id, content, is_error \\ false) do
    result = %{type: "tool_result", tool_use_id: tool_use_id, content: content}
    if is_error, do: Map.put(result, :is_error, true), else: result
  end

  @doc """
  Creates an inline image content block.

  `mime_type` should be one of `"image/jpeg"`, `"image/png"`, `"image/gif"`,
  `"image/webp"`. `data` must be a base64-encoded string of the raw image bytes.
  """
  @spec image(String.t(), String.t()) :: content_block()
  def image(mime_type, data), do: %{type: "image", mime_type: mime_type, data: data}

  @doc """
  Creates an inline audio content block.

  `mime_type` is typically `"audio/mp3"`, `"audio/wav"`, `"audio/ogg"`, etc.
  `data` must be a base64-encoded string of the raw audio bytes.
  """
  @spec audio(String.t(), String.t()) :: content_block()
  def audio(mime_type, data), do: %{type: "audio", mime_type: mime_type, data: data}

  @doc """
  Creates an inline video content block.

  `mime_type` is typically `"video/mp4"`, `"video/webm"`, etc.
  `data` must be a base64-encoded string of the raw video bytes.
  """
  @spec video(String.t(), String.t()) :: content_block()
  def video(mime_type, data), do: %{type: "video", mime_type: mime_type, data: data}

  @doc """
  Creates a URI-referenced document content block.

  Used with provider APIs that require pre-uploaded files (e.g. Google File API).
  `uri` is the provider-specific URI returned after uploading the file.
  """
  @spec document(String.t(), String.t()) :: content_block()
  def document(mime_type, uri), do: %{type: "document", mime_type: mime_type, uri: uri}

  @doc """
  The origin fingerprint for a provider and its config: a hash of the
  module, `:api_url` and `:api_key`. Two configs share an origin exactly
  when they reach the same endpoint with the same credentials.
  """
  @spec origin(module(), map()) :: String.t()
  def origin(provider, config) when is_atom(provider) and is_map(config) do
    input =
      Enum.map_join(
        [inspect(provider), Map.get(config, :api_url), Map.get(config, :api_key)],
        "\n",
        &origin_part/1
      )

    :sha256 |> :crypto.hash(input) |> Base.encode16(case: :lower) |> binary_slice(0, 16)
  end

  defp origin_part(nil), do: ""
  defp origin_part(value) when is_binary(value), do: value
  defp origin_part(value), do: inspect(value)

  @doc """
  Prepares a conversation for `provider` configured with `config`.

  Assistant messages from a different origin (see "Provenance") — another
  provider module, endpoint or account — are rewritten so `provider` can
  read them, following the rules the providers document:

    * thinking becomes plain text (empty thinking is dropped), so the new
      model keeps the earlier reasoning without a signature it can't verify
    * other provider-specific blocks are dropped: redacted thinking,
      OpenAI and xAI raw items, server tool records
    * signatures are removed from text and tool-call blocks
    * tool-call ids outside `[a-zA-Z0-9_-]{1,64}` are rewritten, along
      with the tool results that answer them
    * a message left with no content is dropped

  Messages from the same origin, messages without one (built by hand, or
  persisted without the provenance fields) and user messages are
  unchanged. Switching models on one origin changes nothing: Anthropic,
  OpenAI and Gemini each document that their APIs handle another model's
  reasoning themselves. The result depends only on the arguments, so the
  same history is sent as the same bytes on every request.

  The loop applies this before every provider request, including fallback
  providers; call it yourself only when you call a provider directly.
  """
  @spec normalize_for([t()], module(), map()) :: [t()]
  def normalize_for(messages, provider, config)
      when is_list(messages) and is_atom(provider) and is_map(config) do
    target = origin(provider, config)
    {messages, _renamed_ids} = Enum.flat_map_reduce(messages, %{}, &normalize(&1, &2, target))
    messages
  end

  defp normalize(%__MODULE__{role: :assistant, origin: from} = message, ids, target)
       when from in [nil, target],
       do: {[message], ids}

  defp normalize(%__MODULE__{role: :assistant, content: text} = message, ids, _target)
       when is_binary(text),
       do: {[message], ids}

  defp normalize(%__MODULE__{role: :assistant, content: blocks} = message, ids, _target) do
    case Enum.flat_map_reduce(blocks, ids, &foreign_block/2) do
      {[], ids} -> {[], ids}
      {blocks, ids} -> {[%{message | content: blocks}], ids}
    end
  end

  defp normalize(%__MODULE__{role: :user, content: blocks} = message, ids, _target)
       when is_list(blocks) and map_size(ids) > 0,
       do: {[%{message | content: Enum.map(blocks, &rename_result(&1, ids))}], ids}

  defp normalize(message, ids, _target), do: {[message], ids}

  defp foreign_block(%{type: "thinking", thinking: thinking}, ids) when is_binary(thinking) do
    case String.trim(thinking) do
      "" -> {[], ids}
      _text -> {[%{type: "text", text: thinking}], ids}
    end
  end

  defp foreign_block(%{type: "tool_use", id: id} = block, ids) when is_binary(id) do
    case portable_tool_id(id) do
      ^id -> {[Map.drop(block, @signature_keys)], ids}
      new_id -> {[%{Map.drop(block, @signature_keys) | id: new_id}], Map.put(ids, id, new_id)}
    end
  end

  # Blank text survives only for its signature, which is being removed, and
  # Anthropic rejects an empty text block.
  defp foreign_block(%{type: "text", text: text} = block, ids) when is_binary(text) do
    case String.trim(text) do
      "" -> {[], ids}
      _text -> {[Map.drop(block, @signature_keys)], ids}
    end
  end

  defp foreign_block(%{type: type} = block, ids) when type in @portable_blocks,
    do: {[Map.drop(block, @signature_keys)], ids}

  defp foreign_block(_block, ids), do: {[], ids}

  defp rename_result(%{type: "tool_result", tool_use_id: id} = block, ids) do
    case ids do
      %{^id => new_id} -> %{block | tool_use_id: new_id}
      _ids -> block
    end
  end

  defp rename_result(block, _ids), do: block

  # A rewritten id ends in a hash of the original, so two ids that sanitize
  # alike ("a.b", "a:b") stay distinct, and the same history always yields
  # the same bytes (Anthropic rejects thinking whose earlier history changed).
  defp portable_tool_id(id) do
    if Regex.match?(@portable_tool_id, id) do
      id
    else
      hash = :sha256 |> :crypto.hash(id) |> Base.encode16(case: :lower) |> binary_slice(0, 8)
      prefix = id |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> binary_slice(0, 55)
      prefix <> "_" <> hash
    end
  end
end
