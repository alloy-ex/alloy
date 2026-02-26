defmodule Alloy.TestingTest do
  use ExUnit.Case, async: true

  use Alloy.Testing

  describe "run_with_responses/2" do
    test "runs agent with scripted text response" do
      result =
        run_with_responses("Hello", [
          text_response("Hi there!")
        ])

      assert result.status == :completed
      assert last_text(result) == "Hi there!"
    end

    test "runs agent with tool use then text response" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{message: "test"}),
          text_response("Done!")
        ])

      assert result.status == :completed
      assert last_text(result) == "Done!"
    end

    test "accepts opts for custom configuration" do
      result =
        run_with_responses("Hi", [text_response("ok")],
          max_turns: 1,
          system_prompt: "Be brief."
        )

      assert result.status == :completed
    end
  end

  describe "assert_tool_called/2" do
    test "passes when the tool was called" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{message: "hello"}),
          text_response("Done")
        ])

      assert_tool_called(result, "echo")
    end

    test "raises when the tool was not called" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        assert_tool_called(result, "nonexistent")
      end
    end
  end

  describe "assert_tool_called/3 with input match" do
    test "passes when tool was called with matching input" do
      result =
        run_with_responses("Echo hello", [
          tool_response("echo", %{message: "hello"}),
          text_response("Done")
        ])

      assert_tool_called(result, "echo", %{"message" => "hello"})
    end

    test "raises when input doesn't match" do
      result =
        run_with_responses("Echo hello", [
          tool_response("echo", %{message: "hello"}),
          text_response("Done")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        assert_tool_called(result, "echo", %{"message" => "wrong"})
      end
    end
  end

  describe "refute_tool_called/2" do
    test "passes when the tool was not called" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      refute_tool_called(result, "bash")
    end

    test "raises when the tool was called" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{message: "test"}),
          text_response("Done")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        refute_tool_called(result, "echo")
      end
    end
  end

  describe "last_text/1" do
    test "extracts text from last assistant message" do
      result =
        run_with_responses("Hi", [
          text_response("Final answer")
        ])

      assert last_text(result) == "Final answer"
    end

    test "returns nil when no assistant messages" do
      assert last_text(%{messages: []}) == nil
    end
  end

  describe "tool_calls/1" do
    test "extracts all tool calls from conversation" do
      result =
        run_with_responses("Do both", [
          tool_response("echo", %{message: "first"}),
          tool_response("echo", %{message: "second"}),
          text_response("Done")
        ])

      calls = tool_calls(result)
      assert length(calls) >= 2
      assert Enum.all?(calls, &(&1.name == "echo"))
    end

    test "returns empty list when no tool calls" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      assert tool_calls(result) == []
    end
  end
end
