defmodule Alloy.ToolTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool

  describe "resolve_path/2" do
    test "absolute paths are returned as-is" do
      assert Tool.resolve_path("/usr/local/bin/elixir", %{}) == "/usr/local/bin/elixir"
      assert Tool.resolve_path("/tmp/test.txt", %{working_directory: "/other"}) == "/tmp/test.txt"
    end

    test "relative paths are joined with working_directory" do
      assert Tool.resolve_path("mix.exs", %{working_directory: "/project"}) ==
               "/project/mix.exs"
    end

    test "nested relative paths are joined correctly" do
      assert Tool.resolve_path("lib/alloy.ex", %{working_directory: "/project"}) ==
               "/project/lib/alloy.ex"
    end

    test "relative paths without working_directory expand from cwd" do
      result = Tool.resolve_path("mix.exs", %{})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "relative paths with nil working_directory expand from cwd" do
      result = Tool.resolve_path("mix.exs", %{working_directory: nil})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "handles dot-relative paths" do
      assert Tool.resolve_path("./test.txt", %{working_directory: "/project"}) ==
               "/project/./test.txt"
    end

    test "handles parent directory references" do
      assert Tool.resolve_path("../other/file.ex", %{working_directory: "/project/lib"}) ==
               "/project/lib/../other/file.ex"
    end
  end
end
