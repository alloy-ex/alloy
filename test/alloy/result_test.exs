defmodule Alloy.ResultTest do
  use ExUnit.Case, async: true

  alias Alloy.Result

  describe "struct defaults" do
    test "creates with sensible defaults" do
      result = %Result{}

      assert result.text == nil
      assert result.messages == []
      assert result.usage == %Alloy.Usage{}
      assert result.tool_calls == []
      assert result.status == :completed
      assert result.turns == 0
      assert result.error == nil
      assert result.request_id == nil
    end

    test "accepts all fields" do
      result = %Result{
        text: "hello",
        messages: [:msg],
        usage: %Alloy.Usage{input_tokens: 42},
        tool_calls: [%{name: "read"}],
        status: :error,
        turns: 3,
        error: :timeout,
        request_id: "req-abc"
      }

      assert result.text == "hello"
      assert result.messages == [:msg]
      assert result.usage.input_tokens == 42
      assert result.tool_calls == [%{name: "read"}]
      assert result.status == :error
      assert result.turns == 3
      assert result.error == :timeout
      assert result.request_id == "req-abc"
    end
  end

  describe "Access behaviour" do
    test "bracket syntax reads fields" do
      result = %Result{text: "hi", turns: 5}

      assert result[:text] == "hi"
      assert result[:turns] == 5
      assert result[:error] == nil
    end

    test "get_in/2 works" do
      result = %Result{text: "deep"}
      assert get_in(result, [:text]) == "deep"
    end

    test "pop/2 returns value and updated struct" do
      result = %Result{text: "gone", turns: 2}
      {value, updated} = Access.pop(result, :text)

      assert value == "gone"
      assert updated.text == nil
      assert updated.turns == 2
    end

    test "get_and_update/3 works" do
      result = %Result{turns: 10}

      {old, updated} =
        Access.get_and_update(result, :turns, fn current ->
          {current, current + 1}
        end)

      assert old == 10
      assert updated.turns == 11
    end
  end

  describe "backwards compatibility" do
    test "pattern matches as a map" do
      result = %Result{text: "match me", status: :completed}
      assert %{text: "match me", status: :completed} = result
    end

    test "Map.get/2 works" do
      result = %Result{text: "map-get"}
      assert Map.get(result, :text) == "map-get"
    end

    test "Map.put/3 works" do
      result = %Result{text: "before"}
      updated = Map.put(result, :text, "after")
      assert updated.text == "after"
    end

    test "Map.merge/2 works for adding extra fields" do
      result = %Result{text: "base"}
      merged = Map.merge(result, %{request_id: "req-123"})
      assert merged.request_id == "req-123"
      assert merged.text == "base"
    end
  end
end
