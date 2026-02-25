defmodule Anvil.Context.SystemPrompt do
  @moduledoc """
  Composable system prompt builder.

  Combines a base prompt with named sections and optional tool descriptions.
  """

  @doc """
  Builds a system prompt from a base string and optional named sections.

  Sections are joined with double newline separators.

  ## Examples

      iex> Anvil.Context.SystemPrompt.build("You are helpful.", rules: "Be concise")
      "You are helpful.\\n\\nBe concise"
  """
  @spec build(String.t(), keyword(String.t())) :: String.t()
  def build(base, sections \\ [])

  def build(base, []), do: base

  def build(base, sections) do
    section_texts = Enum.map(sections, fn {_key, value} -> value end)

    [base | section_texts]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Appends an "## Available Tools" section listing tool names and descriptions.

  Returns the base prompt unchanged if no tools are provided.
  """
  @spec with_tool_descriptions(String.t(), [map()]) :: String.t()
  def with_tool_descriptions(prompt, []), do: prompt

  def with_tool_descriptions(prompt, tool_defs) do
    tool_lines =
      Enum.map_join(tool_defs, "\n", fn tool ->
        "- **#{tool.name}**: #{tool.description}"
      end)

    prompt <> "\n\n## Available Tools\n\n" <> tool_lines
  end
end
