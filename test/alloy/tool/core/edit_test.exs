defmodule Alloy.Tool.Core.EditTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Edit

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "alloy_edit_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Alloy.Tool" do
      assert Edit.name() == "edit"
      assert is_binary(Edit.description())
      assert is_map(Edit.input_schema())
    end
  end

  describe "execute/2" do
    test "replaces a unique string", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "edit.txt")
      File.write!(file, "Hello World\nGoodbye World\n")

      assert {:ok, _msg} =
               Edit.execute(
                 %{
                   "file_path" => file,
                   "old_string" => "Hello World",
                   "new_string" => "Hi World"
                 },
                 %{}
               )

      assert File.read!(file) == "Hi World\nGoodbye World\n"
    end

    test "fails when old_string appears more than once (ambiguous)", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "ambiguous.txt")
      File.write!(file, "foo bar\nfoo baz\n")

      assert {:error, msg} =
               Edit.execute(
                 %{"file_path" => file, "old_string" => "foo", "new_string" => "qux"},
                 %{}
               )

      assert msg =~ "ambiguous" or msg =~ "multiple" or msg =~ "more than once"
    end

    test "replace_all replaces all occurrences", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "replace_all.txt")
      File.write!(file, "foo bar\nfoo baz\n")

      assert {:ok, _msg} =
               Edit.execute(
                 %{
                   "file_path" => file,
                   "old_string" => "foo",
                   "new_string" => "qux",
                   "replace_all" => true
                 },
                 %{}
               )

      assert File.read!(file) == "qux bar\nqux baz\n"
    end

    test "fails when old_string not found", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "notfound.txt")
      File.write!(file, "hello world\n")

      assert {:error, msg} =
               Edit.execute(
                 %{"file_path" => file, "old_string" => "xyz", "new_string" => "abc"},
                 %{}
               )

      assert msg =~ "not found" or msg =~ "No match"
    end

    test "fails when file does not exist" do
      assert {:error, _msg} =
               Edit.execute(
                 %{
                   "file_path" => "/nonexistent/file.txt",
                   "old_string" => "a",
                   "new_string" => "b"
                 },
                 %{}
               )
    end

    test "respects working_directory from context", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "wd_edit.txt")
      File.write!(file, "old value\n")

      assert {:ok, _msg} =
               Edit.execute(
                 %{
                   "file_path" => "wd_edit.txt",
                   "old_string" => "old value",
                   "new_string" => "new value"
                 },
                 %{working_directory: tmp_dir}
               )

      assert File.read!(file) == "new value\n"
    end
  end
end
