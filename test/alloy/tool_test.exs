defmodule Alloy.ToolTest.MinimalTool do
  @moduledoc false
  @behaviour Alloy.Tool

  @impl true
  def name, do: "minimal_tool"

  @impl true
  def description, do: "A tool with only required callbacks"

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, required: []}

  @impl true
  def execute(_input, _context), do: {:ok, "done"}
end

defmodule Alloy.ToolTest.AnnotatedTool do
  @moduledoc false
  @behaviour Alloy.Tool

  @impl true
  def name, do: "annotated_tool"

  @impl true
  def description, do: "A tool with optional callbacks implemented"

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, required: []}

  @impl true
  def execute(_input, _context), do: {:ok, "done"}

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :structured
end

defmodule Alloy.ToolTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool

  describe "optional callbacks" do
    test "tool without optional callbacks compiles and works" do
      mod = Alloy.ToolTest.MinimalTool
      assert mod.name() == "minimal_tool"
      assert mod.execute(%{}, %{}) == {:ok, "done"}
      refute function_exported?(mod, :allowed_callers, 0)
      refute function_exported?(mod, :result_type, 0)
    end

    test "tool with optional callbacks exports them" do
      mod = Alloy.ToolTest.AnnotatedTool
      assert mod.name() == "annotated_tool"
      assert function_exported?(mod, :allowed_callers, 0)
      assert function_exported?(mod, :result_type, 0)
      assert mod.allowed_callers() == [:human, :code_execution]
      assert mod.result_type() == :structured
    end
  end

  describe "resolve_path/2" do
    test "absolute paths are returned as-is" do
      assert {:ok, "/usr/local/bin/elixir"} = Tool.resolve_path("/usr/local/bin/elixir", %{})

      assert {:ok, "/tmp/test.txt"} =
               Tool.resolve_path("/tmp/test.txt", %{working_directory: "/other"})
    end

    test "relative paths are joined with working_directory" do
      assert {:ok, "/project/mix.exs"} =
               Tool.resolve_path("mix.exs", %{working_directory: "/project"})
    end

    test "nested relative paths are joined correctly" do
      assert {:ok, "/project/lib/alloy.ex"} =
               Tool.resolve_path("lib/alloy.ex", %{working_directory: "/project"})
    end

    test "relative paths without working_directory expand from cwd" do
      assert {:ok, result} = Tool.resolve_path("mix.exs", %{})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "relative paths with nil working_directory expand from cwd" do
      assert {:ok, result} = Tool.resolve_path("mix.exs", %{working_directory: nil})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "handles dot-relative paths" do
      assert {:ok, "/project/test.txt"} =
               Tool.resolve_path("./test.txt", %{working_directory: "/project"})
    end

    test "handles parent directory references" do
      assert {:ok, "/project/other/file.ex"} =
               Tool.resolve_path("../other/file.ex", %{working_directory: "/project/lib"})
    end
  end
end
