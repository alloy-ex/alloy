defmodule Alloy.Tool.Core.WriteTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Write

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "alloy_write_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Alloy.Tool" do
      assert Write.name() == "write"
      assert is_binary(Write.description())
      assert is_map(Write.input_schema())
    end
  end

  describe "execute/2" do
    test "writes content to a new file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "new.txt")

      assert {:ok, msg} = Write.execute(%{"file_path" => file, "content" => "hello"}, %{})
      assert msg =~ file
      assert File.read!(file) == "hello"
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "a/b/c/deep.txt")

      assert {:ok, _msg} = Write.execute(%{"file_path" => file, "content" => "deep"}, %{})
      assert File.read!(file) == "deep"
    end

    test "overwrites existing file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "existing.txt")
      File.write!(file, "old content")

      assert {:ok, _msg} = Write.execute(%{"file_path" => file, "content" => "new content"}, %{})
      assert File.read!(file) == "new content"
    end

    test "respects working_directory from context", %{tmp_dir: tmp_dir} do
      assert {:ok, _msg} =
               Write.execute(
                 %{"file_path" => "wd_file.txt", "content" => "wd content"},
                 %{working_directory: tmp_dir}
               )

      assert File.read!(Path.join(tmp_dir, "wd_file.txt")) == "wd content"
    end

    test "absolute path ignores working_directory", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "abs.txt")

      assert {:ok, _msg} =
               Write.execute(
                 %{"file_path" => file, "content" => "abs"},
                 %{working_directory: "/some/other"}
               )

      assert File.read!(file) == "abs"
    end
  end
end
