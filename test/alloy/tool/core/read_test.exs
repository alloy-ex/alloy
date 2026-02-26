defmodule Alloy.Tool.Core.ReadTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Read

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "alloy_read_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Alloy.Tool" do
      assert Read.name() == "read"
      assert is_binary(Read.description())
      assert is_map(Read.input_schema())
    end
  end

  describe "execute/2" do
    test "reads existing file with line numbers", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "hello.txt")
      File.write!(file, "line one\nline two\nline three\n")

      assert {:ok, result} = Read.execute(%{"file_path" => file}, %{})
      assert result =~ "1\tline one"
      assert result =~ "2\tline two"
      assert result =~ "3\tline three"
    end

    test "line numbers are right-aligned with padding", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "padded.txt")
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(file, lines)

      assert {:ok, result} = Read.execute(%{"file_path" => file}, %{})
      # Single digit lines get more padding than double digit
      assert result =~ "     1\tline 1"
      assert result =~ "    10\tline 10"
    end

    test "respects offset parameter", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "offset.txt")
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(file, lines)

      assert {:ok, result} = Read.execute(%{"file_path" => file, "offset" => 5}, %{})
      refute result =~ "line 1\n"
      refute result =~ "line 4\n"
      assert result =~ "5\tline 5"
      assert result =~ "10\tline 10"
    end

    test "respects limit parameter", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "limit.txt")
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(file, lines)

      assert {:ok, result} = Read.execute(%{"file_path" => file, "limit" => 3}, %{})
      assert result =~ "1\tline 1"
      assert result =~ "3\tline 3"
      refute result =~ "4\tline 4"
    end

    test "respects offset and limit together", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "both.txt")
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(file, lines)

      assert {:ok, result} =
               Read.execute(%{"file_path" => file, "offset" => 3, "limit" => 2}, %{})

      refute result =~ "2\tline 2"
      assert result =~ "3\tline 3"
      assert result =~ "4\tline 4"
      refute result =~ "5\tline 5"
    end

    test "returns error for missing file" do
      assert {:error, msg} = Read.execute(%{"file_path" => "/nonexistent/file.txt"}, %{})
      assert msg =~ "not found" or msg =~ "no such file" or msg =~ "does not exist"
    end

    test "respects working_directory from context", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "wd.txt")
      File.write!(file, "hello from wd\n")

      assert {:ok, result} =
               Read.execute(%{"file_path" => "wd.txt"}, %{working_directory: tmp_dir})

      assert result =~ "hello from wd"
    end

    test "absolute path ignores working_directory", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "abs.txt")
      File.write!(file, "absolute\n")

      assert {:ok, result} =
               Read.execute(%{"file_path" => file}, %{working_directory: "/some/other/dir"})

      assert result =~ "absolute"
    end
  end
end
