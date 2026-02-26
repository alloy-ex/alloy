defmodule Alloy.Context.TokenCounterTest do
  use ExUnit.Case, async: true

  alias Alloy.Context.TokenCounter
  alias Alloy.Message

  describe "estimate_tokens/1 with text" do
    test "estimates short text" do
      # "hello" = 5 chars => 5 / 4 = 1 token
      assert TokenCounter.estimate_tokens("hello") == 1
    end

    test "estimates longer text" do
      text = String.duplicate("a", 100)
      assert TokenCounter.estimate_tokens(text) == 25
    end

    test "returns 0 for empty string" do
      assert TokenCounter.estimate_tokens("") == 0
    end
  end

  describe "estimate_tokens/1 with message list" do
    test "sums tokens across messages" do
      messages = [
        Message.user(String.duplicate("a", 40)),
        Message.assistant(String.duplicate("b", 80))
      ]

      # 40/4 + 80/4 = 10 + 20 = 30
      assert TokenCounter.estimate_tokens(messages) == 30
    end

    test "handles empty list" do
      assert TokenCounter.estimate_tokens([]) == 0
    end
  end

  describe "estimate_message_tokens/1" do
    test "estimates string content" do
      msg = Message.user(String.duplicate("x", 200))
      assert TokenCounter.estimate_message_tokens(msg) == 50
    end

    test "estimates block content with text blocks" do
      msg = %Message{
        role: :assistant,
        content: [
          %{type: "text", text: String.duplicate("a", 40)},
          %{type: "tool_use", id: "t1", name: "read", input: %{path: "/foo"}}
        ]
      }

      # text block: 40/4 = 10
      # tool_use: name "read" (4) + input json ~14 chars => ~4 tokens
      # But we only count text fields in blocks, so tool_use name + serialized input
      result = TokenCounter.estimate_message_tokens(msg)
      assert result > 0
    end

    test "estimates tool_result blocks" do
      msg = %Message{
        role: :user,
        content: [
          %{type: "tool_result", tool_use_id: "t1", content: String.duplicate("r", 80)}
        ]
      }

      # content field: 80/4 = 20
      result = TokenCounter.estimate_message_tokens(msg)
      assert result >= 20
    end
  end

  describe "model_limit/1" do
    test "returns known model limits" do
      assert TokenCounter.model_limit("claude-sonnet-4-6") == 200_000
      assert TokenCounter.model_limit("gpt-5.2") == 1_047_576
      assert TokenCounter.model_limit("gemini-2.5-flash") == 1_000_000
    end

    test "returns default for unknown model" do
      assert TokenCounter.model_limit("unknown-model") == 200_000
    end
  end

  describe "within_budget?/2" do
    test "returns true when well within budget" do
      messages = [Message.user("hello")]
      assert TokenCounter.within_budget?(messages, 1000)
    end

    test "returns false when over 90% threshold" do
      # Create messages that exceed 90% of budget
      big_text = String.duplicate("a", 3700)
      messages = [Message.user(big_text)]
      # 3700/4 = 925 tokens, 90% of 1000 = 900
      refute TokenCounter.within_budget?(messages, 1000)
    end
  end
end
