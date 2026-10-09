defmodule Alloy.StreamingTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  alias Alloy.Test.EchoTool

  # ── TestProvider.stream/4 ──────────────────────────────────────────────

  describe "TestProvider.stream/4" do
    test "calls on_chunk for each character of text" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hi!")])
      config = %{agent_pid: pid}

      chunks =
        collect_chunks(fn on_chunk ->
          TestProvider.stream([Message.user("Hello")], [], config, on_chunk)
        end)

      # "Hi!" should yield 3 chunks: "H", "i", "!"
      assert chunks == ["H", "i", "!"]
    end

    test "returns same response shape as complete/3" do
      {:ok, pid1} = TestProvider.start_link([TestProvider.text_response("Same")])
      {:ok, pid2} = TestProvider.start_link([TestProvider.text_response("Same")])

      {:ok, from_complete} = TestProvider.complete([Message.user("Hi")], [], %{agent_pid: pid1})

      {:ok, from_stream} =
        TestProvider.stream([Message.user("Hi")], [], %{agent_pid: pid2}, fn _ -> :ok end)

      assert from_complete.stop_reason == from_stream.stop_reason
      assert from_complete.messages == from_stream.messages
      assert from_complete.usage == from_stream.usage
    end

    test "skips streaming for tool_use responses (just returns the response)" do
      tool_calls = [
        %{type: "tool_use", id: "call_1", name: "echo", input: %{"text" => "hi"}}
      ]

      {:ok, pid} = TestProvider.start_link([TestProvider.tool_use_response(tool_calls)])
      config = %{agent_pid: pid}

      chunks =
        collect_chunks(fn on_chunk ->
          TestProvider.stream([Message.user("Use tool")], [], config, on_chunk)
        end)

      # No chunks for tool_use responses
      assert chunks == []
    end

    test "consumes from the same script queue as complete/3" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("First"),
          TestProvider.text_response("Second"),
          TestProvider.text_response("Third")
        ])

      config = %{agent_pid: pid}

      # First: complete
      {:ok, r1} = TestProvider.complete([Message.user("Hi")], [], config)
      assert hd(r1.messages).content == "First"

      # Second: stream
      {:ok, r2} = TestProvider.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert hd(r2.messages).content == "Second"

      # Third: complete again
      {:ok, r3} = TestProvider.complete([Message.user("Hi")], [], config)
      assert hd(r3.messages).content == "Third"
    end
  end

  # ── Turn.run_loop with streaming via opts ──────────────────────────────

  describe "Turn.run_loop with streaming via opts" do
    test "calls on_chunk when streaming: true passed as opt" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hello")])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state, streaming: true, on_chunk: on_chunk)

      assert result.status == :completed

      # Should receive each character of "Hello"
      assert_received {:chunk, "H"}
      assert_received {:chunk, "e"}
      assert_received {:chunk, "l"}
      assert_received {:chunk, "l"}
      assert_received {:chunk, "o"}
    end

    test "result is identical whether streaming or not" do
      {:ok, pid1} = TestProvider.start_link([TestProvider.text_response("Same result")])
      {:ok, pid2} = TestProvider.start_link([TestProvider.text_response("Same result")])

      # Non-streaming (no opts)
      config1 = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid1}
      }

      state1 = State.init(config1, [Message.user("Hi")])
      result1 = Turn.run_loop(state1)

      # Streaming (via opts)
      config2 = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid2}
      }

      state2 = State.init(config2, [Message.user("Hi")])
      result2 = Turn.run_loop(state2, streaming: true, on_chunk: fn _ -> :ok end)

      assert result1.status == result2.status
      assert result1.turn == result2.turn
      assert result1.messages == result2.messages
      assert result1.usage == result2.usage
    end

    test "tool loops work with streaming (stream, execute tools, stream again)" do
      {:ok, pid} =
        TestProvider.start_link([
          # Turn 1: tool call (not streamed character-by-character)
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          # Turn 2: final text response (streamed)
          TestProvider.text_response("Done!")
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state, streaming: true, on_chunk: on_chunk)

      assert result.status == :completed
      assert result.turn == 2

      # Should receive chunks from the final text response "Done!"
      assert_received {:chunk, "D"}
      assert_received {:chunk, "o"}
      assert_received {:chunk, "n"}
      assert_received {:chunk, "e"}
      assert_received {:chunk, "!"}
    end

    test "no opts defaults to non-streaming" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("No stream")])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hi")])
      # Call without opts — should not raise and should complete normally
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert State.last_assistant_text(result) == "No stream"
    end
  end

  # ── Config does not have :streaming field ──────────────────────────────

  describe "Config struct" do
    test "does not have a :streaming field" do
      config = %Config{
        provider: TestProvider,
        provider_config: %{}
      }

      # The struct must not define a :streaming key
      refute Map.has_key?(Map.from_struct(config), :streaming)
    end
  end

  # ── Alloy.stream/3 event envelopes ─────────────────────────────────────

  describe "Alloy.stream/3 event envelopes" do
    test "on_event: nil is treated as no-op (does not crash)" do
      {:ok, provider} = TestProvider.start_link([TestProvider.text_response("Hello")])

      assert {:ok, _} =
               Alloy.stream("Hi", fn _ -> :ok end,
                 provider: {TestProvider, agent_pid: provider},
                 on_event: nil
               )
    end

    test "text deltas share a correlation id and carry increasing seq numbers" do
      {:ok, provider} = TestProvider.start_link([TestProvider.text_response("Hi")])
      test_pid = self()

      {:ok, result} =
        Alloy.stream("Hello", fn _ -> :ok end,
          provider: {TestProvider, agent_pid: provider},
          on_event: &send(test_pid, {:event, &1})
        )

      assert result.status == :completed

      assert_received {:event,
                       %{v: 1, event: :text_delta, correlation_id: correlation_id, payload: "H"} =
                         first}

      assert_received {:event,
                       %{v: 1, event: :text_delta, correlation_id: ^correlation_id, payload: "i"} =
                         second}

      assert second.seq > first.seq
    end

    test "tool_start and tool_end envelopes bracket a tool call" do
      {:ok, provider} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "tool_1", name: "echo", input: %{"text" => "world"}}
          ]),
          TestProvider.text_response("Tool said: Echo: world")
        ])

      test_pid = self()

      {:ok, result} =
        Alloy.stream("Echo world", fn _ -> :ok end,
          provider: {TestProvider, agent_pid: provider},
          tools: [EchoTool],
          on_event: &send(test_pid, {:event, &1})
        )

      assert result.status == :completed

      assert_received {:event,
                       %{v: 1, event: :tool_start, correlation_id: correlation_id} = tool_start}

      assert tool_start.payload.id == "tool_1"
      assert tool_start.payload.name == "echo"
      assert tool_start.payload.input == %{"text" => "world"}

      assert_received {:event,
                       %{v: 1, event: :tool_end, correlation_id: ^correlation_id} = tool_end}

      assert %{id: "tool_1", name: "echo", error: nil, duration_ms: duration_ms} =
               tool_end.payload

      assert is_integer(duration_ms) and duration_ms >= 0
      assert tool_end.payload.start_event_seq == tool_start.seq
      assert tool_end.seq > tool_start.seq
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp collect_chunks(fun) do
    test_pid = self()
    on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

    fun.(on_chunk)

    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      {:chunk, chunk} -> collect_messages(acc ++ [chunk])
    after
      100 -> acc
    end
  end
end
