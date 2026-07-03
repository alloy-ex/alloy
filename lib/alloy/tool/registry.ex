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
    def_map = %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }

    validate_strict_schema!(def_map, tool.strict)

    def_map
    |> maybe_put(:allowed_callers, tool.allowed_callers)
    |> maybe_put(:result_type, tool.result_type)
    |> maybe_put_strict(tool.strict)
    |> maybe_put_non_empty(:input_examples, tool.input_examples)
    |> maybe_put_true(:defer_loading, tool.defer_loading)
  end

  defp tool_def(mod) do
    def_map = %{
      name: mod.name(),
      description: mod.description(),
      input_schema: mod.input_schema()
    }

    strict = optional_callback(mod, :strict?, 0, false)
    validate_strict_schema!(def_map, strict)

    def_map
    |> maybe_put_optional(mod, :allowed_callers, 0)
    |> maybe_put_optional(mod, :result_type, 0)
    |> maybe_put_strict(strict)
    |> maybe_put_optional_non_empty(mod, :input_examples, 0)
    |> maybe_put_optional_true(mod, :defer_loading?, 0, :defer_loading)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_strict(map, true), do: Map.put(map, :strict, true)
  defp maybe_put_strict(map, _strict), do: map

  defp maybe_put_non_empty(map, _key, nil), do: map
  defp maybe_put_non_empty(map, _key, []), do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _value), do: map

  defp maybe_put_optional(map, mod, callback, arity) do
    if function_exported?(mod, callback, arity) do
      Map.put(map, callback, apply(mod, callback, []))
    else
      map
    end
  end

  defp optional_callback(mod, callback, arity, default) do
    if function_exported?(mod, callback, arity) do
      apply(mod, callback, [])
    else
      default
    end
  end

  defp maybe_put_optional_non_empty(map, mod, callback, arity) do
    if function_exported?(mod, callback, arity) do
      maybe_put_non_empty(map, callback, apply(mod, callback, []))
    else
      map
    end
  end

  defp maybe_put_optional_true(map, mod, callback, arity, key) do
    if function_exported?(mod, callback, arity) do
      maybe_put_true(map, key, apply(mod, callback, []))
    else
      map
    end
  end

  defp validate_strict_schema!(_def_map, false), do: :ok
  defp validate_strict_schema!(_def_map, nil), do: :ok

  defp validate_strict_schema!(%{name: name, input_schema: schema}, true) do
    if Map.get(schema, :additionalProperties) == false or
         Map.get(schema, "additionalProperties") == false do
      :ok
    else
      raise ArgumentError,
            "strict tool #{inspect(name)} input_schema must include " <>
              "additionalProperties: false. OpenAI strict mode also requires every " <>
              "property to be listed in required."
    end
  end
end
