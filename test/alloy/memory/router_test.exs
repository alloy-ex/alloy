defmodule Alloy.Memory.RouterTest do
  use ExUnit.Case, async: true

  alias Alloy.Memory.Router
  alias Alloy.Test.MemoryStore

  setup do
    {:ok, pid} = MemoryStore.start_link()
    {:ok, store: {MemoryStore, pid}}
  end

  describe "memory_call?/1" do
    test "recognises the memory tool by name" do
      assert Router.memory_call?(%{type: "tool_use", name: "memory", id: "a", input: %{}})
      refute Router.memory_call?(%{type: "tool_use", name: "bash", id: "b", input: %{}})
      refute Router.memory_call?(%{type: "text", text: "hi"})
    end

    test "tool_name/0 returns the canonical string" do
      assert Router.tool_name() == "memory"
    end
  end

  describe "dispatch_all/2" do
    test "routes view on empty path to not-found error block", %{store: store} do
      [block] =
        Router.dispatch_all(
          [
            %{
              type: "tool_use",
              id: "call_1",
              name: "memory",
              input: %{"command" => "view", "path" => "/memories/missing.md"}
            }
          ],
          store
        )

      assert block.type == "tool_result"
      assert block.tool_use_id == "call_1"
      assert block.is_error == true
      assert block.content =~ "not found"
    end

    test "create + view round-trip", %{store: store} do
      [create, view] =
        Router.dispatch_all(
          [
            %{
              type: "tool_use",
              id: "c1",
              name: "memory",
              input: %{
                "command" => "create",
                "path" => "/memories/note.md",
                "file_text" => "hello world"
              }
            },
            %{
              type: "tool_use",
              id: "c2",
              name: "memory",
              input: %{"command" => "view", "path" => "/memories/note.md"}
            }
          ],
          store
        )

      assert create.is_error == false
      assert view.is_error == false
      assert view.content == "hello world"
    end

    test "str_replace returns error when old_str missing", %{store: store} do
      MemoryStore.create(elem(store, 1), "/memories/note.md", "hello")

      [result] =
        Router.dispatch_all(
          [
            %{
              type: "tool_use",
              id: "r1",
              name: "memory",
              input: %{
                "command" => "str_replace",
                "path" => "/memories/note.md",
                "old_str" => "goodbye",
                "new_str" => "bonjour"
              }
            }
          ],
          store
        )

      assert result.is_error == true
      assert result.content =~ "not found"
    end

    test "invalid path is rejected before reaching the store", %{store: store} do
      [result] =
        Router.dispatch_all(
          [
            %{
              type: "tool_use",
              id: "t1",
              name: "memory",
              input: %{"command" => "view", "path" => "/etc/passwd"}
            }
          ],
          store
        )

      assert result.is_error == true
      assert result.content =~ "must start with /memories"
    end

    test "malformed input produces an error block", %{store: store} do
      [result] =
        Router.dispatch_all(
          [
            %{
              type: "tool_use",
              id: "m1",
              name: "memory",
              input: %{"command" => "nope"}
            }
          ],
          store
        )

      assert result.is_error == true
      assert result.content =~ "invalid memory tool input"
    end

    test "preserves call order across dispatch", %{store: store} do
      calls =
        for i <- 1..5 do
          %{
            type: "tool_use",
            id: "call_#{i}",
            name: "memory",
            input: %{
              "command" => "create",
              "path" => "/memories/f#{i}.md",
              "file_text" => "body #{i}"
            }
          }
        end

      results = Router.dispatch_all(calls, store)
      assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, & &1.id)
    end
  end
end
