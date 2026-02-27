defmodule Alloy.PubSubTest do
  use ExUnit.Case, async: true

  alias Alloy.PubSub
  alias Alloy.Agent.Server
  alias Alloy.Provider.Test, as: TestProvider

  # Start a test PubSub instance for each test
  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    {:ok, pubsub: pubsub_name}
  end

  describe "PubSub.subscribe and PubSub.broadcast" do
    test "subscribe and broadcast work", %{pubsub: pubsub} do
      :ok = PubSub.subscribe("test:topic", pubsub: pubsub)
      :ok = PubSub.broadcast("test:topic", {:hello, "world"}, pubsub: pubsub)
      assert_receive {:hello, "world"}, 1000
    end

    test "subscribers only receive their topic", %{pubsub: pubsub} do
      :ok = PubSub.subscribe("topic:a", pubsub: pubsub)
      :ok = PubSub.broadcast("topic:b", :message_for_b, pubsub: pubsub)
      refute_receive :message_for_b, 100
    end
  end

  describe "agent with PubSub" do
    test "agent subscribes to topics and processes messages", %{pubsub: pubsub} do
      {:ok, provider_pid} =
        TestProvider.start_link([TestProvider.text_response("PubSub response")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          pubsub: pubsub,
          subscribe: ["tasks:new"]
        )

      # Get the stable agent_id from state for the response topic
      agent_id = :sys.get_state(agent).agent_id
      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}:responses")

      # Broadcast a message to the agent's topic
      Phoenix.PubSub.broadcast(pubsub, "tasks:new", {:agent_event, "Hello from PubSub"})

      # Wait for the agent to process and broadcast back
      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed

      Server.stop(agent)
    end

    test "agent with session_id uses it as stable topic prefix", %{pubsub: pubsub} do
      {:ok, provider_pid} =
        TestProvider.start_link([TestProvider.text_response("Stable topic")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          pubsub: pubsub,
          subscribe: ["tasks:stable"],
          context: %{session_id: "my-stable-agent-123"}
        )

      # The topic is predictable from the session_id
      Phoenix.PubSub.subscribe(pubsub, "agent:my-stable-agent-123:responses")

      Phoenix.PubSub.broadcast(pubsub, "tasks:stable", {:agent_event, "Hello stable"})

      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed
      assert result.text == "Stable topic"

      Server.stop(agent)
    end

    test "agent without session_id generates a stable auto-id for topic", %{pubsub: pubsub} do
      {:ok, provider_pid} =
        TestProvider.start_link([TestProvider.text_response("Auto ID")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          pubsub: pubsub,
          subscribe: ["tasks:auto"]
        )

      # Get the auto-generated agent_id
      agent_id = :sys.get_state(agent).agent_id
      assert is_binary(agent_id)
      assert byte_size(agent_id) > 0
      # Should NOT look like a PID string
      refute String.starts_with?(agent_id, "#PID")

      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}:responses")
      Phoenix.PubSub.broadcast(pubsub, "tasks:auto", {:agent_event, "Hello auto"})

      assert_receive {:agent_response, result}, 2000
      assert result.text == "Auto ID"

      Server.stop(agent)
    end

    test "agent without PubSub config works unchanged", %{pubsub: _pubsub} do
      {:ok, provider_pid} =
        TestProvider.start_link([TestProvider.text_response("Normal response")])

      {:ok, agent} =
        Server.start_link(provider: {TestProvider, agent_pid: provider_pid})

      # Should work normally without PubSub
      assert {:ok, result} = Server.chat(agent, "Hello")
      assert result.text == "Normal response"

      Server.stop(agent)
    end

    test "agent broadcasts error and continues running when provider fails", %{pubsub: pubsub} do
      {:ok, provider_pid} =
        TestProvider.start_link([
          TestProvider.error_response("simulated failure"),
          TestProvider.text_response("recovered")
        ])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          pubsub: pubsub,
          subscribe: ["tasks:errors"]
        )

      # Subscribe to this agent's response topic
      agent_id = :sys.get_state(agent).agent_id
      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}:responses")

      # Send a message that will trigger the error path
      Phoenix.PubSub.broadcast(pubsub, "tasks:errors", {:agent_event, "This will fail"})

      # The agent should broadcast an error response (not crash)
      assert_receive {:agent_response, result}, 2000
      assert result.status == :error
      assert result.error == "simulated failure"

      # Verify the agent is still alive and can process a subsequent message
      Phoenix.PubSub.broadcast(pubsub, "tasks:errors", {:agent_event, "This should work"})

      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed
      assert result.text == "recovered"

      # Final confirmation: process is still alive
      assert Process.alive?(agent)

      Server.stop(agent)
    end

    test "agent broadcasts result to response topic after processing event", %{pubsub: pubsub} do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Done")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider_pid},
          pubsub: pubsub,
          subscribe: ["tasks:run"]
        )

      # Subscribe to this agent's stable response topic
      agent_id = :sys.get_state(agent).agent_id
      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}:responses")

      # Send via PubSub
      Phoenix.PubSub.broadcast(pubsub, "tasks:run", {:agent_event, "Do the task"})

      # Receive the broadcast result
      assert_receive {:agent_response, result}, 2000
      assert result.text == "Done"

      Server.stop(agent)
    end
  end
end
