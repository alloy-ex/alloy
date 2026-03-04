defmodule Alloy.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Registry

  defmodule BasicTool do
    @behaviour Alloy.Tool
    @impl true
    def name, do: "basic"
    @impl true
    def description, do: "A basic tool"
    @impl true
    def input_schema, do: %{type: "object", properties: %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule AnnotatedTool do
    @behaviour Alloy.Tool
    @impl true
    def name, do: "annotated"
    @impl true
    def description, do: "A tool with metadata"
    @impl true
    def input_schema, do: %{type: "object", properties: %{x: %{type: "string"}}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "ok"}

    @impl true
    def allowed_callers, do: [:human, :code_execution]

    @impl true
    def result_type, do: :structured
  end

  defmodule HumanOnlyTool do
    @behaviour Alloy.Tool
    @impl true
    def name, do: "human_only"
    @impl true
    def description, do: "Human-only tool"
    @impl true
    def input_schema, do: %{type: "object", properties: %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "ok"}

    @impl true
    def allowed_callers, do: [:human]
  end

  describe "build/1" do
    test "basic tool produces definitions without metadata" do
      {defs, fns} = Registry.build([BasicTool])

      assert [def_map] = defs
      assert def_map.name == "basic"
      assert def_map.description == "A basic tool"
      assert def_map.input_schema == %{type: "object", properties: %{}}
      refute Map.has_key?(def_map, :allowed_callers)
      refute Map.has_key?(def_map, :result_type)

      assert fns == %{"basic" => BasicTool}
    end

    test "annotated tool includes allowed_callers and result_type in definition" do
      {defs, fns} = Registry.build([AnnotatedTool])

      assert [def_map] = defs
      assert def_map.name == "annotated"
      assert def_map.allowed_callers == [:human, :code_execution]
      assert def_map.result_type == :structured

      assert fns == %{"annotated" => AnnotatedTool}
    end

    test "tool with only allowed_callers includes it but not result_type" do
      {defs, _fns} = Registry.build([HumanOnlyTool])

      assert [def_map] = defs
      assert def_map.allowed_callers == [:human]
      refute Map.has_key?(def_map, :result_type)
    end

    test "multiple tools — metadata only on those that implement optional callbacks" do
      {defs, fns} = Registry.build([BasicTool, AnnotatedTool, HumanOnlyTool])

      assert length(defs) == 3
      assert map_size(fns) == 3

      basic_def = Enum.find(defs, &(&1.name == "basic"))
      refute Map.has_key?(basic_def, :allowed_callers)

      annotated_def = Enum.find(defs, &(&1.name == "annotated"))
      assert annotated_def.allowed_callers == [:human, :code_execution]
      assert annotated_def.result_type == :structured

      human_def = Enum.find(defs, &(&1.name == "human_only"))
      assert human_def.allowed_callers == [:human]
      refute Map.has_key?(human_def, :result_type)
    end

    test "empty tool list returns empty results" do
      assert Registry.build([]) == {[], %{}}
    end
  end
end
