defmodule Alloy.Agent.OTPLifecycleTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Agent.Server
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  # ── State.cleanup/1 ─────────────────────────────────────────────────────────

  describe "State.cleanup/1" do
    test "cleanup is safe with no resources" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{}
      }

      state = State.init(config)
      assert :ok = State.cleanup(state)
    end
  end

  # ── Message Append ─────────────────────────────────────────────────────────

  describe "append_messages/2" do
    test "state.messages holds every appended message, so middleware can read it" do
      config = %Config{provider: TestProvider, provider_config: %{}}

      state =
        config
        |> State.init([Message.user("first")])
        |> State.append_messages([Message.assistant("reply")])
        |> State.append_messages(Message.user("second"))

      assert Enum.map(state.messages, & &1.content) == ["first", "reply", "second"]
      assert state.messages_new == []
    end

    test "folds messages left in the deprecated accumulator" do
      config = %Config{provider: TestProvider, provider_config: %{}}

      legacy = %{
        State.init(config, [Message.user("first")])
        | messages_new: [Message.user("third"), Message.assistant("second")]
      }

      state = State.append_messages(legacy, [Message.assistant("fourth")])

      assert Enum.map(state.messages, & &1.content) == ["first", "second", "third", "fourth"]
      assert State.messages(legacy) == Enum.take(state.messages, 3)
    end
  end

  describe "append_messages/2 keeps chronological order" do
    test "messages are returned in chronological order from state" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{}
      }

      state = State.init(config, [Message.user("first")])

      state = State.append_messages(state, [Message.assistant("reply1")])
      state = State.append_messages(state, [Message.user("second")])
      state = State.append_messages(state, [Message.assistant("reply2")])

      # Messages must come out in chronological order
      messages = State.messages(state)
      assert length(messages) == 4
      assert Enum.at(messages, 0).content == "first"
      assert Enum.at(messages, 1).content == "reply1"
      assert Enum.at(messages, 2).content == "second"
      assert Enum.at(messages, 3).content == "reply2"
    end

    test "last_assistant_text returns correct text regardless of storage order" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{}
      }

      state = State.init(config, [Message.user("hello")])
      state = State.append_messages(state, [Message.assistant("first reply")])
      state = State.append_messages(state, [Message.user("followup")])
      state = State.append_messages(state, [Message.assistant("last reply")])

      assert State.last_assistant_text(state) == "last reply"
    end
  end

  # ── :idle Status ────────────────────────────────────────────────────────────

  describe "agent status is :idle between runs, :running during" do
    test "Server starts with :idle status" do
      {:ok, provider_pid} = TestProvider.start_link([])

      {:ok, agent} =
        Server.start_link(provider: {TestProvider, agent_pid: provider_pid})

      health = Server.health(agent)
      assert health.status == :idle
    end

    test "after chat completes, status is :idle (not :running)" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Done")])

      {:ok, agent} =
        Server.start_link(provider: {TestProvider, agent_pid: provider_pid})

      {:ok, _result} = Server.chat(agent, "Hello")

      health = Server.health(agent)

      assert health.status == :idle,
             "Expected :idle after chat completes, got #{inspect(health.status)}"
    end

    test "after reset, status is :idle" do
      {:ok, provider_pid} =
        TestProvider.start_link([
          TestProvider.text_response("Done")
        ])

      {:ok, agent} =
        Server.start_link(provider: {TestProvider, agent_pid: provider_pid})

      {:ok, _} = Server.chat(agent, "Hello")
      :ok = Server.reset(agent)

      health = Server.health(agent)
      assert health.status == :idle
    end

    test "exported session shows :idle after chat" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Done")])

      {:ok, agent} =
        Server.start_link(provider: {TestProvider, agent_pid: provider_pid})

      {:ok, _} = Server.chat(agent, "Hello")

      session = Server.export_session(agent)
      assert session.metadata.status == :idle
    end
  end

  # ── on_shutdown catch stacktrace ──────────────────────────────────────────

  describe "on_shutdown catch block logs stacktrace" do
    test "logs stacktrace when on_shutdown throws" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Done")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          on_shutdown: fn _session -> throw(:kaboom) end
        )

      {:ok, _} = Server.chat(agent, "Hello")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Server.stop(agent)
          Process.sleep(50)
        end)

      assert log =~ "on_shutdown callback threw"
      assert log =~ "Stacktrace"
    end
  end
end
