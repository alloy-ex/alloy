defmodule Alloy.SessionTest do
  use ExUnit.Case, async: true

  alias Alloy.{Message, Usage}
  alias Alloy.Session

  describe "new/0" do
    test "creates a session with a generated ID" do
      session = Session.new()

      assert is_binary(session.id)
      assert String.length(session.id) > 0
    end

    test "generates unique IDs on consecutive calls" do
      s1 = Session.new()
      s2 = Session.new()

      assert s1.id != s2.id
    end

    test "sets timestamps to now" do
      before = DateTime.utc_now()
      session = Session.new()
      after_time = DateTime.utc_now()

      assert DateTime.compare(session.created_at, before) in [:gt, :eq]
      assert DateTime.compare(session.created_at, after_time) in [:lt, :eq]
      assert session.created_at == session.updated_at
    end

    test "initializes with empty messages, usage, and metadata" do
      session = Session.new()

      assert session.messages == []
      assert session.usage == %Usage{}
      assert session.metadata == %{}
    end
  end

  describe "new/1 with options" do
    test "accepts a custom ID" do
      session = Session.new(id: "custom-123")
      assert session.id == "custom-123"
    end

    test "accepts initial messages" do
      msgs = [Message.user("hello")]
      session = Session.new(messages: msgs)
      assert session.messages == msgs
    end

    test "accepts metadata" do
      session = Session.new(metadata: %{model: "gpt-5.2"})
      assert session.metadata == %{model: "gpt-5.2"}
    end
  end

  describe "update_from_result/2" do
    test "replaces messages and usage from result" do
      session = Session.new(id: "test-session")
      new_msgs = [Message.user("hi"), Message.assistant("hello")]
      new_usage = %Usage{input_tokens: 10, output_tokens: 5}

      result = %{messages: new_msgs, usage: new_usage}
      updated = Session.update_from_result(session, result)

      assert updated.messages == new_msgs
      assert updated.usage == new_usage
    end

    test "preserves the original ID and created_at" do
      session = Session.new(id: "keep-me")
      original_created = session.created_at

      result = %{messages: [], usage: %Usage{}}
      updated = Session.update_from_result(session, result)

      assert updated.id == "keep-me"
      assert updated.created_at == original_created
    end

    test "updates the updated_at timestamp" do
      session = Session.new()
      # small sleep to ensure time difference
      Process.sleep(10)

      result = %{messages: [], usage: %Usage{}}
      updated = Session.update_from_result(session, result)

      assert DateTime.compare(updated.updated_at, session.updated_at) in [:gt, :eq]
    end

    test "preserves metadata" do
      session = Session.new(metadata: %{agent: "researcher"})

      result = %{messages: [Message.user("test")], usage: %Usage{input_tokens: 5}}
      updated = Session.update_from_result(session, result)

      assert updated.metadata == %{agent: "researcher"}
    end
  end
end
