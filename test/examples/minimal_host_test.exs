Code.require_file("../../examples/minimal_host/code_mode.exs", __DIR__)
Code.require_file("../../examples/minimal_host/output_capture.exs", __DIR__)

defmodule MinimalHostTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Cancel
  alias MinimalHost.{CodeMode, OutputCapture}

  defmodule Policy do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_tool_call, state) do
      if state.config.context.current_tool_call.name == "write",
        do: {:block, "read only"},
        else: state
    end

    def call(:after_tool_execution, state) do
      send(state.config.context.test_pid, :after_children)
      state
    end

    def call(:after_tool_call, state) do
      if pid = state.config.context[:after_tool_call_pid] do
        send(pid, {:after_tool_call, state.config.context.current_tool_call.id})
      end

      state
    end

    def call(_hook, state), do: state
  end

  defp tool(name, execute, opts \\ []) do
    Alloy.Tool.inline(
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

  defp state(tools) do
    Config.from_opts(
      provider: {Alloy.Provider.Test, %{}},
      tools: tools,
      middleware: [Policy],
      context: %{test_pid: self()}
    )
    |> State.init()
  end

  defp opts, do: [timeout: 5_000, max_calls: 8, parent_call_id: "script-1"]

  test "nested calls retain validation, policy, structured data, hooks and parent events" do
    parent = self()

    execute = fn input, _context ->
      send(parent, {:executed, input})
      {:ok, "visible", %{value: input["value"]}}
    end

    initial = state([tool("read", execute), tool("write", execute)])

    program = fn dispatch ->
      dispatch.([
        %{name: "write", input: %{"value" => "blocked"}},
        %{name: "read", input: %{}},
        %{name: "read", input: %{"value" => "allowed"}}
      ])
    end

    assert {:ok, result} =
             CodeMode.run(
               program,
               initial,
               Keyword.put(opts(), :on_event, &send(parent, {:event, &1}))
             )

    assert Enum.at(result.results, 0).is_error
    assert Enum.at(result.results, 1).is_error
    assert Enum.at(result.metadata, 2).structured_data == %{value: "allowed"}
    assert_receive {:executed, %{"value" => "allowed"}}
    refute_received {:executed, _input}
    assert_receive :after_children
    assert_receive {:event, {:tool_start, %{parent_call_id: "script-1", id: "script-1-1"}}}
    assert_receive {:event, {:tool_end, %{parent_call_id: "script-1", id: "script-1-3"}}}
  end

  test "single-call dispatch routes through Executor.run_tool/3 with native parent_call_id" do
    parent = self()

    execute = fn input, ctx ->
      if ctx[:on_tool_update], do: ctx.on_tool_update.("step:" <> input["value"])
      {:ok, "single:" <> input["value"], %{single: true}}
    end

    initial = state([tool("read", execute)])

    program = fn dispatch ->
      dispatch.(%{name: "read", input: %{"value" => "one"}})
    end

    assert {:ok, %{result: result, metadata: meta}} =
             CodeMode.run(
               program,
               initial,
               Keyword.put(opts(), :on_event, &send(parent, {:event, &1}))
             )

    refute Map.get(result, :is_error, false)
    assert result.content == "single:one"
    assert meta.parent_call_id == "script-1"
    assert meta.structured_data == %{single: true}
    assert_receive {:event, {:tool_start, %{parent_call_id: "script-1", id: "script-1-1"}}}

    assert_receive {:event,
                    {:tool_update,
                     %{parent_call_id: "script-1", id: "script-1-1", chunk: "step:one"}}}

    assert_receive {:event, {:tool_end, %{parent_call_id: "script-1", id: "script-1-1"}}}
  end

  test "sequential child calls remain ordered" do
    parent = self()

    sequential =
      tool(
        "ordered",
        fn input, _context ->
          send(parent, {:ordered, input["value"]})
          {:ok, "ok"}
        end,
        concurrent?: false
      )

    program = fn dispatch ->
      dispatch.([
        %{name: "ordered", input: %{"value" => "first"}},
        %{name: "ordered", input: %{"value" => "second"}}
      ])
    end

    assert {:ok, _result} = CodeMode.run(program, state([sequential]), opts())
    assert_receive {:ordered, "first"}
    assert_receive {:ordered, "second"}
  end

  test "recursive scripts are unavailable and total calls are bounded" do
    script = tool("run_script", fn _input, _context -> flunk("recursive execution") end)
    call = %{name: "run_script", input: %{"value" => "recursive"}}

    assert {:ok, %{results: [result]}} =
             CodeMode.run(fn dispatch -> dispatch.([call]) end, state([script]), opts())

    assert result.is_error
    assert result.content =~ "Unknown tool"

    assert {:error, {:throw, :call_limit}} =
             CodeMode.run(
               fn dispatch -> dispatch.([call, call]) end,
               state([script]),
               Keyword.put(opts(), :max_calls, 1)
             )
  end

  test "cancelling the outer caller stops nested execution and pending sequential calls" do
    parent = self()

    slow =
      tool(
        "slow",
        fn _input, _context ->
          send(parent, {:child, self()})
          Process.sleep(:infinity)
        end,
        concurrent?: false
      )

    program = fn dispatch ->
      dispatch.([
        %{name: "slow", input: %{"value" => "first"}},
        %{name: "slow", input: %{"value" => "pending"}}
      ])
    end

    initial = state([slow])
    caller = spawn(fn -> CodeMode.run(program, initial, opts()) end)
    assert_receive {:child, child}
    monitor = Process.monitor(child)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
    refute_receive {:child, _pending}, 100
  end

  @tag :tmp_dir
  test "producer capture preserves the middle, bounds previews and uses private unique files", %{
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)

    chunks =
      Stream.concat([
        Stream.repeatedly(fn -> String.duplicate("x", 4096) end) |> Stream.take(20),
        ["middle-evidence"],
        [String.duplicate("y", 4096)]
      ])

    options = [max_bytes: 100_000, preview_bytes: 128]
    assert {:ok, first} = OutputCapture.capture(chunks, dir, options)
    assert {:ok, second} = OutputCapture.capture(["other"], dir, options)
    assert first.path != second.path
    assert byte_size(first.preview) == 128
    assert File.read!(first.path) =~ "middle-evidence"
    assert Bitwise.band(File.stat!(first.path).mode, 0o777) == 0o600
    assert byte_size(File.read!(first.path)) == first.bytes
  end

  @tag :tmp_dir
  test "quota stops the producer and removes partial output", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    producer =
      Stream.map(1..100, fn index ->
        send(self(), {:produced, index})
        "abcd"
      end)

    assert {:error, :output_limit} =
             OutputCapture.capture(producer, dir, max_bytes: 5, preview_bytes: 2)

    assert File.ls!(dir) == []
    assert_receive {:produced, 1}
    assert_receive {:produced, 2}
    refute_received {:produced, 3}
  end

  @tag :tmp_dir
  test "refuses public and symlinked output directories", %{tmp_dir: dir} do
    File.chmod!(dir, 0o755)

    assert {:error, :directory_not_private} =
             OutputCapture.capture([], dir, max_bytes: 5, preview_bytes: 2)

    private = Path.join(dir, "private")
    File.mkdir!(private)
    File.chmod!(private, 0o700)
    link = Path.join(dir, "link")
    File.ln_s!(private, link)

    assert {:error, :not_a_directory} =
             OutputCapture.capture([], link, max_bytes: 5, preview_bytes: 2)
  end

  test "the interpreter timeout cancels running children" do
    parent = self()

    slow =
      tool("slow", fn _input, _context ->
        send(parent, {:timed_child, self()})
        Process.sleep(:infinity)
      end)

    assert {:error, :timeout} =
             CodeMode.run(
               fn dispatch ->
                 dispatch.([%{name: "slow", input: %{"value" => "wait"}}])
               end,
               state([slow]),
               Keyword.put(opts(), :timeout, 500)
             )

    assert_receive {:timed_child, child}
    monitor = Process.monitor(child)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
  end

  test "interpreter timeout is terminal even if the program ignores the child timeout result" do
    parent = self()

    slow =
      tool("slow", fn _input, _context ->
        send(parent, {:slow_started, self()})
        Process.sleep(:infinity)
      end)

    program = fn dispatch ->
      _ignored = dispatch.(%{name: "slow", input: %{"value" => "wait"}})
      :continued_after_timeout
    end

    assert {:error, :timeout} =
             CodeMode.run(
               program,
               state([slow]),
               Keyword.put(opts(), :timeout, 60)
             )

    assert_receive {:slow_started, child}
    monitor = Process.monitor(child)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
  end

  test "rejects empty or invalid UTF-8 parent_call_id upfront" do
    for bad_parent <- ["", <<0xFF>>] do
      assert_raise ArgumentError, ~r/non-empty UTF-8 parent_call_id/, fn ->
        CodeMode.run(
          fn _dispatch -> :ok end,
          state([]),
          Keyword.put(opts(), :parent_call_id, bad_parent)
        )
      end
    end
  end

  test "clamps interpreter timeout to tighter outer state.run_deadline" do
    parent = self()

    slow =
      tool("slow", fn _input, _context ->
        send(parent, {:bounded_child, self()})
        Process.sleep(:infinity)
      end)

    program = fn dispatch ->
      _ignored = dispatch.(%{name: "slow", input: %{"value" => "wait"}})
      :should_not_succeed
    end

    now = System.monotonic_time(:millisecond)
    bounded_state = %{state([slow]) | run_deadline: now + 60}

    {elapsed_us, result} =
      :timer.tc(fn ->
        CodeMode.run(program, bounded_state, Keyword.put(opts(), :timeout, 5_000))
      end)

    assert result == {:error, :timeout}
    assert elapsed_us < 1_500_000
    assert_receive {:bounded_child, child}
    monitor = Process.monitor(child)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000

    # Pre-expired outer run_deadline returns {:error, :timeout} immediately without running program
    expired_state = %{state([slow]) | run_deadline: now - 1}

    assert {:error, :timeout} =
             CodeMode.run(fn _ -> flunk("should not run") end, expired_state, opts())
  end

  test "honors cooperative :cancel_token during child calls and between dispatches" do
    parent = self()

    # 1. Cancel during child tool execution (via state.config.cancel_token) finalizes
    #    :after_tool_call, matching :tool_end, and stop telemetry before returning :cancelled
    outer_token = Cancel.new()
    handler_id = "code-mode-cancel-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:alloy, :tool, :stop],
      fn _event, _meas, meta, _cfg ->
        if meta[:parent_call_id] == "script-cancel-1" do
          send(parent, {:tool_stop_telemetry, meta.tool_id, meta.error})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    slow =
      tool("slow", fn _input, _context ->
        send(parent, {:cancel_child, self()})
        Process.sleep(:infinity)
      end)

    state_with_cancel =
      Config.from_opts(
        provider: {Alloy.Provider.Test, %{}},
        tools: [slow],
        middleware: [Policy],
        context: %{test_pid: parent, after_tool_call_pid: parent},
        cancel_token: outer_token
      )
      |> State.init()

    task =
      Task.async(fn ->
        CodeMode.run(
          fn dispatch ->
            _ignored = dispatch.(%{name: "slow", input: %{"value" => "wait"}})
            :should_not_succeed
          end,
          state_with_cancel,
          Keyword.merge(opts(),
            parent_call_id: "script-cancel-1",
            on_event: &send(parent, {:cancel_ev, &1})
          )
        )
      end)

    assert_receive {:cancel_child, child}, 2_000
    monitor = Process.monitor(child)
    Cancel.cancel(outer_token)

    assert {:error, :cancelled} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
    assert_receive {:cancel_ev, {:tool_start, %{id: "script-cancel-1-1"}}}, 1_000
    assert_receive {:cancel_ev, {:tool_end, %{id: "script-cancel-1-1", error: err}}}, 1_000
    assert err =~ "was cancelled"
    assert_receive {:after_tool_call, "script-cancel-1-1"}, 1_000
    assert_receive {:tool_stop_telemetry, "script-cancel-1-1", stop_err}, 1_000
    assert stop_err =~ "was cancelled"

    # 2. Cancel via opts[:cancel_token] while program sleeps between dispatches
    inner_token = Cancel.new()

    task2 =
      Task.async(fn ->
        CodeMode.run(
          fn _dispatch ->
            send(parent, :between_dispatches)
            Process.sleep(5_000)
            :too_late
          end,
          state([]),
          Keyword.put(opts(), :cancel_token, inner_token)
        )
      end)

    assert_receive :between_dispatches, 2_000
    Cancel.cancel(inner_token)
    assert {:error, :cancelled} = Task.await(task2, 2_000)
  end

  @tag :tmp_dir
  test "failed producers leave no artifact and binary previews are display-safe", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    producer =
      Stream.map(["first", "second"], fn
        "first" -> "first"
        "second" -> raise "producer failed"
      end)

    assert_raise RuntimeError, "producer failed", fn ->
      OutputCapture.capture(producer, dir, max_bytes: 100, preview_bytes: 4)
    end

    assert File.ls!(dir) == []

    assert {:ok, result} =
             OutputCapture.capture([<<255, 0, 1>>], dir, max_bytes: 100, preview_bytes: 2)

    assert String.valid?(result.preview)
    assert File.read!(result.path) == <<255, 0, 1>>
  end
end
