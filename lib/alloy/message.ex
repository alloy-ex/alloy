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
  """

  @type role :: :user | :assistant
  @type content_block :: map()

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [content_block()]
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

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
  Returns nil if no text content exists.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && &1[:type] == "text"))
    |> Enum.map_join("\n", & &1[:text])
  end

  @doc """
  Extracts tool_use blocks from an assistant message.
  """
  @spec tool_calls(t()) :: [content_block()]
  def tool_calls(%__MODULE__{content: blocks}) when is_list(blocks) do
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
end
