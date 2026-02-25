defmodule Anvil.StreamingTest do
  use ExUnit.Case, async: true

  alias Anvil.Agent.{Config, State, Turn, Server}
  alias Anvil.Message
  alias Anvil.Provider.Test, as: TestProvider

  # A simple tool for testing streaming + tool loops
  defmodule EchoTool do
    @behaviour Anvil.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes input back"

    @impl true
    def input_schema do
      %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]}
    end

    @impl true
    def execute(%{"text" => text}, _context) do
      {:ok, "Echo: #{text}"}
    end
  end

  # ── TestProvider.stream/4 ──────────────────────────────────────────────

  describe "TestProvider.stream/4" do
    test "calls on_chunk for each character of text" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hi!")])
      config = %{agent_pid: pid}

      chunks = collect_chunks(fn on_chunk ->
        TestProvider.stream([Message.user("Hello")], [], config, on_chunk)
      end)

      # "Hi!" should yield 3 chunks: "H", "i", "!"
      assert chunks == ["H", "i", "!"]
    end

    test "returns same response shape as complete/3" do
      {:ok, pid1} = TestProvider.start_link([TestProvider.text_response("Same")])
      {:ok, pid2} = TestProvider.start_link([TestProvider.text_response("Same")])

      {:ok, from_complete} = TestProvider.complete([Message.user("Hi")], [], %{agent_pid: pid1})
      {:ok, from_stream} = TestProvider.stream([Message.user("Hi")], [], %{agent_pid: pid2}, fn _ -> :ok end)

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

      chunks = collect_chunks(fn on_chunk ->
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

  # ── Turn.run_loop with streaming ───────────────────────────────────────

  describe "Turn.run_loop with streaming" do
    test "calls on_chunk when streaming=true" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hello")])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        streaming: true,
        context: %{on_chunk: on_chunk}
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

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

      # Non-streaming
      config1 = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid1}
      }

      state1 = State.init(config1, [Message.user("Hi")])
      result1 = Turn.run_loop(state1)

      # Streaming
      config2 = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid2},
        streaming: true,
        context: %{on_chunk: fn _ -> :ok end}
      }

      state2 = State.init(config2, [Message.user("Hi")])
      result2 = Turn.run_loop(state2)

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
        tools: [EchoTool],
        streaming: true,
        context: %{on_chunk: on_chunk}
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 2

      # Should receive chunks from the final text response "Done!"
      assert_received {:chunk, "D"}
      assert_received {:chunk, "o"}
      assert_received {:chunk, "n"}
      assert_received {:chunk, "e"}
      assert_received {:chunk, "!"}
    end
  end

  # ── Server.stream_chat/3 ──────────────────────────────────────────────

  describe "Server.stream_chat/3" do
    test "calls on_chunk and returns result" do
      {:ok, provider} = TestProvider.start_link([TestProvider.text_response("Hi!")])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider}
        )

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = Server.stream_chat(agent, "Hello", on_chunk)
      assert result.text == "Hi!"
      assert result.status == :completed

      assert_received {:chunk, "H"}
      assert_received {:chunk, "i"}
      assert_received {:chunk, "!"}
    end

    test "preserves conversation history" do
      {:ok, provider} =
        TestProvider.start_link([
          TestProvider.text_response("First"),
          TestProvider.text_response("Second")
        ])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider}
        )

      {:ok, _} = Server.stream_chat(agent, "Hello", fn _ -> :ok end)
      {:ok, _} = Server.stream_chat(agent, "Again", fn _ -> :ok end)

      messages = Server.messages(agent)
      # user1, assistant1, user2, assistant2
      assert length(messages) == 4
    end

    test "streaming config does not persist after stream_chat" do
      {:ok, provider} =
        TestProvider.start_link([
          TestProvider.text_response("Streamed"),
          TestProvider.text_response("Not streamed")
        ])

      {:ok, agent} =
        Server.start_link(
          provider: {TestProvider, agent_pid: provider}
        )

      # First: stream_chat
      {:ok, _} = Server.stream_chat(agent, "Hello", fn _ -> :ok end)

      # Second: regular chat (should NOT stream)
      # If streaming persisted, this would fail because there's no on_chunk in context
      {:ok, result} = Server.chat(agent, "Hello again")
      assert result.text == "Not streamed"
      assert result.status == :completed
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
