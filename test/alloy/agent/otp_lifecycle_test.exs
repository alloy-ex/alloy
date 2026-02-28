defmodule Alloy.Agent.OTPLifecycleTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Agent.Server
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  # ── Fix 1: Scratchpad Process Leak ─────────────────────────────────────────

  describe "State.cleanup/1 stops the scratchpad process" do
    test "scratchpad process is stopped after cleanup" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{},
        tools: [Alloy.Tool.Core.Scratchpad]
      }

      state = State.init(config)

      # Scratchpad should be started
      assert is_pid(state.scratchpad)
      assert Process.alive?(state.scratchpad)

      # Cleanup should stop it
      State.cleanup(state)

      # Give a moment for process to terminate
      Process.sleep(10)
      refute Process.alive?(state.scratchpad)
    end

    test "cleanup is safe when scratchpad is nil (no scratchpad tool)" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{}
      }

      state = State.init(config)
      assert is_nil(state.scratchpad)

      # Should not raise
      assert :ok = State.cleanup(state)
    end
  end

  defmodule ScratchpadCapture do
    @behaviour Alloy.Middleware

    def call(:before_completion, %Alloy.Agent.State{} = state) do
      if state.scratchpad do
        send(Process.get(:test_pid), {:scratchpad_pid, state.scratchpad})
      end

      state
    end

    def call(_hook, state), do: state
  end

  describe "Alloy.run/2 cleans up scratchpad process" do
    test "scratchpad process is dead after Alloy.run completes" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Done")])

      # Start a helper process that will run Alloy.run and capture the scratchpad pid
      test_pid = self()

      spawn_link(fn ->
        Process.put(:test_pid, test_pid)

        {:ok, _result} =
          Alloy.run("Hello",
            provider: {TestProvider, agent_pid: provider_pid},
            tools: [Alloy.Tool.Core.Scratchpad],
            middleware: [ScratchpadCapture]
          )

        send(test_pid, :run_complete)
      end)

      # Wait for the middleware to capture the scratchpad pid
      assert_receive {:scratchpad_pid, scratchpad_pid}, 5000
      assert Process.alive?(scratchpad_pid)

      # Wait for run to complete (cleanup happens in after block)
      assert_receive :run_complete, 5000
      Process.sleep(10)

      refute Process.alive?(scratchpad_pid),
             "Scratchpad process leaked after Alloy.run — pid #{inspect(scratchpad_pid)} still alive"
    end
  end

  describe "Server.stop/1 cleans up scratchpad process" do
    test "scratchpad process is dead after Server stops" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Hi")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          tools: [Alloy.Tool.Core.Scratchpad]
        )

      # Get the scratchpad pid from the agent state
      agent_state = :sys.get_state(agent)
      scratchpad_pid = agent_state.scratchpad

      assert is_pid(scratchpad_pid)
      assert Process.alive?(scratchpad_pid)

      # Stop the agent
      Server.stop(agent)
      Process.sleep(10)

      # Scratchpad must be dead
      refute Process.alive?(scratchpad_pid),
             "Scratchpad process leaked after Server.stop — pid #{inspect(scratchpad_pid)} still alive"
    end
  end

  # ── Fix 2: O(N²) Message Append ────────────────────────────────────────────

  describe "append_messages/2 uses O(1) prepend internally" do
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

  # ── Fix 3: :idle Status ────────────────────────────────────────────────────

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
end
