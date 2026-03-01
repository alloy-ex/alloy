defmodule Alloy.Agent.ServerSendMessageTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Server
  alias Alloy.Provider.Test, as: TestProvider

  defp start_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp opts(provider_pid, overrides \\ []) do
    Keyword.merge(
      [provider: {Alloy.Provider.Test, agent_pid: provider_pid}],
      overrides
    )
  end

  defp start_pubsub(_ctx) do
    name = :"test_pubsub_sm_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: name})
    {:ok, pubsub: name}
  end

  # ── Basic send_message/2 ────────────────────────────────────────────────────

  describe "send_message/2 — return value" do
    setup :start_pubsub

    test "returns {:ok, request_id} immediately", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Hello")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      result = Server.send_message(agent, "hi")

      assert {:ok, request_id} = result
      assert is_binary(request_id)
      assert byte_size(request_id) > 0
    end

    test "accepts a caller-supplied :request_id", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Hello")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      assert {:ok, "my-req-123"} = Server.send_message(agent, "hi", request_id: "my-req-123")
    end
  end

  # ── Busy detection ──────────────────────────────────────────────────────────

  describe "send_message/2 — busy detection" do
    setup :start_pubsub

    test "returns {:error, :busy} when a Turn is already running", %{pubsub: pubsub} do
      # A slow response gives us a window to send a second message
      pid = start_provider([TestProvider.slow_text_response("Done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      # First send — starts the async Turn
      assert {:ok, _req_id} = Server.send_message(agent, "first")

      # Second send — should be rejected immediately while Turn is running
      assert {:error, :busy} = Server.send_message(agent, "second")

      # Let the first turn finish so the test exits cleanly
      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)
      assert_receive {:agent_response, _result}, 1000
    end

    test "is no longer busy after Turn completes", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.text_response("First"),
          TestProvider.text_response("Second")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))
      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, _} = Server.send_message(agent, "first")
      assert_receive {:agent_response, _}, 1000

      # After first turn completes, agent accepts a second message
      assert {:ok, _} = Server.send_message(agent, "second")
      assert_receive {:agent_response, _}, 1000
    end
  end

  describe "send_message/2 — bounded queue (max_pending)" do
    setup :start_pubsub

    test "queues pending requests and executes them FIFO", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.slow_text_response("First done", 250),
          TestProvider.text_response("Second done"),
          TestProvider.text_response("Third done")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub, max_pending: 2))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, req1} = Server.send_message(agent, "first")
      assert {:ok, req2} = Server.send_message(agent, "second")
      assert {:ok, req3} = Server.send_message(agent, "third")
      assert {:error, :queue_full} = Server.send_message(agent, "fourth")

      health_during = Server.health(agent)
      assert health_during.busy == true
      assert health_during.pending_count == 2

      assert_receive {:agent_response, %{request_id: ^req1, text: "First done"}}, 2_000
      assert_receive {:agent_response, %{request_id: ^req2, text: "Second done"}}, 2_000
      assert_receive {:agent_response, %{request_id: ^req3, text: "Third done"}}, 2_000
    end

    test "still returns {:error, :busy} when max_pending is 0", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Done", 250)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub, max_pending: 0))

      assert {:ok, _} = Server.send_message(agent, "first")
      assert {:error, :busy} = Server.send_message(agent, "second")
    end
  end

  describe "cancel_request/2" do
    setup :start_pubsub

    test "cancels a queued request by request_id", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.slow_text_response("First done", 250),
          TestProvider.text_response("Second done")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub, max_pending: 2))
      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, req1} = Server.send_message(agent, "first")
      assert {:ok, req2} = Server.send_message(agent, "second")

      assert :ok = Server.cancel_request(agent, req2)

      assert_receive {:agent_response, %{request_id: ^req2, error: :cancelled}}, 1_000
      assert_receive {:agent_response, %{request_id: ^req1, text: "First done"}}, 2_000
      refute_receive {:agent_response, %{request_id: ^req2, text: "Second done"}}, 300
    end

    test "cancels a running request and starts next queued request", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.slow_text_response("First done", 500),
          TestProvider.text_response("Second done")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub, max_pending: 2))
      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, req1} = Server.send_message(agent, "first")
      assert {:ok, req2} = Server.send_message(agent, "second")

      assert :ok = Server.cancel_request(agent, req1)

      assert_receive {:agent_response, %{request_id: ^req1, error: :cancelled}}, 1_000
      assert_receive {:agent_response, %{request_id: ^req2, text: "Second done"}}, 2_000
    end

    test "returns {:error, :not_found} for unknown request", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Hello")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub, max_pending: 2))

      assert {:error, :not_found} = Server.cancel_request(agent, "missing-request")
    end
  end

  # ── PubSub broadcast ────────────────────────────────────────────────────────

  describe "send_message/2 — PubSub broadcast" do
    setup :start_pubsub

    test "broadcasts {:agent_response, result} to the session topic", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Async reply")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _req_id} = Server.send_message(agent, "hello async")

      assert_receive {:agent_response, result}, 2000
      assert result.text == "Async reply"
      assert result.status == :completed
    end

    test "result includes :request_id matching the one returned by send_message", %{
      pubsub: pubsub
    } do
      pid = start_provider([TestProvider.text_response("With ID")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, req_id} = Server.send_message(agent, "correlate me")

      assert_receive {:agent_response, result}, 2000
      assert result.request_id == req_id
    end

    test "result includes standard fields (text, messages, usage, tool_calls, status, turns, error)",
         %{
           pubsub: pubsub
         } do
      pid = start_provider([TestProvider.text_response("Full result")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _} = Server.send_message(agent, "check fields")

      assert_receive {:agent_response, result}, 2000
      assert Map.has_key?(result, :text)
      assert Map.has_key?(result, :messages)
      assert Map.has_key?(result, :usage)
      assert Map.has_key?(result, :tool_calls)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :turns)
      assert Map.has_key?(result, :error)
    end
  end

  # ── THE OTP PROOF: GenServer remains responsive during Turn ─────────────────

  describe "send_message/2 — GenServer responsiveness" do
    setup :start_pubsub

    test "health/1 responds immediately while a slow Turn is running", %{pubsub: pubsub} do
      # 300ms simulates a real LLM round-trip
      pid = start_provider([TestProvider.slow_text_response("Eventually done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      # Fire the async message — Turn starts in a Task
      {:ok, _req_id} = Server.send_message(agent, "take your time")

      # GenServer must answer health/1 WITHOUT waiting for Turn to finish.
      # With a blocking implementation this would time out or wait 300ms.
      # With Task.Supervisor this responds in <10ms.
      before_ms = System.monotonic_time(:millisecond)
      health = Server.health(agent)
      elapsed_ms = System.monotonic_time(:millisecond) - before_ms

      assert health.status == :running
      assert elapsed_ms < 100, "health/1 took #{elapsed_ms}ms — GenServer is blocking during Turn"

      # Wait for Turn to finish cleanly
      assert_receive {:agent_response, _result}, 1000
    end
  end

  # ── Error handling ──────────────────────────────────────────────────────────

  describe "send_message/2 — Turn crash recovery" do
    setup :start_pubsub

    test "agent is no longer busy after Turn crashes", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.error_response(:simulated_crash),
          TestProvider.text_response("Recovery")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))
      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _} = Server.send_message(agent, "crash please")

      # Wait for the error broadcast
      assert_receive {:agent_response, result}, 2000
      assert result.status == :error

      # Agent must accept new messages after recovering
      assert {:ok, _} = Server.send_message(agent, "are you alive?")
      assert_receive {:agent_response, recovery_result}, 2000
      assert recovery_result.text == "Recovery"
    end
  end

  # ── Mutual exclusion with chat/2 and stream_chat/4 ─────────────────────────

  describe "send_message/2 — blocks chat/2 and stream_chat/4 while busy" do
    setup :start_pubsub

    test "chat/2 returns {:error, :busy} while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Async done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, _req_id} = Server.send_message(agent, "async first")

      # Synchronous chat while Turn is in flight must be rejected
      assert {:error, :busy} = Server.chat(agent, "sync during async")

      assert_receive {:agent_response, _result}, 1000
    end

    test "stream_chat/4 returns {:error, :busy} while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Async done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, _req_id} = Server.send_message(agent, "async first")

      assert {:error, :busy} =
               Server.stream_chat(agent, "sync during async", fn _chunk -> :ok end)

      assert_receive {:agent_response, _result}, 1000
    end
  end

  # ── Busy guards for reset/set_model ────────────────────────────────────────

  describe "send_message/2 — busy guards for reset and set_model" do
    setup :start_pubsub

    test "reset/1 returns {:error, :busy} while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, _req_id} = Server.send_message(agent, "async first")

      # reset while Turn is in flight must be rejected
      assert {:error, :busy} = Server.reset(agent)

      assert_receive {:agent_response, _result}, 1000
    end

    test "set_model/2 returns {:error, :busy} while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, _req_id} = Server.send_message(agent, "async first")

      # set_model while Turn is in flight must be rejected
      assert {:error, :busy} =
               Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid})

      assert_receive {:agent_response, _result}, 1000
    end
  end

  # ── Health busy field ──────────────────────────────────────────────────────

  describe "health/1 — busy field" do
    setup :start_pubsub

    test "health returns busy: false when idle", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Hello")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      health = Server.health(agent)
      assert health.busy == false
      assert health.pending_count == 0
      assert health.max_pending == 0
    end

    test "health returns busy: true while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _req_id} = Server.send_message(agent, "async")

      health = Server.health(agent)
      assert health.busy == true

      assert_receive {:agent_response, _}, 1000

      # After Turn completes, should be idle again
      health_after = Server.health(agent)
      assert health_after.busy == false
      assert health_after.pending_count == 0
    end
  end

  # ── Post-send_message state correctness ────────────────────────────────────

  describe "send_message/2 — state after Turn completes" do
    setup :start_pubsub

    test "health reports :completed status after async Turn finishes", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Done")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _req_id} = Server.send_message(agent, "hello")

      # Wait for the Turn to complete
      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed

      # After async Turn completes, health should reflect final_state's status
      health = Server.health(agent)
      assert health.status == :completed, "Expected :completed, got #{inspect(health.status)}"
      assert health.turns > 0, "Expected turns > 0 after a completed Turn"
    end
  end

  # ── Busy guard for agent_event ─────────────────────────────────────────────

  describe "send_message/2 — agent_event guard during async Turn" do
    setup :start_pubsub

    test "agent_event is dropped while async Turn is running", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Async done", 300)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      # Start async Turn
      assert {:ok, _req_id} = Server.send_message(agent, "async first")

      # Send an agent_event while Turn is in flight — should be dropped, not crash
      send(agent, {:agent_event, "interrupt attempt"})

      # The async Turn should still complete normally
      assert_receive {:agent_response, result}, 1000
      assert result.text == "Async done"

      # GenServer still alive and responsive
      health = Server.health(agent)
      assert is_map(health)
    end

    test "agent_event Turn preserves :completed status after finishing", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Event handled")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      # Trigger a synchronous agent_event Turn (no async Task in flight)
      send(agent, {:agent_event, "do some work"})

      # Give it time to complete
      Process.sleep(200)

      health = Server.health(agent)
      # The Turn finished — status should reflect completion, NOT :running
      assert health.status == :completed
    end
  end

  # ── PubSub requirement ──────────────────────────────────────────────────────

  describe "send_message/2 — requires PubSub" do
    test "returns {:error, :no_pubsub} when no pubsub is configured" do
      pid = start_provider([TestProvider.text_response("Never sent")])
      {:ok, agent} = Server.start_link(opts(pid))

      assert {:error, :no_pubsub} = Server.send_message(agent, "lost in the void")
    end
  end

  # ── Alloy top-level API ─────────────────────────────────────────────────────

  describe "Alloy async top-level delegates" do
    setup :start_pubsub

    test "Alloy.send_message/3 delegates to Server.send_message/3", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("Top level")])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, req_id} = Alloy.send_message(agent, "via top level")
      assert is_binary(req_id)

      assert_receive {:agent_response, result}, 2000
      assert result.text == "Top level"
      assert result.request_id == req_id
    end

    test "Alloy.cancel_request/2 delegates to Server.cancel_request/2", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Never finishes", 500)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      assert {:ok, req_id} = Alloy.send_message(agent, "cancel me")
      assert :ok = Alloy.cancel_request(agent, req_id)

      assert_receive {:agent_response, %{request_id: ^req_id, error: :cancelled}}, 1_000
    end
  end

  # ── Actual Task crash (:DOWN handler) ──────────────────────────────────────

  describe "send_message/2 — actual Task crash (DOWN handler)" do
    setup :start_pubsub

    test "broadcasts error and recovers when Turn.run_loop raises", %{pubsub: pubsub} do
      # A bare atom (not {:ok, ...} or {:error, ...}) will cause CaseClauseError
      # in Turn's do_provider_call, crashing the Task process.
      pid =
        start_provider([
          :crash_now,
          TestProvider.text_response("Recovery after crash")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, _req_id} = Server.send_message(agent, "trigger crash")

      # :DOWN handler should broadcast an error result
      assert_receive {:agent_response, result}, 2000
      assert result.status == :error
      assert result.error != nil

      # Agent should accept new messages after recovering from the crash
      assert {:ok, _} = Server.send_message(agent, "are you alive?")
      assert_receive {:agent_response, recovery_result}, 2000
      assert recovery_result.text == "Recovery after crash"
    end
  end

  # ── Conversation continuity after send_message ───────────────────────────

  describe "send_message/2 — conversation continuity" do
    setup :start_pubsub

    test "messages from async Turn are preserved in conversation history", %{pubsub: pubsub} do
      pid =
        start_provider([
          TestProvider.text_response("First reply"),
          TestProvider.text_response("Second reply")
        ])

      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      topic = "agent:#{agent_session_id(agent)}:responses"
      Phoenix.PubSub.subscribe(pubsub, topic)

      # Async message
      {:ok, _} = Server.send_message(agent, "first message")
      assert_receive {:agent_response, _}, 2000

      # Check messages include the user message and assistant response
      messages = Server.messages(agent)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant

      # Sync chat continues the conversation
      {:ok, result} = Server.chat(agent, "second message")
      assert result.text == "Second reply"

      # All 4 messages should be in history
      messages_after = Server.messages(agent)
      assert length(messages_after) == 4
    end
  end

  # ── Graceful shutdown during async Turn ──────────────────────────────────

  describe "send_message/2 — GenServer.stop while Task in flight" do
    setup :start_pubsub

    test "agent stops cleanly during async Turn", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.slow_text_response("Never seen", 500)])
      {:ok, agent} = Server.start_link(opts(pid, pubsub: pubsub))

      # Start async Turn
      {:ok, _req_id} = Server.send_message(agent, "going down")

      # Stop immediately while Turn is in flight
      ref = Process.monitor(agent)
      GenServer.stop(agent)

      # Agent should stop cleanly
      assert_receive {:DOWN, ^ref, :process, ^agent, :normal}, 2000
      refute Process.alive?(agent)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp agent_session_id(agent) do
    # Uses export_session/1 for the same effective_session_id logic as the server's
    # broadcast — honours context[:session_id] middleware overrides automatically.
    Server.export_session(agent).id
  end
end
