defmodule Alloy.Tool.Registry do
  @moduledoc """
  Builds tool schemas and function maps from tool modules.

  Takes a list of modules implementing `Alloy.Tool` and produces:
  1. Tool definitions (JSON Schema format for providers)
  2. A dispatch map from tool name → module for execution
  """

  @doc """
  Build tool definitions and dispatch map from a list of tool modules.

  Returns `{tool_defs, tool_fns}` where:
  - `tool_defs` is a list of maps suitable for provider APIs
  - `tool_fns` maps tool name strings to their implementing module
  """
  @spec build([module()]) :: {[map()], %{String.t() => module()}}
  def build(tool_modules) when is_list(tool_modules) do
    tool_defs =
      Enum.map(tool_modules, fn mod ->
        %{
          name: mod.name(),
          description: mod.description(),
          input_schema: mod.input_schema()
        }
      end)

    tool_fns =
      Map.new(tool_modules, fn mod ->
        {mod.name(), mod}
      end)

    {tool_defs, tool_fns}
  end
end
