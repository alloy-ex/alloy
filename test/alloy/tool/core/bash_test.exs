defmodule Alloy.Tool.Core.BashTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Bash

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "alloy_bash_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Alloy.Tool" do
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

      assert String.length(result) <= 31_000
      assert result =~ "truncated"
    end

    test "enforces timeout with a descriptive message", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "sleep 10", "timeout" => 100},
                 %{working_directory: tmp_dir}
               )

      assert msg =~ "timed out"
      assert msg =~ ~r/server|loop|input/i
    end

    test "executes in bash not sh", %{tmp_dir: tmp_dir} do
      # $0 reports the name of the invoking shell: "bash" when called as bash, "sh" when called as sh
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo $0"},
                 %{working_directory: tmp_dir}
               )

      assert result =~ "bash"
    end

    test "uses default working directory when not in context" do
      assert {:ok, result} = Bash.execute(%{"command" => "echo works"}, %{})
      assert result =~ "works"
    end
  end

  describe "custom bash_executor" do
    test "uses custom executor function when provided in context" do
      executor = fn _command, _working_dir -> {"custom output", 0} end

      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo hello"},
                 %{bash_executor: executor}
               )

      assert result =~ "custom output"
      assert result =~ "exit code: 0"
    end

    test "custom executor receives command and working_dir arguments", %{tmp_dir: tmp_dir} do
      test_pid = self()

      executor = fn command, working_dir ->
        send(test_pid, {:called_with, command, working_dir})
        {"ok", 0}
      end

      Bash.execute(
        %{"command" => "echo test"},
        %{bash_executor: executor, working_directory: tmp_dir}
      )

      assert_receive {:called_with, "echo test", ^tmp_dir}
    end

    test "custom executor timeout returns error when executor exceeds timeout" do
      executor = fn _command, _working_dir ->
        Process.sleep(5_000)
        {"never returned", 0}
      end

      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "anything", "timeout" => 100},
                 %{bash_executor: executor}
               )

      assert msg =~ "timed out"
    end

    test "custom executor output is truncated when over 30000 chars" do
      big_output = String.duplicate("x", 40_000)
      executor = fn _command, _working_dir -> {big_output, 0} end

      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "anything"},
                 %{bash_executor: executor}
               )

      assert String.length(result) <= 31_000
      assert result =~ "truncated"
    end
  end
end
