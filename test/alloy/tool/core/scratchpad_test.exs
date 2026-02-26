defmodule Alloy.Tool.Core.ScratchpadTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Scratchpad

  @moduletag :core_tools

  setup do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    {:ok, scratchpad: pid}
  end

  describe "behaviour" do
    test "implements Alloy.Tool", %{scratchpad: pid} do
      assert Scratchpad.name() == "scratchpad"
      assert is_binary(Scratchpad.description())
      schema = Scratchpad.input_schema()
      assert schema.type == "object"
      assert Map.has_key?(schema.properties, :action)
      _ = pid
    end
  end

  describe "read" do
    test "returns empty message when nothing stored", %{scratchpad: pid} do
      assert {:ok, msg} = Scratchpad.execute(%{"action" => "read"}, %{scratchpad_pid: pid})
      assert msg =~ "empty"
    end

    test "returns all stored notes after writes", %{scratchpad: pid} do
      Scratchpad.execute(%{"action" => "write", "key" => "target", "value" => "mix.exs"}, %{
        scratchpad_pid: pid
      })

      assert {:ok, msg} = Scratchpad.execute(%{"action" => "read"}, %{scratchpad_pid: pid})
      assert msg =~ "target: mix.exs"
    end
  end

  describe "write" do
    test "saves a key-value pair and confirms", %{scratchpad: pid} do
      assert {:ok, msg} =
               Scratchpad.execute(
                 %{"action" => "write", "key" => "goal", "value" => "fix bug"},
                 %{scratchpad_pid: pid}
               )

      assert msg =~ "goal"
    end

    test "returns error when key is missing", %{scratchpad: pid} do
      assert {:error, msg} =
               Scratchpad.execute(
                 %{"action" => "write", "value" => "fix bug"},
                 %{scratchpad_pid: pid}
               )

      assert msg =~ "key"
    end

    test "returns error when value is missing", %{scratchpad: pid} do
      assert {:error, msg} =
               Scratchpad.execute(
                 %{"action" => "write", "key" => "goal"},
                 %{scratchpad_pid: pid}
               )

      assert msg =~ "value"
    end

    test "overwrites an existing key", %{scratchpad: pid} do
      Scratchpad.execute(
        %{"action" => "write", "key" => "status", "value" => "in progress"},
        %{scratchpad_pid: pid}
      )

      Scratchpad.execute(
        %{"action" => "write", "key" => "status", "value" => "done"},
        %{scratchpad_pid: pid}
      )

      assert {:ok, msg} = Scratchpad.execute(%{"action" => "read"}, %{scratchpad_pid: pid})
      assert msg =~ "done"
      refute msg =~ "in progress"
    end
  end

  describe "clear" do
    test "removes all stored notes", %{scratchpad: pid} do
      Scratchpad.execute(%{"action" => "write", "key" => "k", "value" => "v"}, %{
        scratchpad_pid: pid
      })

      assert {:ok, _} = Scratchpad.execute(%{"action" => "clear"}, %{scratchpad_pid: pid})
      assert {:ok, msg} = Scratchpad.execute(%{"action" => "read"}, %{scratchpad_pid: pid})
      assert msg =~ "empty"
    end
  end

  describe "missing scratchpad_pid" do
    test "returns a helpful error when not configured" do
      assert {:error, msg} = Scratchpad.execute(%{"action" => "read"}, %{})
      assert msg =~ "not available"
    end
  end

  describe "unknown action" do
    test "returns error naming the bad action", %{scratchpad: pid} do
      assert {:error, msg} =
               Scratchpad.execute(%{"action" => "delete"}, %{scratchpad_pid: pid})

      assert msg =~ "delete"
    end
  end
end
