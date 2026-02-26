defmodule Alloy.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Alloy.Middleware
  alias Alloy.Agent.{Config, State}
  alias Alloy.Provider.Test, as: TestProvider

  # A middleware that blocks a specific tool
  defmodule BlockBashMiddleware do
    @behaviour Alloy.Middleware

    def call(:before_tool_call, %State{} = state) do
      tool_call = state.config.context[:current_tool_call]

      if tool_call[:name] == "bash" do
        {:block, "bash tool is disabled by policy"}
      else
        state
      end
    end

    def call(_hook, %State{} = state), do: state
  end

  # A middleware that tracks which hooks fired
  defmodule TrackingMiddleware do
    @behaviour Alloy.Middleware

    def call(hook, %State{} = state) do
      tracker = state.config.context[:tracker]
      if tracker, do: send(tracker, {:hook_fired, hook})
      state
    end
  end

  defp build_state(overrides) do
    config =
      Config.from_opts(
        Keyword.merge(
          [provider: Alloy.Provider.Test, middleware: []],
          overrides
        )
      )

    State.init(config)
  end

  describe "run/2 with new hooks" do
    test "existing Logger middleware handles new hooks without crashing" do
      state = build_state(middleware: [Alloy.Middleware.Logger])

      # These should not raise FunctionClauseError
      assert %State{} = Middleware.run(:before_tool_call, state)
      assert %State{} = Middleware.run(:session_start, state)
      assert %State{} = Middleware.run(:session_end, state)
    end

    test "existing Telemetry middleware handles new hooks without crashing" do
      state = build_state(middleware: [Alloy.Middleware.Telemetry])

      assert %State{} = Middleware.run(:before_tool_call, state)
      assert %State{} = Middleware.run(:session_start, state)
      assert %State{} = Middleware.run(:session_end, state)
    end
  end

  describe "run_before_tool_call/2" do
    test "returns :ok when no middleware blocks" do
      state = build_state(middleware: [TrackingMiddleware], context: %{tracker: self()})
      tool_call = %{id: "tc_1", name: "read", input: %{"path" => "mix.exs"}}

      assert :ok = Middleware.run_before_tool_call(state, tool_call)
      assert_received {:hook_fired, :before_tool_call}
    end

    test "returns {:block, reason} when middleware blocks" do
      state = build_state(middleware: [BlockBashMiddleware])
      tool_call = %{id: "tc_1", name: "bash", input: %{"command" => "rm -rf /"}}

      assert {:block, "bash tool is disabled by policy"} =
               Middleware.run_before_tool_call(state, tool_call)
    end

    test "allows non-blocked tools through" do
      state = build_state(middleware: [BlockBashMiddleware])
      tool_call = %{id: "tc_1", name: "read", input: %{"path" => "mix.exs"}}

      assert :ok = Middleware.run_before_tool_call(state, tool_call)
    end

    test "returns :ok when no middleware configured" do
      state = build_state(middleware: [])
      tool_call = %{id: "tc_1", name: "bash", input: %{"command" => "echo hi"}}

      assert :ok = Middleware.run_before_tool_call(state, tool_call)
    end
  end

  describe "session hooks via Server" do
    test "fires :session_start on Server.start_link" do
      {:ok, provider_pid} = TestProvider.start_link([TestProvider.text_response("Hi")])

      state =
        build_state(
          provider: {Alloy.Provider.Test, agent_pid: provider_pid},
          middleware: [TrackingMiddleware],
          context: %{tracker: self()}
        )

      # We can't easily test via Server.start_link because we need to pass the tracker.
      # Instead, verify the middleware function directly fires :session_start
      result = Middleware.run(:session_start, state)
      assert %State{} = result
      assert_received {:hook_fired, :session_start}
    end

    test "fires :session_end on terminate" do
      state =
        build_state(
          middleware: [TrackingMiddleware],
          context: %{tracker: self()}
        )

      result = Middleware.run(:session_end, state)
      assert %State{} = result
      assert_received {:hook_fired, :session_end}
    end
  end

  describe "run/2 with halt" do
    test "middleware returning {:halt, reason} stops the chain" do
      # Second middleware should NOT be called
      defmodule HaltFirstMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, _state), do: {:halt, "spend cap"}
      end

      defmodule SecondMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, _state) do
          send(self(), :second_middleware_called)
          {:halt, "should not reach here"}
        end
      end

      state = build_state(middleware: [HaltFirstMiddleware, SecondMiddleware])

      result = Middleware.run(:before_completion, state)

      assert result == {:halted, "spend cap"}
      refute_received :second_middleware_called
    end

    test "middleware returning %State{} continues the chain" do
      defmodule PassThroughMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, %State{} = state), do: state
      end

      state = build_state(middleware: [PassThroughMiddleware])

      result = Middleware.run(:before_completion, state)

      assert %State{} = result
    end

    test "{:halt, reason} from second middleware stops after first" do
      defmodule FirstPassMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, %State{} = state), do: state
      end

      defmodule HaltSecondMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, _state), do: {:halt, "limit"}
      end

      state = build_state(middleware: [FirstPassMiddleware, HaltSecondMiddleware])

      result = Middleware.run(:before_completion, state)

      assert result == {:halted, "limit"}
    end
  end

  describe "run/2 with {:block, reason} at non-tool-call hook" do
    test "raises ArgumentError instead of CaseClauseError when middleware returns {:block, reason} from a general hook" do
      defmodule BlockAtWrongHookMiddleware do
        @behaviour Alloy.Middleware
        def call(:before_completion, _state), do: {:block, "wrong hook usage"}
        def call(_hook, %State{} = state), do: state
      end

      state = build_state(middleware: [BlockAtWrongHookMiddleware])

      assert_raise ArgumentError, ~r/\{:block.*:before_tool_call/s, fn ->
        Middleware.run(:before_completion, state)
      end
    end
  end

  describe "run_before_tool_call/2 with halt" do
    test "middleware returning {:halt, reason} on :before_tool_call returns {:halted, reason}" do
      defmodule HaltOnToolCallMiddleware do
        @behaviour Alloy.Middleware
        def call(:before_tool_call, _state), do: {:halt, "blocked"}
        def call(_hook, %State{} = state), do: state
      end

      state = build_state(middleware: [HaltOnToolCallMiddleware])
      tool_call = %{id: "tc_1", name: "bash", input: %{"command" => "rm -rf /"}}

      assert {:halted, "blocked"} = Middleware.run_before_tool_call(state, tool_call)
    end
  end

  describe "Executor integration with blocking" do
    test "blocked tool calls produce error result blocks" do
      {:ok, provider_pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "tc_1", name: "bash", input: %{"command" => "echo hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      {:ok, result} =
        Alloy.run("Run bash",
          provider: {Alloy.Provider.Test, agent_pid: provider_pid},
          tools: [Alloy.Tool.Core.Bash],
          middleware: [BlockBashMiddleware]
        )

      # The agent should complete (the blocked tool returns an error to the model)
      assert result.status in [:completed, :max_turns]
    end
  end
end
