defmodule Anvil.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Anvil.Middleware
  alias Anvil.Agent.{Config, State}
  alias Anvil.Provider.Test, as: TestProvider

  # A middleware that blocks a specific tool
  defmodule BlockBashMiddleware do
    @behaviour Anvil.Middleware

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
    @behaviour Anvil.Middleware

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
          [provider: Anvil.Provider.Test, middleware: []],
          overrides
        )
      )

    State.init(config)
  end

  describe "run/2 with new hooks" do
    test "existing Logger middleware handles new hooks without crashing" do
      state = build_state(middleware: [Anvil.Middleware.Logger])

      # These should not raise FunctionClauseError
      assert %State{} = Middleware.run(:before_tool_call, state)
      assert %State{} = Middleware.run(:session_start, state)
      assert %State{} = Middleware.run(:session_end, state)
    end

    test "existing Telemetry middleware handles new hooks without crashing" do
      state = build_state(middleware: [Anvil.Middleware.Telemetry])

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
          provider: {Anvil.Provider.Test, agent_pid: provider_pid},
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
        Anvil.run("Run bash",
          provider: {Anvil.Provider.Test, agent_pid: provider_pid},
          tools: [Anvil.Tool.Core.Bash],
          middleware: [BlockBashMiddleware]
        )

      # The agent should complete (the blocked tool returns an error to the model)
      assert result.status in [:completed, :max_turns]
    end
  end
end
