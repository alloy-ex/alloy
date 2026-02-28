defmodule Alloy.Agent.ServerTest do
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

  describe "start_link/1" do
    test "starts a linked GenServer" do
      pid = start_provider([TestProvider.text_response("Hi")])
      assert {:ok, agent} = Server.start_link(opts(pid))
      assert Process.alive?(agent)
    end

    test "accepts a name option" do
      pid = start_provider([TestProvider.text_response("Hi")])
      name = :"test_server_#{System.unique_integer()}"
      assert {:ok, _} = Server.start_link(opts(pid, name: name))
      assert Process.whereis(name) != nil
    end
  end

  describe "chat/2" do
    test "returns {:ok, result} with text" do
      pid = start_provider([TestProvider.text_response("Hello from Alloy!")])
      {:ok, agent} = Server.start_link(opts(pid))
      assert {:ok, result} = Server.chat(agent, "Hello")
      assert result.text == "Hello from Alloy!"
      assert result.status == :completed
    end

    test "persists conversation history across calls" do
      pid =
        start_provider([
          TestProvider.text_response("First reply"),
          TestProvider.text_response("Second reply")
        ])

      {:ok, agent} = Server.start_link(opts(pid))

      {:ok, _} = Server.chat(agent, "First message")
      {:ok, _} = Server.chat(agent, "Second message")

      messages = Server.messages(agent)
      # user1, assistant1, user2, assistant2
      assert length(messages) == 4
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == "First message"
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 2).role == :user
      assert Enum.at(messages, 2).content == "Second message"
    end

    test "returns :turns in result" do
      pid = start_provider([TestProvider.text_response("Done")])
      {:ok, agent} = Server.start_link(opts(pid))
      {:ok, result} = Server.chat(agent, "Go")
      assert result.turns == 1
    end
  end

  describe "messages/1" do
    test "returns [] before any chat" do
      pid = start_provider([])
      {:ok, agent} = Server.start_link(opts(pid))
      assert Server.messages(agent) == []
    end

    test "returns full history after chat" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "Hello")
      assert length(Server.messages(agent)) == 2
    end
  end

  describe "reset/1" do
    test "clears message history" do
      pid =
        start_provider([
          TestProvider.text_response("Hi"),
          TestProvider.text_response("After reset")
        ])

      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "Hello")
      assert length(Server.messages(agent)) == 2

      :ok = Server.reset(agent)
      assert Server.messages(agent) == []
    end
  end

  describe "usage/1" do
    test "accumulates token usage across calls" do
      pid =
        start_provider([
          TestProvider.text_response("One"),
          TestProvider.text_response("Two")
        ])

      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "First")
      usage_after_one = Server.usage(agent)

      Server.chat(agent, "Second")
      usage_after_two = Server.usage(agent)

      # Usage should grow after second call
      assert usage_after_two.input_tokens >= usage_after_one.input_tokens
    end
  end

  describe "chat/3 with timeout option" do
    test "uses default timeout (2 min) when not specified" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      assert {:ok, result} = Server.chat(agent, "Hello")
      assert result.status == :completed
    end

    test "custom timeout: 0ms exits immediately when provider is slow" do
      pid = start_provider([TestProvider.text_response("Slow response")])
      {:ok, agent} = Server.start_link(opts(pid))
      # With timeout: 0, GenServer.call will immediately timeout
      assert catch_exit(Server.chat(agent, "Hello", timeout: 0)) != nil
    end
  end

  describe "stream_chat/4 with timeout option" do
    test "uses default timeout (2 min) when not specified" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      assert {:ok, result} = Server.stream_chat(agent, "Hello", fn _chunk -> :ok end)
      assert result.status == :completed
    end

    test "custom timeout: 0ms exits immediately when provider is slow" do
      pid = start_provider([TestProvider.text_response("Slow response")])
      {:ok, agent} = Server.start_link(opts(pid))

      assert catch_exit(Server.stream_chat(agent, "Hello", fn _chunk -> :ok end, timeout: 0)) !=
               nil
    end
  end

  describe "export_session/1" do
    test "returns a %Alloy.Session{} with correct messages" do
      pid = start_provider([TestProvider.text_response("Export test response")])
      {:ok, agent} = Server.start_link(opts(pid))
      {:ok, _} = Server.chat(agent, "Hello for export")

      session = Server.export_session(agent)

      assert %Alloy.Session{} = session
      assert length(session.messages) == 2
      assert %Alloy.Usage{} = session.usage
      # After chat completes, server resets to :idle for the next call
      assert session.metadata.status == :idle
    end

    test "session ID comes from context if provided" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid, context: %{session_id: "my-session-123"}))

      session = Server.export_session(agent)

      assert session.id == "my-session-123"
    end

    test "session ID is auto-generated if not in context" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))

      session = Server.export_session(agent)

      assert is_binary(session.id)
      assert byte_size(session.id) > 0
    end

    test "export_session/1 returns the same id across multiple calls" do
      pid =
        start_provider([
          TestProvider.text_response("First"),
          TestProvider.text_response("Second")
        ])

      {:ok, agent} = Server.start_link(opts(pid))

      {:ok, _} = Server.chat(agent, "Hello")
      session1 = Server.export_session(agent)

      {:ok, _} = Server.chat(agent, "Hello again")
      session2 = Server.export_session(agent)

      assert session1.id == session2.id,
             "export_session/1 must return a stable id across calls for the same agent lifecycle"
    end
  end

  describe "EXIT signal handling" do
    test "agent survives when a non-parent linked process exits normally" do
      # OTP gen_server intercepts {EXIT, Parent, Reason} at the receive-loop level
      # and always terminates the server — that is expected OTP behaviour and cannot
      # be overridden via handle_info.
      #
      # The bug fixed here is different: when ANY other linked process (not the OTP
      # parent) exits :normal, the old catch-all handle_info clause returned
      # {:stop, :normal, state}, which stopped the agent. The fix adds an explicit
      # {:EXIT, _pid, :normal} clause that returns {:noreply, state} so the agent
      # ignores these benign exits.
      #
      # We simulate this by having the agent start normally (test process is the OTP
      # parent), then using Process.link/1 from a separate short-lived process to
      # establish a non-parent link. When that process exits :normal, BEAM sends
      # {:EXIT, helper_pid, :normal} to the agent's mailbox, which is routed through
      # handle_info (not the OTP parent-exit path).
      pid = start_provider([TestProvider.text_response("ok")])
      {:ok, agent} = Server.start_link(opts(pid))

      # Spawn a helper that links itself to the agent and immediately exits :normal.
      # Because the helper is NOT the OTP parent (the test process is), BEAM delivers
      # {:EXIT, helper_pid, :normal} as a regular mailbox message to the agent via
      # handle_info — not via the special parent-exit path.
      test_pid = self()
      ref = make_ref()

      spawn(fn ->
        Process.link(agent)
        send(test_pid, {ref, :linked})
        # exits :normal — triggers {:EXIT, self(), :normal} to agent via handle_info
      end)

      assert_receive {^ref, :linked}, 500
      # Give BEAM time to deliver the :EXIT message
      Process.sleep(50)

      assert Process.alive?(agent),
             "Agent was stopped by a :normal exit from a non-parent linked process — should be ignored"
    end
  end

  describe "graceful shutdown" do
    test "on_shutdown callback is called when agent stops" do
      test_pid = self()
      pid = start_provider([TestProvider.text_response("Shutdown test")])

      {:ok, agent} =
        Server.start_link(
          opts(pid, on_shutdown: fn session -> send(test_pid, {:shutdown, session}) end)
        )

      {:ok, _} = Server.chat(agent, "Hello before shutdown")
      Server.stop(agent)

      assert_receive {:shutdown, session}, 1000
      assert %Alloy.Session{} = session
    end

    test "crashing on_shutdown callback does not prevent clean stop" do
      pid = start_provider([TestProvider.text_response("Hi")])

      {:ok, agent} =
        Server.start_link(opts(pid, on_shutdown: fn _session -> raise "crash in shutdown" end))

      # This should not crash the test process — the agent must stop cleanly
      assert :ok = Server.stop(agent)
      refute Process.alive?(agent)
    end

    test "on_shutdown callback that throws does not prevent clean stop" do
      # on_shutdown throws. The `catch _, _` guard in terminate/2 must catch
      # it so the process exits cleanly. Without the fix (catch :exit, _ only)
      # the throw escapes the catch clause and aborts terminate/2 mid-execution.
      # OTP absorbs the escaped throw during :normal shutdown so the process
      # still dies, but the catch clause in terminate/2 ensures the throw is
      # handled explicitly (making intent clear and protecting non-normal exits).
      provider_pid = start_provider([TestProvider.text_response("Hi")])

      {:ok, agent} =
        Server.start_link(opts(provider_pid, on_shutdown: fn _session -> throw(:oops) end))

      # Agent must stop cleanly — no crash, no test failure
      assert :ok = Server.stop(agent)
      refute Process.alive?(agent)
    end

    test "agent without on_shutdown stops cleanly" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      Server.stop(agent)

      refute Process.alive?(agent)
    end

    test "EXIT message from a linked process flows through terminate/2 (on_shutdown runs, process stops)" do
      # Regression test for the EXIT-swallowing bug.
      #
      # Context: Server.init/1 calls Process.flag(:trap_exit, true). This converts
      # exit signals from LINKED processes into {:EXIT, pid, reason} messages
      # delivered to the GenServer mailbox via handle_info.
      #
      # The old catch-all handle_info(_msg, state) returns {:noreply, state},
      # which swallows the {:EXIT, linked_pid, reason} message — the server
      # stays alive indefinitely, never calls terminate/2, and on_shutdown never
      # runs. A supervisor waiting for the child to stop is forced to use the
      # brutal_kill strategy after the shutdown timeout.
      #
      # The fix: an explicit handle_info({:EXIT, _pid, reason}, state) clause
      # that returns {:stop, reason, state}, letting OTP call terminate/2 normally.
      #
      # NOTE: Process.exit(server_pid, :shutdown) is handled by OTP at a lower
      # level — it calls terminate/2 directly, bypassing handle_info. The bug
      # only manifests when a LINKED process dies and BEAM delivers the EXIT as
      # a message to the mailbox. We simulate that here with a raw send/2.
      test_pid = self()

      pid = start_provider([])

      {:ok, agent} =
        Server.start_link(
          opts(pid, on_shutdown: fn session -> send(test_pid, {:shutdown_ran, session}) end)
        )

      Process.unlink(agent)

      # Simulate BEAM delivering an {:EXIT, linked_pid, :shutdown} message to
      # the agent mailbox — this is exactly what happens when a process that
      # the server is linked to exits while trap_exit is true.
      fake_linked_pid = spawn(fn -> :ok end)
      send(agent, {:EXIT, fake_linked_pid, :shutdown})

      # on_shutdown must run, proving terminate/2 was reached via {:stop, ...}
      # and NOT swallowed by a {:noreply, state} catch-all.
      assert_receive {:shutdown_ran, _session}, 1000

      # The server must actually be dead — {:noreply, state} would leave it alive.
      refute Process.alive?(agent)
    end

    test "on_shutdown receives a valid Session with messages" do
      test_pid = self()
      pid = start_provider([TestProvider.text_response("Message for shutdown")])

      {:ok, agent} =
        Server.start_link(
          opts(pid, on_shutdown: fn session -> send(test_pid, {:shutdown, session}) end)
        )

      {:ok, _} = Server.chat(agent, "Test message")
      Server.stop(agent)

      assert_receive {:shutdown, session}, 1000
      assert length(session.messages) == 2
    end
  end

  describe "set_model/2" do
    test "switches provider module and config" do
      pid = start_provider([TestProvider.text_response("Before switch")])
      {:ok, agent} = Server.start_link(opts(pid))

      {:ok, result} = Server.chat(agent, "Hello")
      assert result.text == "Before switch"

      # Create a new provider with different responses
      pid2 = start_provider([TestProvider.text_response("After switch")])

      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      {:ok, result2} = Server.chat(agent, "Hello again")
      assert result2.text == "After switch"
    end

    test "preserves conversation history after model switch" do
      pid =
        start_provider([
          TestProvider.text_response("First response")
        ])

      {:ok, agent} = Server.start_link(opts(pid))
      {:ok, _} = Server.chat(agent, "Hello")

      assert length(Server.messages(agent)) == 2

      pid2 = start_provider([TestProvider.text_response("Second response")])
      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      {:ok, _} = Server.chat(agent, "Hello again")
      # History should include all 4 messages (before + after switch)
      assert length(Server.messages(agent)) == 4
    end

    test "accepts bare module atom without config" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))

      # Should not raise — bare module is valid
      :ok = Server.set_model(agent, provider: Alloy.Provider.Test)
    end
  end

  describe "middleware halt at :session_start" do
    defmodule HaltAtStartMiddleware do
      @behaviour Alloy.Middleware

      def call(:session_start, _state), do: {:halt, "blocked at start"}
      def call(_hook, %Alloy.Agent.State{} = state), do: state
    end

    test "server fails to start when middleware halts at :session_start" do
      # Trap exits so the linked server's :stop doesn't kill the test process
      Process.flag(:trap_exit, true)

      pid = start_provider([TestProvider.text_response("Hi")])

      result =
        Server.start_link(opts(pid, middleware: [HaltAtStartMiddleware]))

      assert {:error, {:middleware_halted, "blocked at start"}} = result
    end
  end

  describe "on_shutdown receives post-middleware state" do
    defmodule SessionEndEnricherMiddleware do
      @behaviour Alloy.Middleware

      def call(:session_end, %Alloy.Agent.State{} = state) do
        # Set session_id in context -- build_export_session reads this
        # to set session.id. If on_shutdown uses pre-middleware state,
        # session.id will NOT be "enriched-session-id".
        updated_context = Map.put(state.config.context, :session_id, "enriched-session-id")
        updated_config = %{state.config | context: updated_context}
        %{state | config: updated_config}
      end

      def call(_hook, %Alloy.Agent.State{} = state), do: state
    end

    test "on_shutdown callback receives session built from post-middleware state" do
      test_pid = self()
      pid = start_provider([TestProvider.text_response("Shutdown test")])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            middleware: [SessionEndEnricherMiddleware],
            on_shutdown: fn session -> send(test_pid, {:shutdown, session}) end
          )
        )

      {:ok, _} = Server.chat(agent, "Hello before shutdown")
      Server.stop(agent)

      assert_receive {:shutdown, session}, 1000
      assert %Alloy.Session{} = session
      # If Task 1 fix is applied, the session will be built from post-middleware
      # state where context.session_id was set to "enriched-session-id"
      assert session.id == "enriched-session-id"
    end

    defmodule SessionEndHaltMiddleware do
      @behaviour Alloy.Middleware

      def call(:session_end, _state), do: {:halt, "session_end halted"}
      def call(_hook, %Alloy.Agent.State{} = state), do: state
    end

    test "on_shutdown still fires when :session_end middleware halts (uses original state)" do
      test_pid = self()
      pid = start_provider([TestProvider.text_response("Hi")])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            middleware: [SessionEndHaltMiddleware],
            on_shutdown: fn session -> send(test_pid, {:shutdown, session}) end
          )
        )

      {:ok, _} = Server.chat(agent, "Hello")
      Server.stop(agent)

      assert_receive {:shutdown, session}, 1000
      assert %Alloy.Session{} = session
    end
  end

  describe "init/1 PubSub subscription uses post-middleware config" do
    defmodule SubscribeRewriteMiddleware do
      @behaviour Alloy.Middleware

      # Replaces the subscribe list with a middleware-chosen topic.
      # If init reads the pre-middleware config, the agent will subscribe to
      # "original_topic" (from opts). If it reads state.config (post-middleware),
      # it subscribes to "middleware_topic". The test checks which one it got.
      def call(:session_start, %Alloy.Agent.State{} = state) do
        updated_config = %{state.config | subscribe: ["middleware_topic"]}
        %{state | config: updated_config}
      end

      def call(_hook, %Alloy.Agent.State{} = state), do: state
    end

    setup do
      pubsub_name = :"test_pubsub_srv_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      {:ok, pubsub: pubsub_name}
    end

    test "subscribes to post-middleware topics, not pre-middleware opts topics", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("ok")])

      # Agent opts say subscribe: ["original_topic"], but SubscribeRewriteMiddleware
      # will rewrite state.config.subscribe to ["middleware_topic"] during :session_start.
      # The bug: the old code reads `config.subscribe` (pre-middleware), so it
      # subscribes to "original_topic" and ignores the middleware change.
      # The fix: read `state.config.subscribe` (post-middleware).
      {:ok, agent} =
        Server.start_link(
          opts(pid,
            pubsub: pubsub,
            subscribe: ["original_topic"],
            middleware: [SubscribeRewriteMiddleware]
          )
        )

      # If the bug is present, the agent subscribed to "original_topic" but stored
      # "middleware_topic" in state.config. Verify the stored config is post-middleware.
      agent_state = :sys.get_state(agent)
      assert agent_state.config.subscribe == ["middleware_topic"]

      # More critically: verify the agent actually receives a message on the
      # middleware topic, proving it subscribed to the right topic.
      # Subscribe ourselves to observe the agent's response broadcast.
      agent_id = agent_state.agent_id
      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}:responses")

      # Send to "middleware_topic" — only a subscribed agent will process this.
      Phoenix.PubSub.broadcast(
        pubsub,
        "middleware_topic",
        {:agent_event, "hello from middleware topic"}
      )

      # Agent must respond, confirming it was subscribed to "middleware_topic".
      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed
    end
  end

  describe "PubSub broadcast uses effective_session_id (session_id context wins over agent_id)" do
    defmodule SessionIdInjectMiddleware do
      @behaviour Alloy.Middleware

      # Injects context[:session_id] during :session_start so that
      # effective_session_id/1 returns "custom-session-123" instead of
      # the raw agent_id UUID.
      def call(:session_start, %Alloy.Agent.State{} = state) do
        updated_context = Map.put(state.config.context, :session_id, "custom-session-123")
        updated_config = %{state.config | context: updated_context}
        %{state | config: updated_config}
      end

      def call(_hook, %Alloy.Agent.State{} = state), do: state
    end

    setup do
      pubsub_name = :"test_pubsub_sid_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      {:ok, pubsub: pubsub_name}
    end

    test "agent_event broadcasts to session-ID-based topic, not agent_id topic", %{pubsub: pubsub} do
      pid = start_provider([TestProvider.text_response("session id response")])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            pubsub: pubsub,
            subscribe: ["agent_events"],
            middleware: [SessionIdInjectMiddleware]
          )
        )

      # Subscribe to the session-ID-based topic — this is what a caller
      # that has the exported session ID would use.
      Phoenix.PubSub.subscribe(pubsub, "agent:custom-session-123:responses")

      # Trigger the agent via PubSub event
      Phoenix.PubSub.broadcast(pubsub, "agent_events", {:agent_event, "hello"})

      # Must receive on the session-ID topic, NOT the agent_id topic.
      # Before the fix, broadcasts go to "agent:<agent_id>:responses" and this
      # assertion times out.
      assert_receive {:agent_response, result}, 2000
      assert result.status == :completed
    end
  end

  describe "chat/2 timeout coupling with config.timeout_ms" do
    test "chat does not crash with GenServer call timeout when config.timeout_ms is short" do
      # The bug: chat/3 defaults GenServer.call timeout to 120_000 regardless of
      # config.timeout_ms. If config.timeout_ms is very short (e.g. 100ms), the Turn
      # returns quickly via deadline awareness, but the GenServer.call timeout is
      # irrelevant here. The real issue surfaces when config.timeout_ms > 120_000.
      #
      # This test verifies the inverse: with a very short timeout_ms (100ms),
      # the Turn aborts via deadline, and the GenServer.call does NOT wait 120s.
      pid =
        start_provider([
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Should not reach")
        ])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            max_retries: 3,
            retry_backoff_ms: 50_000,
            timeout_ms: 100
          )
        )

      start_time = System.monotonic_time(:millisecond)
      result = Server.chat(agent, "Hi")
      elapsed = System.monotonic_time(:millisecond) - start_time

      # The Turn should abort via deadline in <500ms, and the GenServer.call
      # should return promptly — NOT wait 120 seconds.
      assert elapsed < 2_000,
             "Expected quick return via deadline but took #{elapsed}ms — call timeout not coupled"

      assert {:error, error_result} = result
      assert error_result.status == :error
    end

    test "stream_chat does not crash with GenServer call timeout when config.timeout_ms is short" do
      pid =
        start_provider([
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Should not reach")
        ])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            max_retries: 3,
            retry_backoff_ms: 50_000,
            timeout_ms: 100
          )
        )

      start_time = System.monotonic_time(:millisecond)
      result = Server.stream_chat(agent, "Hi", fn _chunk -> :ok end)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 2_000
      assert {:error, _} = result
    end
  end

  describe "health/1" do
    test "returns expected shape" do
      pid = start_provider([])
      {:ok, agent} = Server.start_link(opts(pid))

      health = Server.health(agent)

      assert Map.has_key?(health, :status)
      assert Map.has_key?(health, :turns)
      assert Map.has_key?(health, :message_count)
      assert Map.has_key?(health, :usage)
      assert Map.has_key?(health, :uptime_ms)
      assert health.status == :idle
      assert health.turns == 0
      assert health.message_count == 0
    end

    test "uptime_ms is positive" do
      pid = start_provider([])
      {:ok, agent} = Server.start_link(opts(pid))
      Process.sleep(10)

      health = Server.health(agent)

      assert health.uptime_ms > 0
    end

    test "works even when agent has no messages" do
      pid = start_provider([])
      {:ok, agent} = Server.start_link(opts(pid))

      health = Server.health(agent)

      assert health.message_count == 0
    end

    test "message_count updates after chat" do
      pid = start_provider([TestProvider.text_response("Health check response")])
      {:ok, agent} = Server.start_link(opts(pid))
      {:ok, _} = Server.chat(agent, "Count this")

      health = Server.health(agent)

      # user message + assistant message = 2
      assert health.message_count == 2
    end
  end
end
