defmodule Alloy.MemoryTest do
  use ExUnit.Case, async: true

  alias Alloy.Memory

  describe "validate_path/1" do
    test "accepts paths under /memories" do
      assert Memory.validate_path("/memories") == {:ok, "/memories"}
      assert Memory.validate_path("/memories/foo.md") == {:ok, "/memories/foo.md"}

      assert Memory.validate_path("/memories/deep/sub/path.txt") ==
               {:ok, "/memories/deep/sub/path.txt"}
    end

    test "strips trailing slashes and collapses double slashes" do
      assert Memory.validate_path("/memories/") == {:ok, "/memories"}
      assert Memory.validate_path("/memories/foo/") == {:ok, "/memories/foo"}
      assert Memory.validate_path("/memories//foo") == {:ok, "/memories/foo"}
    end

    test "rejects paths not rooted at /memories" do
      assert {:error, _} = Memory.validate_path("/etc/passwd")
      assert {:error, _} = Memory.validate_path("memories/foo")
      assert {:error, _} = Memory.validate_path("./memories/foo")
    end

    test "rejects upward traversal" do
      assert {:error, reason} = Memory.validate_path("/memories/../etc/passwd")
      assert reason =~ "upward traversal"

      assert {:error, reason} = Memory.validate_path("/memories/foo/..")
      assert reason =~ "upward traversal"
    end

    test "rejects non-string input" do
      assert {:error, reason} = Memory.validate_path(nil)
      assert reason =~ "must be a string"

      assert {:error, _} = Memory.validate_path(42)
    end
  end
end
