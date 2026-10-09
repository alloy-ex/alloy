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

  defmodule StructuredTool do
    @behaviour Alloy.Tool
    @impl true
    def name, do: "structured"
    @impl true
    def description, do: "Returns structured data alongside text"
    @impl true
    def input_schema, do: %{type: "object", properties: %{}}

    @impl true
    def execute(_input, _ctx) do
      {:ok, "Found 2 agents", %{agents: [%{name: "atlas"}, %{name: "researcher"}]}}
    end

    @impl true
    def allowed_callers, do: [:human, :code_execution]

    @impl true
    def result_type, do: :structured
  end

  defmodule StrictEchoTool do
    @behaviour Alloy.Tool
    def name, do: "strict_echo"
    def description, do: "Echoes text"

    def input_schema,
      do: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]}

    def execute(%{"text" => text}, _ctx), do: {:ok, "echo #{text}"}
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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Executor.execute_all([tool_call], state.tool_fns, state)

          assert %Message{role: :user, content: [block]} = result
          assert block.content =~ "Tool crasher crashed: boom!"
          assert block.content =~ "CrashingTool.execute/2"
          assert block.content =~ "Check the input and try again."
          refute block.content =~ "\n"
          refute block.content =~ "lib/alloy"
          assert block.is_error == true
        end)

      assert log =~ "Tool crasher crashed: boom!"
      assert log =~ "CrashingTool.execute/2"
      assert log =~ "lib/alloy/tool/executor.ex"
    end

    test "exception telemetry keeps full stacktrace while model-visible result is short" do
      state = build_state([CrashingTool])
      tool_call = %{id: "call_crash", name: "crasher", type: "tool_use", input: %{}}
      test_pid = self()

      stop_handler_id = "tool-error-telemetry-#{inspect(make_ref())}"

      :telemetry.attach(
        stop_handler_id,
        [:alloy, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:tool_stop, metadata})
        end,
        nil
      )

      try do
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %Message{role: :user, content: [block]}, [_meta]} =
                   Executor.execute_all([tool_call], state.tool_fns, state,
                     on_event: fn _ -> :ok end
                   )

          refute block.content =~ "\n"
        end)

        assert_receive {:tool_stop, %{tool_name: "crasher", error: error}}
        assert error =~ "boom!"
        assert error =~ "lib/alloy/tool/executor.ex"
      after
        :telemetry.detach(stop_handler_id)
      end
    end

    for concurrent? <- [true, false], {kind, crash} <- [exit: :exit, throw: :throw] do
      @tag capture_log: true
      test "#{kind} in a #{if concurrent?, do: "concurrent", else: "sequential"} tool becomes an error result" do
        crash =
          case unquote(crash) do
            :exit -> fn _input, _ctx -> exit(:boom) end
            :throw -> fn _input, _ctx -> throw(:boom) end
          end

        tool =
          Alloy.Tool.inline(
            name: "crash",
            description: "crashes",
            input_schema: %{type: "object", properties: %{}},
            concurrent?: unquote(concurrent?),
            execute: crash
          )

        state = build_state([tool])
        call = %{id: "c_crash", name: "crash", type: "tool_use", input: %{}}

        assert %Message{content: [block]} = Executor.execute_all([call], state.tool_fns, state)
        assert block.tool_use_id == "c_crash"
        assert block.is_error == true
        assert block.content =~ "Tool crash crashed"
        assert block.content =~ ":boom"
      end
    end

    test "tool_timeout applies to sequential tools" do
      tool =
        Alloy.Tool.inline(
          name: "slow_seq",
          description: "sleeps",
          input_schema: %{type: "object", properties: %{}},
          concurrent?: false,
          execute: fn _input, _ctx ->
            Process.sleep(2_000)
            {:ok, "finished"}
          end
        )

      state = build_state([tool], tool_timeout: 50)
      call = %{id: "c_slow_seq", name: "slow_seq", type: "tool_use", input: %{}}

      {elapsed_us, result} =
        :timer.tc(fn -> Executor.execute_all([call], state.tool_fns, state) end)

      assert %Message{content: [block]} = result
      assert block.is_error == true

      assert block.content ==
               "Tool slow_seq timed out after 50ms. Try a smaller input or raise :tool_timeout."

      assert elapsed_us < 1_000_000
    end

    test "invalid UTF-8 in a result is replaced so the transcript stays encodable" do
      bytes = <<"ok ", 0xFF, 0xFE, " end">>

      tools =
        for {name, result} <- [{"bad_ok", {:ok, bytes}}, {"bad_err", {:error, bytes}}] do
          Alloy.Tool.inline(
            name: name,
            description: name,
            input_schema: %{type: "object", properties: %{}},
            execute: fn _input, _ctx -> result end
          )
        end

      state = build_state(tools)

      calls = [
        %{id: "c_ok", name: "bad_ok", type: "tool_use", input: %{}},
        %{id: "c_err", name: "bad_err", type: "tool_use", input: %{}}
      ]

      assert {:ok, %Message{content: [ok, err]} = msg, [_ok_meta, err_meta]} =
               Executor.execute_all(calls, state.tool_fns, state, [])

      assert ok.content == "ok �� end"
      assert err.content == "ok �� end"
      assert err.is_error
      assert String.valid?(err_meta.error)
      assert {:ok, _json} = Jason.encode(msg.content)
    end

    @tag :tmp_dir
    test "reading a non-UTF-8 text file does not poison the transcript", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "latin1.txt")
      File.write!(path, <<"caf", 0xE9, "\n">>)
      state = build_state([Alloy.Tool.Core.Read])
      call = %{id: "c_read", name: "read", type: "tool_use", input: %{"file_path" => path}}

      assert %Message{content: [block]} = Executor.execute_all([call], state.tool_fns, state)
      assert block.content =~ "caf�"
      assert {:ok, _json} = Jason.encode(block)
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

  describe "execute_all/3 — input validation" do
    test "missing required keys are an error result naming them, not a crash" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {block, meta} = run_one(StrictEchoTool, %{"other" => 1})

          assert block.is_error
          assert block.content =~ "Missing required parameter"
          assert block.content =~ "text"
          assert meta.error == block.content
        end)

      refute log =~ "FunctionClauseError"
    end

    test "required keys may be atoms or strings in the schema, and in the input" do
      atom_schema = inline_with_schema(%{type: "object", required: [:a, "b"]})
      string_schema = inline_with_schema(%{"type" => "object", "required" => ["a", "b"]})

      for tool <- [atom_schema, string_schema] do
        assert {%{is_error: true, content: content}, _} = run_one(tool, %{"a" => 1})
        assert content =~ ": b."

        for input <- [%{"a" => 1, "b" => 2}, %{"a" => 1, b: 2}] do
          assert {block, %{error: nil}} = run_one(tool, input)
          refute Map.has_key?(block, :is_error)
        end
      end
    end

    test "input that is not an object is an error result" do
      {block, _meta} = run_one(StrictEchoTool, "just a string")

      assert block.is_error
      assert block.content =~ "must be a JSON object"
    end

    test "types are not checked, so loose schemas keep working" do
      tool = inline_with_schema(%{type: "object", required: ["n"]})

      assert {block, _} = run_one(tool, %{"n" => "not a number", "extra" => true})
      refute Map.get(block, :is_error)
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
    test "tool exceeding tool_timeout returns error with original tool_use_id" do
      state = build_state([Alloy.Test.SlowEchoTool], tool_timeout: 50)

      tool_call = %{
        id: "call_slow",
        name: "slow_echo",
        type: "tool_use",
        input: %{"text" => "hi", "sleep_ms" => 200}
      }

      result = Executor.execute_all([tool_call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.tool_use_id == "call_slow"

      assert block.content ==
               "Tool slow_echo timed out after 50ms. Try a smaller input or raise :tool_timeout."

      assert block.is_error == true
    end

    test "multiple tools where one times out preserves all tool_use_ids" do
      state = build_state([SuccessTool, Alloy.Test.SlowEchoTool], tool_timeout: 50)

      calls = [
        %{id: "c_fast", name: "success", type: "tool_use", input: %{}},
        %{
          id: "c_slow",
          name: "slow_echo",
          type: "tool_use",
          input: %{"text" => "hi", "sleep_ms" => 200}
        }
      ]

      result = Executor.execute_all(calls, state.tool_fns, state)

      assert %Message{role: :user, content: blocks} = result
      assert length(blocks) == 2

      fast_block = Enum.find(blocks, &(&1.tool_use_id == "c_fast"))
      slow_block = Enum.find(blocks, &(&1.tool_use_id == "c_slow"))

      assert fast_block.content == "it worked"
      assert slow_block.tool_use_id == "c_slow"
      assert slow_block.is_error == true
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

  describe "execute_all/4 — structured results (3-tuple)" do
    test "tool returning {ok, text, data} puts text in result block and data in metadata" do
      state = build_state([StructuredTool])
      call = %{id: "call_s", name: "structured", type: "tool_use", input: %{}}

      assert {:ok, %Message{role: :user, content: [block]}, [meta]} =
               Executor.execute_all([call], state.tool_fns, state, on_event: fn _ -> :ok end)

      # Text goes into the tool_result block (what the model sees)
      assert block.tool_use_id == "call_s"
      assert block.content == "Found 2 agents"
      refute Map.get(block, :is_error)

      # Structured data goes into metadata
      assert meta.id == "call_s"
      assert meta.name == "structured"
      assert meta.error == nil
      assert meta.structured_data == %{agents: [%{name: "atlas"}, %{name: "researcher"}]}
    end

    test "tool returning {ok, text} 2-tuple has no structured_data in metadata" do
      state = build_state([SuccessTool])
      call = %{id: "call_plain", name: "success", type: "tool_use", input: %{}}

      assert {:ok, %Message{role: :user, content: [block]}, [meta]} =
               Executor.execute_all([call], state.tool_fns, state, on_event: fn _ -> :ok end)

      assert block.content == "it worked"
      refute Map.has_key?(meta, :structured_data)
    end

    test "mixed tools — structured and plain — both work in same batch" do
      state = build_state([SuccessTool, StructuredTool])

      calls = [
        %{id: "c_plain", name: "success", type: "tool_use", input: %{}},
        %{id: "c_structured", name: "structured", type: "tool_use", input: %{}}
      ]

      assert {:ok, %Message{role: :user, content: blocks}, metas} =
               Executor.execute_all(calls, state.tool_fns, state, on_event: fn _ -> :ok end)

      assert length(blocks) == 2
      assert length(metas) == 2

      plain_meta = Enum.find(metas, &(&1.id == "c_plain"))
      structured_meta = Enum.find(metas, &(&1.id == "c_structured"))

      refute Map.has_key?(plain_meta, :structured_data)

      assert structured_meta.structured_data == %{
               agents: [%{name: "atlas"}, %{name: "researcher"}]
             }
    end
  end

  describe "execute_all/4 — events and metadata" do
    test "emits tool_start/tool_end and returns tool metadata" do
      state = build_state([SuccessTool])
      call = %{id: "call_1", name: "success", type: "tool_use", input: %{"x" => 1}}

      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end
      seq_ref = :atomics.new(1, signed: false)

      assert {:ok, %Message{role: :user, content: [block]}, [meta]} =
               Executor.execute_all([call], state.tool_fns, state,
                 on_event: on_event,
                 event_seq_ref: seq_ref,
                 event_correlation_id: "corr-1",
                 event_turn: 5
               )

      assert block.tool_use_id == "call_1"
      assert block.content == "it worked"

      assert meta.id == "call_1"
      assert meta.name == "success"
      assert meta.input == %{"x" => 1}
      assert meta.error == nil
      assert meta.correlation_id == "corr-1"
      assert is_integer(meta.duration_ms)
      assert meta.duration_ms >= 0
      assert is_integer(meta.start_event_seq)
      assert is_integer(meta.end_event_seq)
      assert meta.end_event_seq > meta.start_event_seq

      assert_received {:event,
                       {:tool_start,
                        %{
                          id: "call_1",
                          name: "success",
                          input: %{"x" => 1},
                          event_seq: 1,
                          correlation_id: "corr-1"
                        }}}

      assert_received {:event,
                       {:tool_end,
                        %{
                          id: "call_1",
                          name: "success",
                          input: %{"x" => 1},
                          event_seq: 2,
                          start_event_seq: 1,
                          correlation_id: "corr-1",
                          duration_ms: _,
                          error: nil
                        }}}
    end

    test "blocked tools emit tool_start/tool_end with error metadata" do
      state = build_state([SuccessTool], middleware: [BlockingMiddleware])
      call = %{id: "blocked_1", name: "success", type: "tool_use", input: %{}}

      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end
      seq_ref = :atomics.new(1, signed: false)

      assert {:ok, %Message{role: :user, content: [block]}, [meta]} =
               Executor.execute_all([call], state.tool_fns, state,
                 on_event: on_event,
                 event_seq_ref: seq_ref,
                 event_correlation_id: "corr-blocked",
                 event_turn: 2
               )

      assert block.tool_use_id == "blocked_1"
      assert block.is_error == true
      assert block.content =~ "Blocked: not allowed"

      assert meta.id == "blocked_1"
      assert meta.name == "success"
      assert meta.error == "Blocked: not allowed"
      assert meta.correlation_id == "corr-blocked"
      assert meta.start_event_seq == 1
      assert meta.end_event_seq == 2

      assert_received {:event,
                       {:tool_start,
                        %{
                          id: "blocked_1",
                          name: "success",
                          input: %{},
                          event_seq: 1,
                          correlation_id: "corr-blocked"
                        }}}

      assert_received {:event,
                       {:tool_end,
                        %{
                          id: "blocked_1",
                          name: "success",
                          input: %{},
                          event_seq: 2,
                          start_event_seq: 1,
                          correlation_id: "corr-blocked",
                          duration_ms: _,
                          error: "Blocked: not allowed"
                        }}}
    end

    test "a timed-out tool's tool_end pairs with its tool_start and carries the real duration" do
      state = build_state([Alloy.Test.SlowEchoTool], tool_timeout: 50)

      call = %{
        id: "c_slow",
        name: "slow_echo",
        type: "tool_use",
        input: %{"text" => "hi", "sleep_ms" => 1_000}
      }

      test_pid = self()
      handler_id = "tool-timeout-telemetry-#{inspect(make_ref())}"

      :telemetry.attach(
        handler_id,
        [:alloy, :tool, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_stop, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:ok, %Message{content: [%{is_error: true}]}, [meta]} =
                 Executor.execute_all([call], state.tool_fns, state,
                   on_event: fn event -> send(test_pid, {:event, event}) end
                 )

        assert_received {:event, {:tool_start, %{id: "c_slow", event_seq: start_seq}}}

        assert_received {:event,
                         {:tool_end, %{id: "c_slow", start_event_seq: ^start_seq} = tool_end}}

        assert tool_end.duration_ms >= 50
        assert meta.start_event_seq == start_seq
        assert meta.duration_ms >= 50

        assert_received {:tool_stop, %{duration_ms: duration_ms},
                         %{tool_id: "c_slow", start_event_seq: ^start_seq}}

        assert duration_ms >= 50
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits telemetry envelope with correlation and ordered sequence" do
      state = build_state([SuccessTool])
      call = %{id: "call_telemetry", name: "success", type: "tool_use", input: %{}}
      seq_ref = :atomics.new(1, signed: false)
      correlation = "corr-telemetry"
      test_pid = self()

      start_handler_id = "test-tool-start-#{inspect(make_ref())}"
      stop_handler_id = "test-tool-stop-#{inspect(make_ref())}"

      :telemetry.attach(
        start_handler_id,
        [:alloy, :tool, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        stop_handler_id,
        [:alloy, :tool, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:ok, %Message{}, [_meta]} =
                 Executor.execute_all([call], state.tool_fns, state,
                   event_seq_ref: seq_ref,
                   event_correlation_id: correlation,
                   event_turn: 9
                 )

        assert_receive {:telemetry_event, [:alloy, :tool, :start], %{event_seq: 1},
                        %{
                          correlation_id: ^correlation,
                          turn: 9,
                          tool_id: "call_telemetry",
                          tool_name: "success"
                        }}

        assert_receive {:telemetry_event, [:alloy, :tool, :stop],
                        %{event_seq: 2, duration_ms: _duration_ms},
                        %{
                          correlation_id: ^correlation,
                          turn: 9,
                          tool_id: "call_telemetry",
                          tool_name: "success",
                          start_event_seq: 1,
                          error: nil
                        }}
      after
        :telemetry.detach(start_handler_id)
        :telemetry.detach(stop_handler_id)
      end
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

  defp inline_with_schema(schema) do
    Alloy.Tool.inline(
      name: "schema_tool",
      description: "Returns its input",
      input_schema: schema,
      execute: fn input, _ctx -> {:ok, inspect(input)} end
    )
  end

  defp run_one(%Alloy.Tool.Inline{name: name} = tool, input), do: run_one(tool, name, input)
  defp run_one(tool, input), do: run_one(tool, tool.name(), input)

  defp run_one(tool, name, input) do
    state = build_state([tool])
    call = %{id: "c1", name: name, input: input}

    {:ok, %Message{content: [block]}, [meta]} =
      Executor.execute_all([call], state.tool_fns, state, [])

    {block, meta}
  end

  # Each call logs {:start, id} and {:done, id} so the tests can see what
  # overlapped. A sequential tool must observe everything the model asked
  # for before it, and nothing it asked for after it.
  defp logging_tool(name, log, concurrent?) do
    Alloy.Tool.inline(
      name: name,
      description: name,
      input_schema: %{type: "object", properties: %{}},
      concurrent?: concurrent?,
      execute: fn %{"id" => id}, _ctx ->
        Agent.update(log, &[{:start, id} | &1])
        Process.sleep(30)
        Agent.update(log, &[{:done, id} | &1])
        {:ok, id}
      end
    )
  end

  defp run_logged(names) do
    {:ok, log} = Agent.start_link(fn -> [] end)
    state = build_state([logging_tool("par", log, true), logging_tool("seq", log, false)])

    calls =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, i} ->
        id = "#{name}#{i}"
        %{id: id, name: name, type: "tool_use", input: %{"id" => id}}
      end)

    %Message{content: blocks} = Executor.execute_all(calls, state.tool_fns, state)
    assert Enum.map(blocks, & &1.tool_use_id) == Enum.map(calls, & &1.id)

    log |> Agent.get(& &1) |> Enum.reverse()
  end

  # --- Test Tools for max_result_chars ---

  defmodule VerboseTool do
    @behaviour Alloy.Tool
    def name, do: "verbose"
    def description, do: "Returns lots of text"
    def input_schema, do: %{type: "object", properties: %{}}
    def max_result_chars, do: 100
    def execute(_input, _ctx), do: {:ok, String.duplicate("x", 500)}
  end

  defmodule UnlimitedTool do
    @behaviour Alloy.Tool
    def name, do: "unlimited"
    def description, do: "Returns text with unlimited result"
    def input_schema, do: %{type: "object", properties: %{}}
    def max_result_chars, do: :unlimited
    def execute(_input, _ctx), do: {:ok, String.duplicate("y", 500)}
  end

  # --- Test Tools for concurrent? ---

  defmodule SequentialTool do
    @behaviour Alloy.Tool
    def name, do: "sequential"
    def description, do: "Not concurrency safe"
    def input_schema, do: %{type: "object", properties: %{}}
    def concurrent?, do: false

    def execute(_input, _ctx) do
      ts = System.monotonic_time(:millisecond)
      Process.sleep(30)
      {:ok, "seq:#{ts}"}
    end
  end

  defmodule ParallelTool do
    @behaviour Alloy.Tool
    def name, do: "parallel"
    def description, do: "Concurrency safe (default)"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, _ctx) do
      ts = System.monotonic_time(:millisecond)
      Process.sleep(30)
      {:ok, "par:#{ts}"}
    end
  end

  describe "execute_all — max_result_chars truncation" do
    test "truncates results exceeding max_result_chars" do
      state = build_state([VerboseTool])
      call = %{id: "c_verbose", name: "verbose", type: "tool_use", input: %{}}

      result = Executor.execute_all([call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert String.length(block.content) < 200
      assert block.content =~ "[truncated"
    end

    test "tools without max_result_chars return full content" do
      state = build_state([SuccessTool])
      call = %{id: "c_full", name: "success", type: "tool_use", input: %{}}

      result = Executor.execute_all([call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert block.content == "it worked"
    end

    test "tools with max_result_chars :unlimited return full content" do
      state = build_state([UnlimitedTool])
      call = %{id: "c_unlim", name: "unlimited", type: "tool_use", input: %{}}

      result = Executor.execute_all([call], state.tool_fns, state)

      assert %Message{role: :user, content: [block]} = result
      assert String.length(block.content) == 500
    end
  end

  describe "execute_all — cancellation" do
    # A runtime cancelling a request kills the turn outright; tool tasks are unlinked
    # (so a crashing tool can't take the turn down) and must still stop.
    test "killing the caller stops its in-flight tool tasks" do
      test_pid = self()

      tool =
        Alloy.Tool.inline(
          name: "slow",
          description: "Reports its pid, then blocks",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _input, _ctx ->
            send(test_pid, {:tool_pid, self()})
            Process.sleep(10_000)
            {:ok, "too late"}
          end
        )

      state = build_state([tool])
      calls = [%{id: "c1", name: "slow", input: %{}}, %{id: "c2", name: "slow", input: %{}}]

      caller =
        spawn(fn ->
          Executor.execute_all(calls, state.tool_fns, state, on_event: fn _ -> :ok end)
        end)

      assert_receive {:tool_pid, tool_a}, 1_000
      assert_receive {:tool_pid, tool_b}, 1_000
      refs = Enum.map([tool_a, tool_b], &Process.monitor/1)

      Process.exit(caller, :kill)

      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)
    end
  end

  describe "execute_all — execution order" do
    test "a sequential call runs after the concurrent calls the model made before it" do
      # e.g. [read f, edit f] must read the file before editing it
      assert run_logged(["par", "seq"]) ==
               [{:start, "par1"}, {:done, "par1"}, {:start, "seq2"}, {:done, "seq2"}]
    end

    test "concurrent calls after a sequential call wait for it" do
      log = run_logged(["par", "seq", "par"])

      assert Enum.take(log, 2) == [{:start, "par1"}, {:done, "par1"}]
      assert Enum.slice(log, 2, 2) == [{:start, "seq2"}, {:done, "seq2"}]
      assert Enum.drop(log, 4) == [{:start, "par3"}, {:done, "par3"}]
    end

    test "consecutive concurrent calls still run in parallel" do
      log = run_logged(["seq", "par", "par", "seq"])

      assert Enum.take(log, 2) == [{:start, "seq1"}, {:done, "seq1"}]
      assert log |> Enum.slice(2, 2) |> Enum.sort() == [{:start, "par2"}, {:start, "par3"}]
      assert Enum.take(log, -2) == [{:start, "seq4"}, {:done, "seq4"}]
    end

    # 0.12.4 ran concurrent calls through async_stream's default cap; a model
    # that fans out dozens of calls must not start them all at once.
    test "a large concurrent batch runs at most schedulers_online at a time" do
      cap = System.schedulers_online()
      running = :atomics.new(2, signed: true)

      tool =
        Alloy.Tool.inline(
          name: "counted",
          description: "Tracks how many copies run at once",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _input, _ctx ->
            now = :atomics.add_get(running, 1, 1)
            # Record the peak with a compare-and-swap loop.
            peak = fn peak ->
              seen = :atomics.get(running, 2)

              if now > seen and :atomics.compare_exchange(running, 2, seen, now) != :ok,
                do: peak.(peak)
            end

            peak.(peak)
            Process.sleep(30)
            :atomics.sub(running, 1, 1)
            {:ok, "done"}
          end
        )

      state = build_state([tool])
      calls = for i <- 1..(cap + 4), do: %{id: "c#{i}", name: "counted", input: %{}}

      assert {:ok, %Message{content: blocks}, _meta} =
               Executor.execute_all(calls, state.tool_fns, state, on_event: fn _ -> :ok end)

      assert length(blocks) == cap + 4
      assert :atomics.get(running, 2) <= cap
    end

    test "result order matches original call order" do
      state = build_state([ParallelTool, SequentialTool])

      calls = [
        %{id: "c1", name: "parallel", type: "tool_use", input: %{}},
        %{id: "c2", name: "sequential", type: "tool_use", input: %{}},
        %{id: "c3", name: "parallel", type: "tool_use", input: %{}}
      ]

      assert {:ok, %Message{role: :user, content: blocks}, _meta} =
               Executor.execute_all(calls, state.tool_fns, state, on_event: fn _ -> :ok end)

      ids = Enum.map(blocks, & &1.tool_use_id)
      assert ids == ["c1", "c2", "c3"]
    end
  end
end
