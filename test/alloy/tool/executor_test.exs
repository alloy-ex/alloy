defmodule Alloy.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias Alloy.Tool.Executor

  # --- Test Tool Modules ---

  defmodule SuccessTool do
    @behaviour Alloy.Tool
    def name, do: "success"
    def description, do: "Always succeeds"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, _ctx), do: {:ok, "it worked"}
  end

  defmodule ErrorTool do
    @behaviour Alloy.Tool
    def name, do: "error_tool"
    def description, do: "Always returns error"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, _ctx), do: {:error, "something went wrong"}
  end

  defmodule CrashingTool do
    @behaviour Alloy.Tool
    def name, do: "crasher"
    def description, do: "Always crashes"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, _ctx), do: raise("boom!")
  end

  defmodule ContextTool do
    @behaviour Alloy.Tool
    def name, do: "context_checker"
    def description, do: "Returns context info"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, ctx) do
      {:ok, "wd=#{ctx[:working_directory]},custom=#{ctx[:custom_key]}"}
    end
  end

  defmodule BlockingMiddleware do
    @behaviour Alloy.Middleware

    def call(:before_tool_call, %{config: %{context: %{current_tool_call: call}}} = state) do
      if call[:name] == "success" do
        {:block, "not allowed"}
      else
        state
      end
    end

    def call(_hook, state), do: state
  end

  defmodule HaltingMiddleware do
    @behaviour Alloy.Middleware

    def call(:before_tool_call, _state), do: {:halt, "spend cap exceeded"}
    def call(_hook, state), do: state
  end

  # --- Tests ---

  describe "execute_all/3 — happy path" do
    test "executes a single tool call and returns result message" do
      state = build_state([SuccessTool])
      tool_call = %{id: "call_1", name: "success", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: blocks} = result
      assert [%{type: "tool_result", tool_use_id: "call_1", content: "it worked"}] = blocks
    end

    test "executes multiple tool calls concurrently" do
      state = build_state([SuccessTool, ErrorTool])

      calls = [
        %{id: "c1", name: "success", type: "tool_use", input: %{}},
        %{id: "c2", name: "error_tool", type: "tool_use", input: %{}}
      ]

      result = Executor.execute_all(calls, state.tool_fns, state)

      assert %Message{role: :user, content: blocks} = result
      assert length(blocks) == 2

      success_block = Enum.find(blocks, &(&1.tool_use_id == "c1"))
      error_block = Enum.find(blocks, &(&1.tool_use_id == "c2"))

      assert success_block.content == "it worked"
      assert error_block.content == "something went wrong"
      assert error_block.is_error == true
    end
  end

  describe "execute_all/3 — error handling" do
    test "returns error block for unknown tool name" do
      state = build_state([SuccessTool])
      tool_call = %{id: "call_x", name: "nonexistent", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content =~ "Unknown tool: nonexistent"
      assert block.is_error == true
    end

    test "returns error block when tool raises an exception" do
      state = build_state([CrashingTool])
      tool_call = %{id: "call_crash", name: "crasher", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content =~ "Tool crashed"
      assert block.content =~ "boom!"
      assert block.is_error == true
    end

    test "tool returning {:error, reason} produces is_error block" do
      state = build_state([ErrorTool])
      tool_call = %{id: "call_err", name: "error_tool", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content == "something went wrong"
      assert block.is_error == true
    end
  end

  describe "execute_all/3 — middleware blocking" do
    test "blocked tool returns error block without executing" do
      state = build_state([SuccessTool], middleware: [BlockingMiddleware])
      tool_call = %{id: "call_blocked", name: "success", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content =~ "Blocked: not allowed"
      assert block.is_error == true
    end

    test "non-blocked tools still execute when another is blocked" do
      state = build_state([SuccessTool, ErrorTool], middleware: [BlockingMiddleware])

      calls = [
        %{id: "c1", name: "success", type: "tool_use", input: %{}},
        %{id: "c2", name: "error_tool", type: "tool_use", input: %{}}
      ]

      result = Executor.execute_all(calls, state.tool_fns, state)

      assert %Message{role: :user, content: blocks} = result
      blocked = Enum.find(blocks, &(&1.tool_use_id == "c1"))
      executed = Enum.find(blocks, &(&1.tool_use_id == "c2"))

      assert blocked.content =~ "Blocked"
      # error_tool was NOT blocked — it ran and returned its error
      assert executed.content == "something went wrong"
    end
  end

  describe "execute_all/3 — middleware halt" do
    test "returns {:halted, reason} when middleware returns {:halt, reason} for before_tool_call" do
      state = build_state([SuccessTool], middleware: [HaltingMiddleware])
      tool_call = %{id: "call_halt", name: "success", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert result == {:halted, "spend cap exceeded"}
    end

    test "halts immediately without executing any tools when middleware halts" do
      # Use an agent to verify SuccessTool is never invoked
      test_pid = self()

      defmodule SpyTool do
        @behaviour Alloy.Tool
        def name, do: "spy"
        def description, do: "Reports invocation"
        def input_schema, do: %{type: "object", properties: %{}}

        def execute(_input, ctx) do
          send(ctx[:test_pid], :spy_tool_executed)
          {:ok, "spied"}
        end
      end

      state =
        build_state([SpyTool], middleware: [HaltingMiddleware], context: %{test_pid: test_pid})

      tool_call = %{id: "call_spy", name: "spy", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert result == {:halted, "spend cap exceeded"}
      refute_received :spy_tool_executed
    end

    test "halts on first halted call when multiple tool calls are present" do
      state = build_state([SuccessTool, ErrorTool], middleware: [HaltingMiddleware])

      calls = [
        %{id: "c1", name: "success", type: "tool_use", input: %{}},
        %{id: "c2", name: "error_tool", type: "tool_use", input: %{}}
      ]

      result = Executor.execute_all(calls, state.tool_fns, state)

      assert result == {:halted, "spend cap exceeded"}
    end
  end

  describe "execute_all/3 — context building" do
    test "passes working_directory and custom context to tools" do
      state =
        build_state([ContextTool],
          context: %{custom_key: "hello"},
          working_directory: "/test/dir"
        )

      tool_call = %{id: "c_ctx", name: "context_checker", type: "tool_use", input: %{}}

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content =~ "wd=/test/dir"
      assert block.content =~ "custom=hello"
    end
  end

  describe "execute_all/3 — configurable tool_timeout" do
    test "tool exceeding tool_timeout produces an exit" do
      state = build_state([Alloy.Test.SlowEchoTool], tool_timeout: 50)

      tool_call = %{
        id: "call_slow",
        name: "slow_echo",
        type: "tool_use",
        input: %{"text" => "hi", "sleep_ms" => 200}
      }

      # Task.async_stream with default on_timeout: :exit raises on timeout
      assert catch_exit(Executor.execute_all([tool_call], state.tool_fns, state))
    end

    test "tool_timeout defaults to 120_000 in config" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []})
      assert config.tool_timeout == 120_000
    end

    test "tool_timeout is configurable via Config.from_opts/1" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, tool_timeout: 30_000)
      assert config.tool_timeout == 30_000
    end
  end

  # --- Helpers ---

  defp build_state(tools, opts \\ []) do
    config = %Config{
      provider: Alloy.Provider.Test,
      provider_config: %{},
      tools: tools,
      middleware: Keyword.get(opts, :middleware, []),
      working_directory: Keyword.get(opts, :working_directory, "."),
      context: Keyword.get(opts, :context, %{}),
      tool_timeout: Keyword.get(opts, :tool_timeout, 120_000)
    }

    State.init(config)
  end
end
