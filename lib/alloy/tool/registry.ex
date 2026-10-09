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
    specs = Enum.map(tools, &(&1 |> validate!() |> to_inline() |> Inline.validate!()))
    reject_duplicate_names!(specs)
    tool_defs = Enum.map(specs, &tool_def/1)
    tool_fns = tools |> Enum.zip(specs) |> Map.new(fn {tool, spec} -> {spec.name, tool} end)
    {tool_defs, tool_fns}
  end

  @doc false
  # One shape for both kinds of tool, so the definition builder and the
  # executor handle modules and inline tools with the same code. A module's
  # missing optional callbacks become the inline defaults.
  @spec to_inline(tool()) :: Inline.t()
  def to_inline(%Inline{} = tool), do: tool

  def to_inline(mod) when is_atom(mod) do
    name = mod.name()

    %Inline{
      name: name,
      description: mod.description(),
      input_schema: mod.input_schema(),
      execute: &mod.execute/2,
      concurrent?: optional(mod, :concurrent?, true),
      max_result_chars: optional(mod, :max_result_chars, nil),
      allowed_callers: optional(mod, :allowed_callers, nil),
      result_type: optional(mod, :result_type, nil),
      strict: optional(mod, :strict?, false),
      input_examples: optional(mod, :input_examples, []),
      defer_loading: optional(mod, :defer_loading?, false),
      native_types: optional(mod, :native_types, %{})
    }
  end

  defp optional(mod, callback, default) do
    if function_exported?(mod, callback, 0), do: apply(mod, callback, []), else: default
  end

  # Every provider API rejects a request with two tools of the same name,
  # and only one of them could ever be dispatched.
  defp reject_duplicate_names!(specs) do
    case for({name, count} <- Enum.frequencies_by(specs, & &1.name), count > 1, do: name) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "tool names must be unique; configured more than once: #{inspect(duplicates)}"
    end
  end

  defp validate!(%Inline{} = tool), do: tool
  defp validate!(mod) when is_atom(mod), do: mod

  defp validate!(other) do
    raise ArgumentError,
          "tools must be modules implementing Alloy.Tool or Alloy.Tool.Inline " <>
            "structs (see Alloy.Tool.inline/1). Got: #{inspect(other)}"
  end

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
    |> maybe_put_true(:strict, tool.strict)
    |> maybe_put_non_empty(:input_examples, tool.input_examples)
    |> maybe_put_true(:defer_loading, tool.defer_loading)
    |> maybe_put_non_empty(:native_types, tool.native_types)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_non_empty(map, _key, nil), do: map
  defp maybe_put_non_empty(map, _key, []), do: map
  defp maybe_put_non_empty(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _value), do: map

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
