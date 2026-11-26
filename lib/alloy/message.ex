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
  - `%{type: "image", url: "https://..."}` - URL-referenced image (optional `:mime_type`)
  - `%{type: "audio", mime_type: "audio/mp3", data: "base64..."}` - Inline audio
  - `%{type: "video", mime_type: "video/mp4", data: "base64..."}` - Inline video
  - `%{type: "document", mime_type: "application/pdf", data: "base64..."}` - Inline document (optional `:filename`, `:title`)
  - `%{type: "document", mime_type: "application/pdf", uri: "..."}` - URL/URI-referenced document
  - `%{type: "document", mime_type: "application/pdf", file_id: "..."}` - Provider Files API document (origin-scoped)

  Alloy Core does not read, transcode, or base64-encode media. It expects callers
  (e.g. Anvil connectors) to supply pre-encoded data or provider-specific URIs.

  ### Reasoning and provider-specific blocks

  Assistant messages can also hold blocks only their own provider can read
  back: `"thinking"` with a `:signature` (Anthropic, Gemini) or
  `source: "content_part"` (OpenAI-compatible array-of-parts thinking, which
  is withheld from top-level `reasoning_content` echo on subsequent turns),
  `"redacted_thinking"`, `"reasoning"` and `"output_item"` (OpenAI and xAI raw
  items), `"server_tool_use"` and server tool results (Anthropic),
  `"gemini_part"` (Gemini native `executableCode`, `codeExecutionResult`,
  `toolCall`, and `toolResponse` parts), and `:signature` or
  `:thought_signature` on text and tool-call blocks (Gemini).

  ## Provenance

  The loop records which provider and model wrote each assistant message in
  `:provider` and `:model`, and in `:origin` a fingerprint of the provider
  module, its `:api_url`, and its `:origin_key` (falling back to `:api_key`,
  hashed so credentials are never stored). All three are `nil` for messages you
  build yourself. Set a stable `:origin_key` whenever persisting transcripts
  across credential changes (required for function `:api_key` and
  `auth_scheme: :bearer`, and recommended for static API keys that may rotate):
  without `:origin_key`, rotating the credential changes the origin fingerprint
  and causes earlier assistant messages and provider-specific file attachments
  to be treated as foreign on resumed turns. When a conversation moves to a
  different origin — a fallback provider, another account or endpoint, or a
  different provider after a model switch — `normalize_for/3` rewrites the
  other origin's messages and omits foreign provider-specific file attachments;
  see its docs. Persist these fields with your transcripts: without them a
  reloaded message is sent as it is.
  """

  alias Alloy.Provider.HTTP

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
  Creates a URL-referenced image content block.

  Supported by Anthropic, OpenAI/xAI Responses, OpenAICompat, and Gemini
  (pass `mime_type: "image/png"` in `opts` when sending URL images to Gemini).
  Account-scoped Gemini File API URIs
  (`https://generativelanguage.googleapis.com/.../files/...`) are treated as
  origin-scoped and degraded safely if a run switches or falls back to another
  provider or account.
  """
  @spec image_url(String.t(), keyword()) :: content_block()
  def image_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
    base = %{type: "image", url: url}

    case Keyword.get(opts, :mime_type) do
      mime when is_binary(mime) and mime != "" -> Map.put(base, :mime_type, mime)
      _ -> base
    end
  end

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
  Creates a URL- or URI-referenced document content block.

  Accepts public HTTP(S) URLs (supported by Anthropic for PDFs, OpenAI/xAI, and
  Gemini) as well as GCS URIs (`gs://...`, used with Gemini). Prefer
  `document_file/3` for account-scoped provider Files API references (including
  Gemini File API URIs); Gemini File API URIs
  (`https://generativelanguage.googleapis.com/.../files/...`) passed here are
  still treated as origin-scoped and degraded safely if a run switches or falls
  back to another provider. Optional `:filename` and `:title` keys may be
  passed in `opts`.
  """
  @spec document(String.t(), String.t(), keyword()) :: content_block()
  def document(mime_type, uri, opts \\ [])
      when is_binary(mime_type) and is_binary(uri) and is_list(opts) do
    %{type: "document", mime_type: mime_type, uri: uri}
    |> put_document_opts(opts)
  end

  @doc """
  Creates an inline base64-encoded document content block (for example a PDF).

  Supported natively by Anthropic, OpenAI/xAI Responses, and Gemini. Optional
  `:filename` and `:title` keys may be passed in `opts`.
  """
  @spec document_data(String.t(), String.t(), keyword()) :: content_block()
  def document_data(mime_type, data, opts \\ [])
      when is_binary(mime_type) and is_binary(data) and is_list(opts) do
    %{type: "document", mime_type: mime_type, data: data}
    |> put_document_opts(opts)
  end

  @doc """
  Creates a provider Files API document content block.

  Produces a document attachment (`document` / `input_file` / `fileData`, for
  PDF and document files rather than uploaded image file IDs). `file_id` is
  origin-scoped to the provider account that uploaded the file (Anthropic
  Files API, OpenAI Files API, or Gemini File URI). Pass
  `origin: Message.origin(provider, config)` (or `origin: {provider, config}`)
  to bind the attachment explicitly; during fallback runs Alloy also attributes
  unattributed user `file_id` attachments to the primary provider's origin so
  `normalize_for/3` omits them before calling a different provider or account.
  """
  @spec document_file(String.t(), String.t(), keyword()) :: content_block()
  def document_file(mime_type, file_id, opts \\ [])
      when is_binary(mime_type) and is_binary(file_id) and is_list(opts) do
    %{type: "document", mime_type: mime_type, file_id: file_id}
    |> put_document_opts(opts)
    |> put_document_origin(opts)
  end

  defp put_document_opts(block, opts) do
    Enum.reduce([:filename, :title], block, fn key, acc ->
      case Keyword.get(opts, key) do
        val when is_binary(val) and val != "" -> Map.put(acc, key, val)
        _ -> acc
      end
    end)
  end

  defp put_document_origin(block, opts) do
    case Keyword.get(opts, :origin) do
      origin_str when is_binary(origin_str) and origin_str != "" ->
        Map.put(block, :origin, origin_str)

      {provider, cfg} when is_atom(provider) and is_map(cfg) ->
        Map.put(block, :origin, origin(provider, cfg))

      {provider, cfg} when is_atom(provider) and is_list(cfg) ->
        Map.put(block, :origin, origin(provider, Map.new(cfg)))

      _ ->
        block
    end
  end

  @doc """
  The origin fingerprint for a provider and its config: a hash of the
  module, `:api_url`, and `:origin_key` (falling back to `:api_key`).
  `:origin_key` defines the account identity: two configs targeting the same
  provider module and endpoint share an origin when they use the same
  `:origin_key` (even across rotated credentials or multiple keys in the same
  project/workspace, such as a same-project Gemini fallback).

  Function-valued `:api_key` callbacks are never invoked during origin hashing.
  Because closure inspection does not capture runtime values and changes across
  recompiles, `Alloy.Agent.Config` requires a stable `:origin_key` string
  whenever `:api_key` is a function (or `auth_scheme: :bearer`); direct
  `origin/2` calls without `:origin_key` include `:erlang.fun_info(fun, :env)`
  so distinct captured accounts do not collide.
  """
  @spec origin(module(), map()) :: String.t()
  def origin(provider, config) when is_atom(provider) and is_map(config) do
    credential =
      case Map.get(config, :origin_key) do
        key when is_binary(key) and key != "" -> key
        _ -> Map.get(config, :api_key)
      end

    input =
      Enum.map_join(
        [inspect(provider), Map.get(config, :api_url), credential],
        "\n",
        &origin_part/1
      )

    :sha256 |> :crypto.hash(input) |> Base.encode16(case: :lower) |> binary_slice(0, 16)
  end

  defp origin_part(nil), do: ""
  defp origin_part(value) when is_binary(value), do: value

  defp origin_part(fun) when is_function(fun) do
    info = {
      :erlang.fun_info(fun, :module),
      :erlang.fun_info(fun, :name),
      :erlang.fun_info(fun, :uniq),
      :erlang.fun_info(fun, :env)
    }

    "fun:" <>
      (:sha256 |> :crypto.hash(:erlang.term_to_binary(info)) |> Base.encode16(case: :lower))
  end

  defp origin_part(value), do: inspect(value)

  @doc false
  @spec attribute_file_blocks([t()], String.t(), module() | nil) :: [t()]
  def attribute_file_blocks(messages, origin_id, provider \\ nil)
      when is_list(messages) and is_binary(origin_id) and is_atom(provider) do
    if Enum.any?(messages, &needs_file_attribution?(&1, provider)) do
      Enum.map(messages, &attribute_message_file_blocks(&1, origin_id, provider))
    else
      messages
    end
  end

  defp attribute_message_file_blocks(
         %__MODULE__{role: :user, origin: nil, content: blocks} = msg,
         origin_id,
         provider
       )
       when is_list(blocks) do
    %{msg | content: Enum.map(blocks, &attribute_file_block(&1, origin_id, provider))}
  end

  defp attribute_message_file_blocks(other, _origin_id, _provider), do: other

  defp attribute_file_block(block, origin_id, provider) do
    if attributable_file_block?(block, provider) and is_nil(Map.get(block, :origin)) do
      Map.put(block, :origin, origin_id)
    else
      block
    end
  end

  defp needs_file_attribution?(%__MODULE__{role: :user, origin: nil, content: blocks}, provider)
       when is_list(blocks) do
    Enum.any?(blocks, fn block ->
      attributable_file_block?(block, provider) and is_nil(Map.get(block, :origin))
    end)
  end

  defp needs_file_attribution?(_msg, _provider), do: false

  defp attributable_file_block?(%{type: "document", file_id: _}, _provider), do: true

  # Gemini File API URIs are recognizable by host/path and should only be bound
  # when running on Gemini (or when no provider context is given), so an
  # Anthropic/OpenAI primary with a Gemini fallback does not stamp them with the
  # non-Gemini origin.
  defp attributable_file_block?(block, provider)
       when provider in [nil, Alloy.Provider.Gemini],
       do: origin_scoped_file_block?(block)

  defp attributable_file_block?(_block, _provider), do: false

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

  Messages from the same origin and messages without one (built by hand, or
  persisted without the provenance fields) are unchanged except for any
  `file_id` document blocks that carry a different explicit `:origin` (or
  belong to a user message with a different `:origin`), which are omitted.
  Switching models on one origin changes nothing: Anthropic, OpenAI and Gemini
  each document that their APIs handle another model's reasoning themselves.
  The result depends only on the arguments, so the same history is sent as the
  same bytes on every request.

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

  # A same-origin (or unattributed) assistant message starts a new round with
  # no foreign ID renames, so later tool results reusing the same raw ID keep
  # their original pairing. Explicit block-level foreign `file_id` attachments
  # are still stripped so account-scoped file references never cross origins.
  defp normalize(
         %__MODULE__{role: :assistant, origin: from, content: blocks} = message,
         _ids,
         target
       )
       when from in [nil, target] and is_list(blocks) do
    case strip_foreign_assistant_file_blocks(blocks, target) do
      {[], true} -> {[], %{}}
      {kept, _dropped?} -> {[%{message | content: kept}], %{}}
    end
  end

  defp normalize(%__MODULE__{role: :assistant, origin: from} = message, _ids, target)
       when from in [nil, target],
       do: {[message], %{}}

  defp normalize(%__MODULE__{role: :assistant, content: text} = message, _ids, _target)
       when is_binary(text),
       do: {[message], %{}}

  defp normalize(%__MODULE__{role: :assistant, content: blocks} = message, _ids, _target) do
    case Enum.flat_map_reduce(blocks, %{}, &foreign_block/2) do
      {[], ids} -> {[], ids}
      {blocks, ids} -> {[%{message | content: blocks}], ids}
    end
  end

  defp normalize(%__MODULE__{role: :user, content: blocks} = message, ids, target)
       when is_list(blocks) do
    has_tool_results? = Enum.any?(blocks, &(is_map(&1) and &1[:type] == "tool_result"))

    {blocks, next_ids} =
      if map_size(ids) > 0 and has_tool_results? do
        {Enum.map(blocks, &rename_result(&1, ids)), ids}
      else
        {blocks, %{}}
      end

    blocks = strip_foreign_user_file_blocks(blocks, message.origin, target)
    {[%{message | content: blocks}], next_ids}
  end

  defp normalize(%__MODULE__{role: :user} = message, _ids, _target), do: {[message], %{}}

  defp normalize(message, ids, _target), do: {[message], ids}

  defp strip_foreign_assistant_file_blocks(blocks, target) do
    {kept, dropped?} =
      Enum.reduce(blocks, {[], false}, fn block, {acc, dropped?} ->
        block_origin = if is_map(block), do: Map.get(block, :origin), else: nil

        if origin_scoped_file_block?(block) and is_binary(block_origin) and
             block_origin != target do
          {acc, true}
        else
          {[block | acc], dropped?}
        end
      end)

    {Enum.reverse(kept), dropped?}
  end

  defp strip_foreign_user_file_blocks(blocks, msg_origin, target) do
    Enum.map(blocks, fn block ->
      if origin_scoped_file_block?(block) do
        eff_origin = Map.get(block, :origin) || msg_origin

        if eff_origin != nil and eff_origin != target do
          %{type: "text", text: "[Omitted provider-specific file attachment]"}
        else
          block
        end
      else
        block
      end
    end)
  end

  defp origin_scoped_file_block?(%{type: "document", file_id: _}), do: true

  defp origin_scoped_file_block?(%{type: "document", uri: uri}),
    do: HTTP.provider_file_uri?(uri)

  defp origin_scoped_file_block?(%{type: "image", url: url}),
    do: HTTP.provider_file_uri?(url)

  defp origin_scoped_file_block?(_block), do: false

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

  # Files API IDs and account-scoped provider file URIs belong strictly to the
  # provider account that uploaded them.
  defp foreign_block(%{type: "document", file_id: _}, ids), do: {[], ids}

  defp foreign_block(%{type: "document", uri: uri} = block, ids) do
    if HTTP.provider_file_uri?(uri) do
      {[], ids}
    else
      {[Map.drop(block, @signature_keys)], ids}
    end
  end

  defp foreign_block(%{type: "image", url: url} = block, ids) do
    if HTTP.provider_file_uri?(url) do
      {[], ids}
    else
      {[Map.drop(block, @signature_keys)], ids}
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
