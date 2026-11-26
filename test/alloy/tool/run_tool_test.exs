defmodule Alloy.Tool.RunToolTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.{Cancel, Events, Tool}
  alias Alloy.Tool.Executor

  defmodule EditBlockHaltMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_tool_call, state) do
      call = state.config.context.current_tool_call

      case state.config.context[:mode] do
        :edit ->
          {:edit, %{call | input: Map.put(call.input, "value", "edited")}}

        :block ->
          {:block, "blocked by policy"}

        :halt ->
          {:halt, "halted by policy"}

        _ ->
          state
      end
    end

    def call(:after_tool_call, state) do
      case state.config.context[:after_mode] do
        :rewrite ->
          res = state.config.context.current_tool_result
          {:result, %{res | content: "rewritten:" <> res.content, data: %{rewritten: true}}}

        _ ->
          state
      end
    end

    def call(_hook, state), do: state
  end

  defp inline_tool(name, execute, opts \\ []) do
    Tool.inline(
      Keyword.merge(
        [
          name: name,
          description: name,
          input_schema: %{
            type: "object",
            properties: %{value: %{type: "string"}},
            required: ["value"]
          },
          execute: execute
        ],
        opts
      )
    )
  end

  defp init_state(tools, opts \\ []) do
    Keyword.merge(
      [
        provider: {Alloy.Provider.Test, %{}},
        tools: tools
      ],
      opts
    )
    |> Config.from_opts()
    |> State.init()
  end

  describe "run_tool/3 core execution and parity" do
    test "executes a single tool with structured data, truncation, validation, and middleware" do
      echo =
        inline_tool(
          "echo",
          fn %{"value" => value}, ctx ->
            {:ok, "#{value}@#{ctx.working_directory}", %{seen: value}}
          end,
          max_result_chars: 100
        )

      state = init_state([echo], working_directory: "/tmp/work")
      call = %{id: "call_1", name: "echo", input: %{"value" => "hello"}}

      assert {:ok, block, meta} = Executor.run_tool(call, state)

      assert block == %{
               type: "tool_result",
               tool_use_id: "call_1",
               content: "hello@/tmp/work"
             }

      assert meta.id == "call_1"
      assert meta.name == "echo"
      assert meta.error == nil
      assert meta.structured_data == %{seen: "hello"}
      refute Map.has_key?(meta, :parent_call_id)

      # Required-key validation
      assert {:ok, missing_block, missing_meta} =
               Executor.run_tool(%{id: "call_2", name: "echo", input: %{}}, state)

      assert missing_block.is_error == true
      assert missing_block.content =~ "Missing required parameter"
      assert is_binary(missing_meta.error)

      # Unknown tool
      assert {:ok, unknown_block, _meta} =
               Executor.run_tool(%{id: "call_3", name: "nope", input: %{}}, state)

      assert unknown_block.is_error == true
      assert unknown_block.content =~ "Unknown tool: nope"

      # :before_tool_call edit + :after_tool_call rewrite
      mw_state =
        init_state([echo],
          middleware: [EditBlockHaltMiddleware],
          context: %{mode: :edit, after_mode: :rewrite}
        )

      assert {:ok, edited_block, edited_meta} = Executor.run_tool(call, mw_state)
      assert edited_block.content =~ "rewritten:edited@"
      assert edited_meta.structured_data == %{rewritten: true}

      # :before_tool_call block
      blocked_state =
        init_state([echo], middleware: [EditBlockHaltMiddleware], context: %{mode: :block})

      assert {:ok, blocked_block, blocked_meta} = Executor.run_tool(call, blocked_state)
      assert blocked_block.is_error == true
      assert blocked_block.content == "Blocked: blocked by policy"
      assert blocked_meta.error == "Blocked: blocked by policy"

      # :before_tool_call halt
      halted_state =
        init_state([echo], middleware: [EditBlockHaltMiddleware], context: %{mode: :halt})

      assert {:halted, "halted by policy"} = Executor.run_tool(call, halted_state)
    end

    test "supports :tool_fns override and optional JSON Schema validation" do
      override_tool =
        inline_tool("typed", fn %{"value" => value}, _ctx -> {:ok, value} end)

      state = init_state([], tool_validation: :schema)

      assert {:ok, bad_block, _meta} =
               Executor.run_tool(
                 %{id: "s1", name: "typed", input: %{"value" => 123}},
                 state,
                 tool_fns: %{"typed" => override_tool}
               )

      assert bad_block.is_error == true
      assert bad_block.content =~ "Invalid input for typed"

      assert {:ok, ok_block, _meta} =
               Executor.run_tool(
                 %{id: "s2", name: "typed", input: %{"value" => "ok"}},
                 state,
                 tool_fns: %{"typed" => override_tool}
               )

      refute Map.get(ok_block, :is_error, false)
      assert ok_block.content == "ok"
    end
  end

  describe "run_tool/3 parent_call_id events and telemetry" do
    test "attaches :parent_call_id to :tool_start, :tool_update, :tool_end, v1 envelopes, telemetry, and meta" do
      caller = self()
      handler_id = "run-tool-parent-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:alloy, :tool, :start], [:alloy, :tool, :stop]],
        fn event, _measurements, metadata, _config ->
          if metadata[:tool_id] == "child_1" do
            send(caller, {:telemetry, event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      streaming =
        inline_tool("stream_tool", fn %{"value" => val}, ctx ->
          send(caller, {:worker_pid, self()})
          ctx.on_tool_update.("chunk-1:")
          ctx.on_tool_update.(val)
          {:ok, "done"}
        end)

      state = init_state([streaming])

      event_opts =
        Events.normalize_opts(state,
          on_event: fn envelope ->
            send(caller, {:envelope, self(), envelope})
          end
        )

      assert {:ok, block, meta} =
               Executor.run_tool(
                 %{id: "child_1", name: "stream_tool", input: %{"value" => "chunk-2"}},
                 state,
                 parent_call_id: "parent_99",
                 on_event: &Events.emit(event_opts, 2, &1),
                 event_seq_ref: event_opts[:event_seq_ref],
                 event_correlation_id: event_opts[:event_correlation_id],
                 event_turn: 2
               )

      assert block.content == "done"
      assert meta.parent_call_id == "parent_99"
      assert_receive {:worker_pid, worker_pid}
      assert worker_pid != caller

      assert_receive {:envelope, ^caller,
                      %{
                        v: 1,
                        event: :tool_start,
                        payload: %{
                          id: "child_1",
                          name: "stream_tool",
                          parent_call_id: "parent_99"
                        }
                      }}

      assert_receive {:envelope, ^caller,
                      %{
                        v: 1,
                        event: :tool_update,
                        payload: %{
                          id: "child_1",
                          name: "stream_tool",
                          chunk: "chunk-1:",
                          parent_call_id: "parent_99"
                        }
                      }}

      assert_receive {:envelope, ^caller,
                      %{
                        v: 1,
                        event: :tool_update,
                        payload: %{
                          id: "child_1",
                          name: "stream_tool",
                          chunk: "chunk-2",
                          parent_call_id: "parent_99"
                        }
                      }}

      assert_receive {:envelope, ^caller,
                      %{
                        v: 1,
                        event: :tool_end,
                        payload: %{
                          id: "child_1",
                          name: "stream_tool",
                          error: nil,
                          parent_call_id: "parent_99"
                        }
                      }}

      assert_receive {:telemetry, [:alloy, :tool, :start], %{parent_call_id: "parent_99"}}
      assert_receive {:telemetry, [:alloy, :tool, :stop], %{parent_call_id: "parent_99"}}
    end
  end

  describe "run_tool/3 deadlines, timeouts, and cancellation" do
    test "respects :tool_timeout override and clamps :run_deadline to state.run_deadline" do
      slow =
        inline_tool("slow", fn _input, _ctx ->
          Process.sleep(5_000)
          {:ok, "late"}
        end)

      state = init_state([slow], tool_timeout: 5_000)
      call = %{id: "t1", name: "slow", input: %{"value" => "x"}}

      # Tighter :tool_timeout override
      assert {:ok, timeout_block, timeout_meta} =
               Executor.run_tool(call, state, tool_timeout: 40)

      assert timeout_block.is_error == true
      assert timeout_block.content =~ "timed out after 40ms"
      assert timeout_meta.error =~ "timed out after 40ms"

      # state.run_deadline cannot be loosened by a later opts[:run_deadline]
      now = System.monotonic_time(:millisecond)
      bounded_state = %{state | run_deadline: now + 40}

      assert {:ok, clamped_block, _meta} =
               Executor.run_tool(call, bounded_state, run_deadline: now + 30_000)

      assert clamped_block.is_error == true
      assert clamped_block.content =~ "run deadline"

      # Already expired deadline returns nil meta and emits zero events
      parent = self()
      expired_state = %{state | run_deadline: now - 1}

      assert {:ok, expired_block, nil} =
               Executor.run_tool(call, expired_state, on_event: &send(parent, {:ev, &1}))

      assert expired_block.is_error == true
      assert expired_block.content =~ "Not executed"
      refute_received {:ev, _}
    end

    test "honors pre-cancelled and mid-flight cooperative :cancel_token" do
      parent = self()

      # 1. Pre-cancelled skips middleware and emits zero events
      token = Cancel.new()
      Cancel.cancel(token)

      tool =
        inline_tool("work", fn _input, _ctx ->
          send(parent, :work_ran)
          {:ok, "ok"}
        end)

      state =
        init_state([tool],
          middleware: [EditBlockHaltMiddleware],
          context: %{mode: :halt}
        )

      assert {:ok, pre_block, nil} =
               Executor.run_tool(
                 %{id: "c1", name: "work", input: %{"value" => "x"}},
                 state,
                 cancel_token: token,
                 on_event: &send(parent, {:ev, &1})
               )

      assert pre_block.is_error == true
      assert pre_block.content == "Not executed: Cancelled"
      refute_received :work_ran
      refute_received {:ev, _}

      # 2. Mid-flight cancellation kills the worker promptly and pairs tool_start/tool_end
      token2 = Cancel.new()

      blocking =
        inline_tool("block_work", fn _input, _ctx ->
          send(parent, {:worker, self()})
          Process.sleep(:infinity)
        end)

      state2 = init_state([blocking])

      task =
        Task.async(fn ->
          Executor.run_tool(
            %{id: "c2", name: "block_work", input: %{"value" => "x"}},
            state2,
            cancel_token: token2,
            on_event: &send(parent, {:mid_ev, &1})
          )
        end)

      assert_receive {:worker, worker_pid}, 2_000
      mon = Process.monitor(worker_pid)
      Cancel.cancel(token2)

      assert {:ok, cancel_block, cancel_meta} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^mon, :process, ^worker_pid, _reason}, 1_000
      assert cancel_block.is_error == true
      assert cancel_block.content =~ "was cancelled"
      assert cancel_meta.error =~ "was cancelled"
      assert_receive {:mid_ev, {:tool_start, %{id: "c2"}}}
      assert_receive {:mid_ev, {:tool_end, %{id: "c2"}}}
    end

    test "validates option shapes on invalid inputs" do
      state = init_state([])
      call = %{id: "v1", name: "x", input: %{}}

      assert_raise ArgumentError, ~r/:tool_fns/, fn ->
        Executor.run_tool(call, state, tool_fns: [:bad])
      end

      assert_raise ArgumentError, ~r/:tool_timeout/, fn ->
        Executor.run_tool(call, state, tool_timeout: 0)
      end

      assert_raise ArgumentError, ~r/:run_deadline/, fn ->
        Executor.run_tool(call, state, run_deadline: "soon")
      end

      assert_raise ArgumentError, ~r/:cancel_token/, fn ->
        Executor.run_tool(call, state, cancel_token: :not_a_token)
      end

      assert_raise ArgumentError, ~r/:parent_call_id/, fn ->
        Executor.run_tool(call, state, parent_call_id: "")
      end

      assert_raise ArgumentError, ~r/:on_event/, fn ->
        Executor.run_tool(call, state, on_event: :not_a_fn)
      end
    end
  end
end
