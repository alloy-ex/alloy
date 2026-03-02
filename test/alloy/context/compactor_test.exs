defmodule Alloy.Context.CompactorTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Context.Compactor
  alias Alloy.Message

  defp build_state(messages, max_tokens \\ 200_000) do
    config = %Config{
      provider: Alloy.Provider.Test,
      provider_config: %{},
      max_tokens: max_tokens
    }

    %State{config: config, messages: messages}
  end

  describe "maybe_compact/1" do
    test "returns state unchanged when within budget" do
      messages = [Message.user("hello"), Message.assistant("hi")]
      state = build_state(messages)

      assert Compactor.maybe_compact(state) == state
    end

    test "compacts messages when over budget" do
      # Build messages that exceed 90% of a small token budget
      # 1200 chars / 4 = 300 tokens, budget 90% of 250 = 225
      big_result = String.duplicate("x", 1200)

      messages = [
        Message.user("original request"),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: big_result}
        ]),
        Message.assistant("analysis of results"),
        Message.user("follow up")
      ]

      state = build_state(messages, 250)
      compacted = Compactor.maybe_compact(state)

      # Should have compacted the tool results
      refute compacted == state
      assert length(compacted.messages) == length(messages)
    end
  end

  describe "on_compaction callback" do
    test "fires callback with middle messages before compaction" do
      test_pid = self()

      callback = fn middle_messages, state ->
        send(test_pid, {:compaction_fired, middle_messages, state})
        :ok
      end

      # Build messages that exceed 90% of a small token budget
      big_text = String.duplicate("x", 1200)

      messages = [
        Message.user("original request"),
        Message.assistant(big_text),
        Message.user("middle question"),
        Message.assistant("middle answer"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      config = %Config{
        provider: Alloy.Provider.Test,
        provider_config: %{},
        max_tokens: 250,
        on_compaction: callback
      }

      state = %State{config: config, messages: messages, messages_new: []}

      _compacted = Compactor.maybe_compact(state)

      assert_received {:compaction_fired, middle_messages, received_state}
      assert middle_messages != []
      assert %State{} = received_state
    end

    test "does not fire callback when within budget" do
      test_pid = self()

      callback = fn _middle, _state ->
        send(test_pid, :should_not_fire)
        :ok
      end

      messages = [Message.user("hi"), Message.assistant("hello")]

      config = %Config{
        provider: Alloy.Provider.Test,
        provider_config: %{},
        max_tokens: 200_000,
        on_compaction: callback
      }

      state = %State{config: config, messages: messages, messages_new: []}

      _result = Compactor.maybe_compact(state)

      refute_received :should_not_fire
    end

    test "compaction still works when on_compaction is nil" do
      big_text = String.duplicate("x", 1200)

      messages = [
        Message.user("original"),
        Message.assistant(big_text),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state = build_state(messages, 250)

      compacted = Compactor.maybe_compact(state)
      assert %State{} = compacted
      refute compacted == state
    end

    test "compaction proceeds even when on_compaction crashes" do
      callback = fn _middle, _state ->
        raise "Boom! Callback crashed!"
      end

      big_text = String.duplicate("x", 1200)

      messages = [
        Message.user("original"),
        Message.assistant(big_text),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      config = %Config{
        provider: Alloy.Provider.Test,
        provider_config: %{},
        max_tokens: 250,
        on_compaction: callback
      }

      state = %State{config: config, messages: messages, messages_new: []}

      # Should NOT raise — crash is swallowed
      compacted = Compactor.maybe_compact(state)
      assert %State{} = compacted
    end
  end

  describe "Config parses on_compaction" do
    test "from_opts accepts on_compaction function" do
      callback = fn _msgs, _state -> :ok end

      config =
        Config.from_opts(
          provider: Alloy.Provider.Test,
          on_compaction: callback
        )

      assert config.on_compaction == callback
    end

    test "from_opts defaults on_compaction to nil" do
      config = Config.from_opts(provider: Alloy.Provider.Test)

      assert config.on_compaction == nil
    end
  end

  describe "compact_messages/2" do
    test "preserves first message" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 1000)),
        Message.user("middle message"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      assert hd(compacted).content == "original request"
    end

    test "preserves recent messages intact" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 1000)),
        Message.user("middle"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      last_two = Enum.take(compacted, -2)
      assert Enum.at(last_two, 0).content == "recent reply"
      assert Enum.at(last_two, 1).content == "latest"
    end

    test "compacts tool_result blocks to [compacted]" do
      tool_content = String.duplicate("r", 500)

      messages = [
        Message.user("original"),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: tool_content}
        ]),
        Message.assistant("ok"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      # The tool_result message (index 1) should be compacted
      compacted_msg = Enum.at(compacted, 1)
      [block] = compacted_msg.content
      assert block.content == "[compacted]"
    end

    test "truncates old assistant text messages" do
      long_text = String.duplicate("a", 500)

      messages = [
        Message.user("original"),
        Message.assistant(long_text),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      # The old assistant message should be truncated to 200 chars + "..."
      compacted_msg = Enum.at(compacted, 1)
      assert String.length(compacted_msg.content) <= 203
    end

    test "handles all messages within keep_recent window" do
      messages = [
        Message.user("hello"),
        Message.assistant("hi")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 10)
      assert compacted == messages
    end
  end
end
