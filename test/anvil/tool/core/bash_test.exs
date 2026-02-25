defmodule Anvil.Tool.Core.BashTest do
  use ExUnit.Case, async: true

  alias Anvil.Tool.Core.Bash

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "anvil_bash_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Anvil.Tool" do
      assert Bash.name() == "bash"
      assert is_binary(Bash.description())
      assert is_map(Bash.input_schema())
    end
  end

  describe "execute/2" do
    test "runs a simple command and returns output", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "echo hello"}, %{working_directory: tmp_dir})

      assert result =~ "hello"
      assert result =~ "exit code: 0"
    end

    test "returns non-zero exit code", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "exit 42"}, %{working_directory: tmp_dir})

      assert result =~ "exit code: 42"
    end

    test "captures stderr", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo error_msg >&2"},
                 %{working_directory: tmp_dir}
               )

      assert result =~ "error_msg"
    end

    test "respects working_directory", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "pwd"}, %{working_directory: tmp_dir})

      assert result =~ tmp_dir
    end

    test "truncates output beyond 30000 chars", %{tmp_dir: tmp_dir} do
      # Generate output longer than 30000 chars
      cmd = "python3 -c \"print('x' * 40000)\""

      assert {:ok, result} =
               Bash.execute(%{"command" => cmd}, %{working_directory: tmp_dir})

      assert String.length(result) <= 31000
      assert result =~ "truncated"
    end

    test "enforces timeout", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "sleep 10", "timeout" => 100},
                 %{working_directory: tmp_dir}
               )

      assert msg =~ "timed out" or msg =~ "timeout"
    end

    test "uses default working directory when not in context" do
      assert {:ok, result} = Bash.execute(%{"command" => "echo works"}, %{})
      assert result =~ "works"
    end
  end
end
