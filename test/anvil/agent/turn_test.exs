defmodule Anvil.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Anvil.Agent.{Config, State, Turn}
  alias Anvil.Message
  alias Anvil.Provider.Test, as: TestProvider

  alias Anvil.Test.EchoTool

  describe "run_loop/1 with simple text response" do
    test "completes in one turn" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Hello there!")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state =
        State.init(config, [Message.user("Hi")])

      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 1

      # Should have user msg + assistant response
      assert length(result.messages) == 2
      last_msg = List.last(result.messages)
      assert last_msg.role == :assistant
      assert Message.text(last_msg) == "Hello there!"
    end
  end

  describe "run_loop/1 with tool use" do
    test "executes tools and continues" do
      {:ok, pid} =
        TestProvider.start_link([
          # Turn 1: model calls the echo tool
          TestProvider.tool_use_response([
            %{id: "tool_1", name: "echo", input: %{"text" => "world"}}
          ]),
          # Turn 2: model responds with final text after seeing tool result
          TestProvider.text_response("Tool said: Echo: world")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo world")])

      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 2

      # Messages: user, assistant(tool_use), user(tool_result), assistant(text)
      assert length(result.messages) == 4
    end

    test "handles multiple tool calls in one turn" do
      {:ok, pid} =
        TestProvider.start_link([
          # Turn 1: model calls echo twice
          TestProvider.tool_use_response([
            %{id: "tool_1", name: "echo", input: %{"text" => "foo"}},
            %{id: "tool_2", name: "echo", input: %{"text" => "bar"}}
          ]),
          # Turn 2: done
          TestProvider.text_response("Got both results")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo two things")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 2

      # Check that tool results message has 2 result blocks
      tool_result_msg = Enum.at(result.messages, 2)
      assert tool_result_msg.role == :user
      assert length(tool_result_msg.content) == 2
    end
  end

  describe "run_loop/1 with max_turns" do
    test "stops at max_turns" do
      # Create responses that always ask for tools (infinite loop)
      responses =
        for _ <- 1..30 do
          TestProvider.tool_use_response([
            %{id: "tool_#{:rand.uniform(1000)}", name: "echo", input: %{"text" => "loop"}}
          ])
        end

      {:ok, pid} = TestProvider.start_link(responses)

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        max_turns: 3
      }

      state = State.init(config, [Message.user("Loop forever")])
      result = Turn.run_loop(state)

      assert result.status == :max_turns
      assert result.turn == 3
    end
  end

  describe "run_loop/1 with provider errors" do
    test "sets error status on provider failure" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("API rate limited")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "API rate limited"
    end
  end

  describe "run_loop/1 with middleware" do
    test "calls middleware at hook points" do
      test_pid = self()

      defmodule TrackingMiddleware do
        @behaviour Anvil.Middleware

        def call(hook, state) do
          send(state.config.context[:test_pid], {:middleware, hook})
          state
        end
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [TrackingMiddleware],
        context: %{test_pid: test_pid}
      }

      state = State.init(config, [Message.user("Hi")])
      Turn.run_loop(state)

      assert_received {:middleware, :before_completion}
      assert_received {:middleware, :after_completion}
    end

    test "calls after_tool_execution hook when tools run" do
      test_pid = self()

      defmodule ToolTrackingMiddleware do
        @behaviour Anvil.Middleware

        def call(hook, state) do
          send(state.config.context[:test_pid], {:middleware, hook})
          state
        end
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        middleware: [ToolTrackingMiddleware],
        context: %{test_pid: test_pid}
      }

      state = State.init(config, [Message.user("Echo hi")])
      Turn.run_loop(state)

      assert_received {:middleware, :after_tool_execution}
    end
  end

  describe "run_loop/1 tracks usage" do
    test "accumulates token usage across turns" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      # TestProvider returns 10 input + 5 output per call, 2 calls
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 10
    end
  end
end
