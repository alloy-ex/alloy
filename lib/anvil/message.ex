defmodule Anvil.Message do
  @moduledoc """
  Normalized message struct used throughout Anvil.

  All providers translate their wire format to/from this struct.
  Internal format uses content blocks (similar to Anthropic's API)
  since it's the most expressive.

  ## Content Block Types

  - `%{type: "text", text: "..."}` - Plain text
  - `%{type: "tool_use", id: "...", name: "...", input: %{}}` - Tool call from assistant
  - `%{type: "tool_result", tool_use_id: "...", content: "..."}` - Tool execution result
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
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && &1[:type] == "text"))
    |> Enum.map_join("\n", & &1[:text])
    |> case do
      "" -> nil
      text -> text
    end
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
end
