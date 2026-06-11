defmodule Alloy.Tool.Registry do
  @moduledoc """
  Builds tool schemas and function maps from tool definitions.

  Takes a list of modules implementing `Alloy.Tool` and/or
  `Alloy.Tool.Inline` structs (see `Alloy.Tool.inline/1`) and produces:
  1. Tool definitions (JSON Schema format for providers)
  2. A dispatch map from tool name → module or inline struct
  """

  alias Alloy.Tool.Inline

  @type tool :: module() | Inline.t()

  @doc """
  Build tool definitions and dispatch map from a list of tools.

  Each entry is either a module implementing `Alloy.Tool` or an
  `Alloy.Tool.Inline` struct. Returns `{tool_defs, tool_fns}` where:
  - `tool_defs` is a list of maps suitable for provider APIs
  - `tool_fns` maps tool name strings to their implementing tool
  """
  @spec build([tool()]) :: {[map()], %{String.t() => tool()}}
  def build(tools) when is_list(tools) do
    tools = Enum.map(tools, &validate!/1)
    tool_defs = Enum.map(tools, &tool_def/1)
    tool_fns = Map.new(tools, fn tool -> {tool_name(tool), tool} end)
    {tool_defs, tool_fns}
  end

  defp validate!(%Inline{} = tool), do: Inline.validate!(tool)
  defp validate!(mod) when is_atom(mod), do: mod

  defp validate!(other) do
    raise ArgumentError,
          "tools must be modules implementing Alloy.Tool or Alloy.Tool.Inline " <>
            "structs (see Alloy.Tool.inline/1). Got: #{inspect(other)}"
  end

  defp tool_name(%Inline{name: name}), do: name
  defp tool_name(mod), do: mod.name()

  defp tool_def(%Inline{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
    |> maybe_put(:allowed_callers, tool.allowed_callers)
    |> maybe_put(:result_type, tool.result_type)
  end

  defp tool_def(mod) do
    %{
      name: mod.name(),
      description: mod.description(),
      input_schema: mod.input_schema()
    }
    |> maybe_put_optional(mod, :allowed_callers, 0)
    |> maybe_put_optional(mod, :result_type, 0)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_optional(map, mod, callback, arity) do
    if function_exported?(mod, callback, arity) do
      Map.put(map, callback, apply(mod, callback, []))
    else
      map
    end
  end
end
