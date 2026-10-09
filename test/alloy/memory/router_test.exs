defmodule Alloy.Memory.RouterTest do
  use ExUnit.Case, async: true

  alias Alloy.Memory.Router
  alias Alloy.Test.MemoryStore

  setup do
    {:ok, pid} = MemoryStore.start_link()
    {:ok, store: {MemoryStore, pid}, pid: pid}
  end

  describe "dispatch/2" do
    test "viewing a missing path is an error", %{store: store} do
      assert {:error, message} =
               Router.dispatch(store, %{"command" => "view", "path" => "/memories/missing.md"})

      assert message =~ "not found"
    end

    test "create + view round-trip", %{store: store} do
      create = %{
        "command" => "create",
        "path" => "/memories/note.md",
        "file_text" => "hello world"
      }

      assert {:ok, _} = Router.dispatch(store, create)

      assert {:ok, "hello world"} =
               Router.dispatch(store, %{"command" => "view", "path" => "/memories/note.md"})
    end

    test "str_replace returns an error when old_str is missing", %{store: store, pid: pid} do
      MemoryStore.create(pid, "/memories/note.md", "hello")

      assert {:error, message} =
               Router.dispatch(store, %{
                 "command" => "str_replace",
                 "path" => "/memories/note.md",
                 "old_str" => "goodbye",
                 "new_str" => "bonjour"
               })

      assert message =~ "not found"
    end

    test "an invalid path is rejected before reaching the store", %{store: store} do
      assert {:error, message} =
               Router.dispatch(store, %{"command" => "view", "path" => "/etc/passwd"})

      assert message =~ "must start with /memories"
    end

    test "malformed input is an error", %{store: store} do
      assert {:error, message} = Router.dispatch(store, %{"command" => "nope"})
      assert message =~ "invalid memory tool input"
    end

    test "refuses to delete or rename the /memories root", %{store: store, pid: pid} do
      MemoryStore.create(pid, "/memories/keep.md", "keep")

      for input <- [
            %{"command" => "delete", "path" => "/memories"},
            %{"command" => "delete", "path" => "/memories/"},
            %{"command" => "rename", "old_path" => "/memories", "new_path" => "/memories/x"},
            %{"command" => "rename", "old_path" => "/memories/keep.md", "new_path" => "/memories"}
          ] do
        assert {:error, message} = Router.dispatch(store, input)
        assert message =~ "/memories directory itself"
      end

      assert MemoryStore.contents(pid) == %{"/memories/keep.md" => "keep"}
    end

    test "str_replace without new_str deletes old_str", %{store: store, pid: pid} do
      MemoryStore.create(pid, "/memories/note.md", "keep this, drop this")

      assert {:ok, _} =
               Router.dispatch(store, %{
                 "command" => "str_replace",
                 "path" => "/memories/note.md",
                 "old_str" => ", drop this"
               })

      assert MemoryStore.contents(pid)["/memories/note.md"] == "keep this"
    end

    test "view honours view_range", %{store: store, pid: pid} do
      MemoryStore.create(pid, "/memories/lines.md", "one\ntwo\nthree\nfour\n")

      view = fn range ->
        Router.dispatch(store, %{
          "command" => "view",
          "path" => "/memories/lines.md",
          "view_range" => range
        })
      end

      assert view.([2, 3]) == {:ok, "two\nthree"}
      assert view.([3, -1]) == {:ok, "three\nfour"}
      assert {:error, past_end} = view.([9, -1])
      assert past_end =~ "4 lines"
      assert {:error, bad} = view.([0, 2])
      assert bad =~ "view_range"
    end
  end
end
