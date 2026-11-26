defmodule Alloy.CancelSteeringFollowUpTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.{Cancel, Message, Result, Tool, Transcript}
  alias Alloy.Context.Compactor
  alias Alloy.Provider.{Anthropic, Codex, Error, OpenAI}
  alias Alloy.Provider.Test, as: TestProvider

  defmodule BlockingAdapter do
    def run(req) do
      [probe_id] = Req.Request.get_header(req, "x-probe-id")
      test_pid = :persistent_term.get({Alloy.CancelSteeringFollowUpTest, probe_id})
      send(test_pid, {:http_worker_started, self()})

      if Req.Request.get_header(req, "x-stream-multi") == ["true"] do
        resp = Req.Response.new(status: 200)

        chunk =
          ~s(data: {"type":"response.output_text.delta","delta":"one"}\n\n) <>
            ~s(data: {"type":"response.output_text.delta","delta":"two"}\n\n) <>
            ~s(data: {"type":"response.output_text.delta","delta":"three"}\n\n)

        case req.into.({:data, chunk}, {req, resp}) do
          {:halt, {req, resp}} -> {req, resp}
          {:cont, {req, resp}} -> {req, resp}
        end
      else
        if Req.Request.get_header(req, "x-stream-first") == ["true"] do
          resp = Req.Response.new(status: 200)
          chunk = ~s(data: {"type":"response.output_text.delta","delta":"hello"}\n\n)
          _ = req.into.({:data, chunk}, {req, resp})
        end

        receive do
          :never -> {req, Req.Response.new(status: 200, body: "{}")}
        end
      end
    end
  end

  defmodule AfterToolExecutionRecorder do
    @behaviour Alloy.Middleware

    @impl true
    def call(:after_tool_execution, state) do
      if pid = state.config.context[:test_pid], do: send(pid, :after_tool_execution_ran)
      state
    end

    def call(:after_tool_request, state) do
      if pid = state.config.context[:test_pid], do: send(pid, :after_tool_request_ran)
      state
    end

    def call(:after_completion, state) do
      if pid = state.config.context[:test_pid], do: send(pid, {:after_completion_ran, state.turn})
      state
    end

    def call(:after_compaction, state) do
      if pid = state.config.context[:test_pid], do: send(pid, :after_compaction_ran)
      state
    end

    def call(_hook, state), do: state
  end

  defmodule CancelEmptySummaryProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      Cancel.cancel(config.cancel_token)

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("   ")],
         usage: %{input_tokens: 7, output_tokens: 0}
       }}
    end
  end

  defmodule BlockSecondToolMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(
          :before_tool_call,
          %{config: %{context: %{current_tool_call: %{name: "step_b"}}}} = state
        ) do
      send(state.config.context.test_pid, :blocked_step_b)
      {:block, "policy denied step_b"}
    end

    def call(_hook, state), do: state
  end

  defmodule RecordingProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(messages, _tool_defs, %{agent_pid: pid, record_pid: record_pid} = config) do
      send(record_pid, {:recorded_messages, messages})
      if config[:cancel_on_complete], do: Cancel.cancel(config.cancel_on_complete)
      TestProvider.complete(messages, [], %{agent_pid: pid})
    end
  end

  defmodule FailingThenFallbackProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      :atomics.add(config.attempts, 1, 1)
      if config[:cancel_on_attempt], do: Cancel.cancel(config.cancel_on_attempt)

      case config.mode do
        :retryable_429 ->
          {:error, %Error{kind: :rate_limited, status: 429, message: "slow down"}}

        :ok ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("fallback ok")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
      end
    end
  end

  defp register_probe(test_pid) do
    id = "cancel-probe-#{System.unique_integer([:positive])}"
    :persistent_term.put({__MODULE__, id}, test_pid)
    on_exit(fn -> :persistent_term.erase({__MODULE__, id}) end)
    id
  end

  defp drain_tagged(tag) do
    receive do
      {^tag, value} -> [value | drain_tagged(tag)]
    after
      0 -> []
    end
  end

  defp drain_mailbox do
    receive do
      msg -> [msg | drain_mailbox()]
    after
      0 -> []
    end
  end

  describe "Alloy.Cancel and Config validation" do
    test "Cancel token lifecycle is lock-free, idempotent, and cross-process" do
      refute Cancel.cancelled?(nil)

      token = Cancel.new()
      refute Cancel.cancelled?(token)

      parent = self()

      spawn(fn ->
        assert :ok = Cancel.cancel(token)
        send(parent, :cancelled_from_other_proc)
      end)

      assert_receive :cancelled_from_other_proc, 1_000
      assert Cancel.cancelled?(token)
      assert :ok = Cancel.cancel(token)
      assert Cancel.cancelled?(token)
    end

    test "Config.from_opts/1 validates :cancel_token, :steering, and :follow_up" do
      base = [provider: {TestProvider, []}]

      assert_raise ArgumentError, ~r/cancel_token/, fn ->
        Config.from_opts(base ++ [cancel_token: :not_a_token])
      end

      assert_raise ArgumentError, ~r/cancel_token/, fn ->
        Config.from_opts(base ++ [cancel_token: %Cancel{ref: :forged}])
      end

      assert_raise ArgumentError, ~r/steering/, fn ->
        Config.from_opts(base ++ [steering: fn -> [] end])
      end

      err_steering =
        assert_raise ArgumentError, fn ->
          Config.from_opts(base ++ [steering: "sk-secret-steering"])
        end

      refute Exception.message(err_steering) =~ "sk-secret-steering"

      err_follow_up =
        assert_raise ArgumentError, fn ->
          Config.from_opts(base ++ [follow_up: "sk-secret-follow-up"])
        end

      assert Exception.message(err_follow_up) =~ "follow_up"
      refute Exception.message(err_follow_up) =~ "sk-secret-follow-up"

      token = Cancel.new()
      steering = fn _state -> [] end
      follow_up = fn _state -> [] end

      cfg =
        Config.from_opts(base ++ [cancel_token: token, steering: steering, follow_up: follow_up])

      assert cfg.cancel_token == token
      assert cfg.steering == steering
      assert cfg.follow_up == follow_up
    end
  end

  describe "cooperative cancellation across run phases" do
    test "pre-cancelled token skips provider, emits no turn events, and reports :cancelled telemetry" do
      parent = self()
      token = Cancel.new()
      Cancel.cancel(token)

      tel_id = "cancel-run-stop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        tel_id,
        [:alloy, :run, :stop],
        fn _ev, _meas, meta, _ ->
          if self() == parent, do: send(parent, {:run_stop, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(tel_id) end)

      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("should never run")])

      assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 0} = result} =
               Alloy.run("hello",
                 provider: {TestProvider, agent_pid: pid},
                 cancel_token: token,
                 on_event: &send(parent, {:ev, &1})
               )

      assert length(result.messages) == 1
      assert drain_tagged(:ev) == []
      assert_received {:run_stop, %{status: :cancelled, turns: 0}}
      assert length(Agent.get(pid, & &1)) == 1
    end

    test "cancelling inside :turn_start stops before provider call and emits :turn_end :cancelled" do
      parent = self()
      token = Cancel.new()
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("never called")])

      assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 0}} =
               Alloy.run("hello",
                 provider: {TestProvider, agent_pid: pid},
                 cancel_token: token,
                 on_event: fn ev ->
                   send(parent, {:ev, ev})
                   if ev.event == :turn_start, do: Cancel.cancel(token)
                 end
               )

      events = drain_tagged(:ev)

      assert [%{event: :turn_start, turn: 1}, %{event: :turn_end, turn: 1, payload: payload}] =
               events

      assert payload.status == :cancelled
      assert payload.stop_reason == nil
      assert length(Agent.get(pid, & &1)) == 1
    end

    test "cancels in-flight HTTP POST with finite and :infinity timeout, killing worker and skipping fallback" do
      parent = self()

      for timeout_ms <- [5_000, :infinity] do
        token = Cancel.new()
        probe_id = register_probe(parent)
        fb_attempts = :atomics.new(1, signed: false)

        task =
          Task.async(fn ->
            Alloy.run("hi",
              provider:
                {OpenAI,
                 api_key: "sk-test",
                 model: "gpt-5.4",
                 extra_headers: [{"x-probe-id", probe_id}],
                 req_options: [adapter: BlockingAdapter]},
              fallback_providers: [
                {FailingThenFallbackProvider, %{attempts: fb_attempts, mode: :ok}}
              ],
              max_retries: 2,
              timeout_ms: timeout_ms,
              cancel_token: token
            )
          end)

        assert_receive {:http_worker_started, worker_pid}, 2_000
        mon = Process.monitor(worker_pid)
        started = System.monotonic_time(:millisecond)
        Cancel.cancel(token)

        assert {:error, %Result{status: :cancelled, error: :cancelled}} = Task.await(task, 2_000)
        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed < 1_000
        assert_receive {:DOWN, ^mon, :process, ^worker_pid, _reason}, 1_000
        assert :atomics.get(fb_attempts, 1) == 0
      end
    end

    test "cancels in-flight SSE stream between chunks and mid-chunk with :infinity timeout" do
      parent = self()

      # 1. Stall after first SSE chunk under timeout_ms: :infinity
      token = Cancel.new()
      probe_id = register_probe(parent)

      task =
        Task.async(fn ->
          Alloy.stream(
            "hi",
            fn chunk -> send(parent, {:chunk, chunk}) end,
            provider:
              {OpenAI,
               api_key: "sk-test",
               model: "gpt-5.4",
               extra_headers: [{"x-probe-id", probe_id}, {"x-stream-first", "true"}],
               req_options: [adapter: BlockingAdapter]},
            timeout_ms: :infinity,
            cancel_token: token
          )
        end)

      assert_receive {:http_worker_started, worker_pid}, 2_000
      assert_receive {:chunk, "hello"}, 2_000
      mon = Process.monitor(worker_pid)
      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled}} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^mon, :process, ^worker_pid, _reason}, 1_000

      # 2. Cancel inside on_chunk during a multi-event single SSE chunk stops further dispatch
      token2 = Cancel.new()
      probe_id2 = register_probe(parent)

      assert {:error, %Result{status: :cancelled, error: :cancelled}} =
               Alloy.stream(
                 "hi",
                 fn chunk ->
                   send(parent, {:multi_chunk, chunk})
                   Cancel.cancel(token2)
                 end,
                 provider:
                   {OpenAI,
                    api_key: "sk-test",
                    model: "gpt-5.4",
                    extra_headers: [{"x-probe-id", probe_id2}, {"x-stream-multi", "true"}],
                    req_options: [adapter: BlockingAdapter]},
                 timeout_ms: :infinity,
                 cancel_token: token2
               )

      assert_receive {:http_worker_started, _pid}, 1_000
      assert drain_tagged(:multi_chunk) == ["one"]
      assert drain_mailbox() == []
    end

    test "cancels blocked dynamic :api_key callback promptly" do
      parent = self()
      token = Cancel.new()

      task =
        Task.async(fn ->
          Alloy.run("hi",
            provider:
              {Anthropic,
               api_key: fn ->
                 send(parent, {:auth_worker, self()})
                 Process.sleep(:infinity)
               end,
               origin_key: "acct-1",
               model: "claude-sonnet-4-6"},
            timeout_ms: :infinity,
            cancel_token: token
          )
        end)

      assert_receive {:auth_worker, auth_pid}, 2_000
      mon = Process.monitor(auth_pid)
      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled}} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^mon, :process, ^auth_pid, _reason}, 1_000
    end

    test "cancels during Retry backoff sleep promptly without retrying or calling fallback" do
      token = Cancel.new()
      primary_attempts = :atomics.new(1, signed: false)
      fallback_attempts = :atomics.new(1, signed: false)

      task =
        Task.async(fn ->
          Alloy.run("hi",
            provider:
              {FailingThenFallbackProvider, %{attempts: primary_attempts, mode: :retryable_429}},
            fallback_providers: [
              {FailingThenFallbackProvider, %{attempts: fallback_attempts, mode: :ok}}
            ],
            max_retries: 3,
            retry_backoff_ms: 5_000,
            timeout_ms: 30_000,
            cancel_token: token
          )
        end)

      # Wait until attempt 1 has failed and entered backoff sleep.
      Enum.reduce_while(1..100, :wait, fn _, _ ->
        if :atomics.get(primary_attempts, 1) >= 1 do
          {:halt, :ok}
        else
          Process.sleep(10)
          {:cont, :wait}
        end
      end)

      started = System.monotonic_time(:millisecond)
      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled}} = Task.await(task, 2_000)
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert :atomics.get(primary_attempts, 1) == 1
      assert :atomics.get(fallback_attempts, 1) == 0
    end

    test "cancels in-flight parallel/queued/unstarted tool batches cleanly with valid transcript" do
      parent = self()
      token = Cancel.new()

      slow_tool =
        Tool.inline(
          name: "slow_op",
          description: "blocks until killed",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _input, _ctx ->
            send(parent, {:tool_worker_started, self()})
            Process.sleep(:infinity)
          end
        )

      serial_tool =
        Tool.inline(
          name: "serial_op",
          description: "should never run",
          concurrent?: false,
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _input, _ctx ->
            send(parent, :serial_op_ran)
            {:ok, "ran"}
          end
        )

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "c1", name: "slow_op", input: %{}},
            %{id: "c2", name: "slow_op", input: %{}},
            %{id: "c3", name: "serial_op", input: %{}}
          ]),
          TestProvider.text_response("should not reach turn 2")
        ])

      task =
        Task.async(fn ->
          res =
            Alloy.run("run tools",
              provider: {TestProvider, agent_pid: pid},
              tools: [slow_tool, serial_tool],
              tool_concurrency: 1,
              middleware: [AfterToolExecutionRecorder],
              context: %{test_pid: parent},
              cancel_token: token,
              on_event: &send(parent, {:ev, &1})
            )

          {res, drain_mailbox()}
        end)

      assert_receive {:tool_worker_started, worker_pid}, 2_000
      mon = Process.monitor(worker_pid)
      Cancel.cancel(token)

      assert {{:error, %Result{status: :cancelled, error: :cancelled, turns: 1} = result},
              leftover_msgs} = Task.await(task, 2_000)

      assert_receive {:DOWN, ^mon, :process, ^worker_pid, _reason}, 1_000
      assert leftover_msgs == []
      refute_received :serial_op_ran
      refute_received :after_tool_execution_ran

      assert :ok == Transcript.validate(result.messages)

      tool_result_blocks =
        result.messages
        |> List.last()
        |> Map.fetch!(:content)

      assert Enum.map(tool_result_blocks, & &1.tool_use_id) == ["c1", "c2", "c3"]
      assert Enum.all?(tool_result_blocks, & &1.is_error)
      assert Enum.at(tool_result_blocks, 0).content =~ "cancelled"
      assert Enum.at(tool_result_blocks, 1).content == "Not executed: Cancelled"
      assert Enum.at(tool_result_blocks, 2).content == "Not executed: Cancelled"

      events = drain_tagged(:ev)
      starts = Enum.filter(events, &(&1.event == :tool_start))
      ends = Enum.filter(events, &(&1.event == :tool_end))
      assert Enum.map(starts, & &1.payload.id) == ["c1"]
      assert Enum.map(ends, & &1.payload.id) == ["c1"]

      assert [%{turn: 1, payload: %{status: :cancelled, stop_reason: :tool_use}}] =
               Enum.filter(events, &(&1.event == :turn_end))
    end

    test "cancels parallel batch with queued pending slot cleanly" do
      parent = self()
      token = Cancel.new()

      slow_tool =
        Tool.inline(
          name: "slow_par",
          description: "blocks",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _input, _ctx ->
            send(parent, {:par_worker, self()})
            Process.sleep(:infinity)
          end
        )

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "p1", name: "slow_par", input: %{}},
            %{id: "p2", name: "slow_par", input: %{}},
            %{id: "p3", name: "slow_par", input: %{}}
          ])
        ])

      task =
        Task.async(fn ->
          Alloy.run("run parallel",
            provider: {TestProvider, agent_pid: pid},
            tools: [slow_tool],
            tool_concurrency: 2,
            cancel_token: token,
            on_event: &send(parent, {:par_ev, &1})
          )
        end)

      assert_receive {:par_worker, w1}, 2_000
      assert_receive {:par_worker, w2}, 2_000
      m1 = Process.monitor(w1)
      m2 = Process.monitor(w2)
      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled} = result} =
               Task.await(task, 2_000)

      assert_receive {:DOWN, ^m1, :process, ^w1, _}, 1_000
      assert_receive {:DOWN, ^m2, :process, ^w2, _}, 1_000
      assert :ok == Transcript.validate(result.messages)

      events = drain_tagged(:par_ev)
      starts = events |> Enum.filter(&(&1.event == :tool_start)) |> Enum.map(& &1.payload.id)
      ends = events |> Enum.filter(&(&1.event == :tool_end)) |> Enum.map(& &1.payload.id)
      assert Enum.sort(starts) == ["p1", "p2", "p3"]
      assert Enum.sort(ends) == ["p1", "p2", "p3"]
    end

    test "cancels before tool execution starts when cancelled during provider response" do
      parent = self()
      token = Cancel.new()

      tool =
        Tool.inline(
          name: "never_run",
          description: "never runs",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ ->
            send(parent, :never_run_called)
            {:ok, "bad"}
          end
        )

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "t1", name: "never_run", input: %{}}])
        ])

      assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 1} = result} =
               Alloy.run("go",
                 provider:
                   {RecordingProvider,
                    agent_pid: pid, record_pid: parent, cancel_on_complete: token},
                 tools: [tool],
                 middleware: [AfterToolExecutionRecorder],
                 context: %{test_pid: parent},
                 cancel_token: token
               )

      refute_received :never_run_called
      refute_received :after_tool_request_ran
      assert :ok == Transcript.validate(result.messages)

      assert [
               %{
                 type: "tool_result",
                 tool_use_id: "t1",
                 content: "Not executed: Cancelled",
                 is_error: true
               }
             ] =
               result.messages |> List.last() |> Map.fetch!(:content)
    end

    test "cancels mid-compaction summary call cleanly without mutating history or firing post-compaction hooks" do
      parent = self()
      token = Cancel.new()
      probe_id = register_probe(parent)

      compaction_tel_id = "cancel-compaction-done-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        compaction_tel_id,
        [:alloy, :compaction, :done],
        fn _ev, _m, _meta, _ ->
          if self() == parent, do: send(parent, :compaction_done_telemetry)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(compaction_tel_id) end)

      # Include signed thinking blocks and bulky tool results so any finalize/clear/truncate
      # mutation would visibly change the verbatim messages.
      history =
        [
          Message.user("initial prompt " <> String.duplicate("x", 400)),
          %Message{
            role: :assistant,
            content: [
              %{type: "thinking", thinking: "signed thought", signature: "sig-1"},
              %{type: "tool_use", id: "old_tc", name: "read", input: %{"path" => "a.ex"}}
            ]
          },
          Message.tool_results([
            Message.tool_result_block("old_tc", String.duplicate("tool-output-", 300), false)
          ])
        ] ++
          for i <- 1..8 do
            if rem(i, 2) == 1,
              do: Message.user(String.duplicate("u#{i} ", 200)),
              else: Message.assistant(String.duplicate("a#{i} ", 200))
          end

      expected_messages = history ++ [Message.user("final question")]

      task =
        Task.async(fn ->
          Alloy.run("final question",
            messages: history,
            provider:
              {OpenAI,
               api_key: "sk-test",
               model: "gpt-5.4",
               extra_headers: [{"x-probe-id", probe_id}],
               req_options: [adapter: BlockingAdapter]},
            middleware: [AfterToolExecutionRecorder],
            context: %{test_pid: parent},
            max_tokens: 500,
            compaction: [reserve_tokens: 100, keep_recent_tokens: 100],
            cancel_token: token
          )
        end)

      assert_receive {:http_worker_started, summary_worker}, 2_000
      mon = Process.monitor(summary_worker)
      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 0} = result} =
               Task.await(task, 2_000)

      assert_receive {:DOWN, ^mon, :process, ^summary_worker, _}, 1_000
      assert result.messages == expected_messages
      refute_received :after_compaction_ran
      refute_received :compaction_done_telemetry

      # Summary provider that cancels token and returns an empty summary must NOT fall back to truncation.
      token2 = Cancel.new()

      assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 0} = result2} =
               Alloy.run("final question",
                 messages: history,
                 provider: {CancelEmptySummaryProvider, %{cancel_token: token2}},
                 middleware: [AfterToolExecutionRecorder],
                 context: %{test_pid: parent},
                 max_tokens: 500,
                 compaction: [reserve_tokens: 100, keep_recent_tokens: 100],
                 cancel_token: token2
               )

      assert result2.messages == expected_messages
      assert result2.usage.input_tokens == 7
      refute_received :after_compaction_ran

      # Pre-cancelled force_compact preserves messages verbatim without clearing/shrinking/stripping thinking.
      token3 = Cancel.new()
      Cancel.cancel(token3)
      cfg = Config.from_opts(provider: {TestProvider, []}, cancel_token: token3)
      st = State.init(cfg, history)
      assert Compactor.force_compact(st).messages == history
    end

    test "cancels CodexRunner subprocess cleanly, removes temp dir, and annotates resumed sessions" do
      tmp_root =
        Path.join(System.tmp_dir!(), "alloy-cancel-codex-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf(tmp_root) end)

      leader_pid_file = Path.join(tmp_root, "leader.pid")
      child_pid_file = Path.join(tmp_root, "child.pid")
      fake_codex = Path.join(tmp_root, "fake_codex.sh")

      # Spawn a descendant that ignores SIGTERM so process-group SIGKILL cleanup is exercised.
      File.write!(
        fake_codex,
        """
        #!/bin/sh
        trap '' TERM
        echo $$ > "#{leader_pid_file}"
        sh -c 'trap "" TERM; sleep 30' &
        echo $! > "#{child_pid_file}"
        wait
        """
      )

      File.chmod!(fake_codex, 0o755)

      token = Cancel.new()
      work_tmp = Path.join(tmp_root, "work_tmp")
      File.mkdir_p!(work_tmp)

      task =
        Task.async(fn ->
          Alloy.run("hi",
            provider:
              {Codex,
               model: "gpt-5.4", codex_bin: fake_codex, tmp_dir: work_tmp, timeout_ms: 30_000},
            cancel_token: token
          )
        end)

      wait_for_pid = fn path ->
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case File.read(path) do
            {:ok, content} when byte_size(content) > 0 ->
              {:halt, String.trim(content)}

            _ ->
              Process.sleep(10)
              {:cont, nil}
          end
        end)
      end

      leader_pid = wait_for_pid.(leader_pid_file)
      child_pid = wait_for_pid.(child_pid_file)
      assert is_binary(leader_pid)
      assert is_binary(child_pid)

      Cancel.cancel(token)

      assert {:error, %Result{status: :cancelled, error: :cancelled}} = Task.await(task, 3_000)

      # Temp dir created by CodexRunner is cleaned up and BOTH leader & SIGTERM-ignoring child terminated.
      assert File.ls!(work_tmp) == []

      for pid_str <- [leader_pid, child_pid] do
        alive? =
          Enum.reduce_while(1..50, true, fn _, _ ->
            case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
              {_, 0} ->
                Process.sleep(20)
                {:cont, true}

              _ ->
                {:halt, false}
            end
          end)

        refute alive?, "expected process #{pid_str} to be terminated after cancel"
      end

      # Verify resumed Codex session preserves kind: :cancelled with generation rotation guidance.
      token2 = Cancel.new()
      Cancel.cancel(token2)

      workdir = Path.join(tmp_root, "repo")
      File.mkdir_p!(workdir)

      # First run succeeds via injected command_runner to obtain a resumable provider_state.
      fake_reply =
        Jason.encode!(%{
          "type" => "thread.started",
          "thread_id" => "thr_cancel_1"
        }) <>
          "\n" <>
          Jason.encode!(%{
            "type" => "turn.completed",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
          })

      runner = fn _bin, args, _opts ->
        out_idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        out_path = Enum.at(args, out_idx + 1)

        File.write!(
          out_path,
          Jason.encode!(%{stop_reason: "end_turn", text: "ok", tool_calls: []})
        )

        {fake_reply, 0}
      end

      {:ok, first_resp} =
        Codex.complete(
          [Message.user("turn 1")],
          [],
          %{
            model: "gpt-5.4",
            persist_session: true,
            workdir: workdir,
            command_runner: runner
          }
        )

      {:error, %Error{kind: :cancelled, message: msg}} =
        Codex.complete(
          [Message.user("turn 1")] ++ first_resp.messages ++ [Message.user("turn 2")],
          [],
          %{
            model: "gpt-5.4",
            persist_session: true,
            workdir: workdir,
            provider_state: first_resp.provider_state,
            alloy_cancel_token: token2,
            command_runner: runner
          }
        )

      assert msg =~ "session_generation"
    end
  end

  describe ":steering mid-run callback" do
    test "skips remaining unstarted tool batches, keeps valid transcript, and delivers steering message on next turn" do
      parent = self()

      make_tool = fn name ->
        Tool.inline(
          name: name,
          description: name,
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ ->
            send(parent, {:ran, name})
            {:ok, "#{name} done"}
          end
        )
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "s1", name: "step_a", input: %{}},
            %{id: "s2", name: "step_b", input: %{}},
            %{id: "s3", name: "step_c", input: %{}}
          ]),
          TestProvider.text_response("pivoted to plan B")
        ])

      polled = :atomics.new(1, signed: false)

      steering = fn state ->
        n = :atomics.add_get(polled, 1, 1)
        send(parent, {:steering_seen_calls, Enum.map(state.tool_calls, & &1.name)})

        if n == 1 do
          [Message.user("Stop and switch to plan B")]
        else
          []
        end
      end

      assert {:ok, %Result{status: :completed, text: "pivoted to plan B", turns: 2} = result} =
               Alloy.run("start plan A",
                 provider: {RecordingProvider, agent_pid: pid, record_pid: parent},
                 tools: [make_tool.("step_a"), make_tool.("step_b"), make_tool.("step_c")],
                 tool_concurrency: 1,
                 middleware: [BlockSecondToolMiddleware],
                 context: %{test_pid: parent},
                 steering: steering,
                 on_event: &send(parent, {:ev, &1})
               )

      assert_received {:ran, "step_a"}
      assert_received :blocked_step_b
      refute_received {:ran, "step_b"}
      refute_received {:ran, "step_c"}
      assert_received {:steering_seen_calls, ["step_a"]}

      assert :ok == Transcript.validate(result.messages)

      # Verify tool results preserve executed, blocked, and skipped reasons cleanly.
      tool_results_msg =
        Enum.find(result.messages, fn m ->
          m.role == :user and is_list(m.content) and
            Enum.any?(m.content, &(&1[:type] == "tool_result"))
        end)

      assert [
               %{tool_use_id: "s1", content: "step_a done"} = s1_block,
               %{tool_use_id: "s2", content: "Blocked: policy denied step_b", is_error: true},
               %{tool_use_id: "s3", content: "Skipped due to steering message.", is_error: true}
             ] = tool_results_msg.content

      refute Map.get(s1_block, :is_error, false)

      # Only step_a emitted :tool_start/:tool_end and appeared in result.tool_calls.
      assert Enum.map(result.tool_calls, & &1.name) == ["step_a"]
      events = drain_tagged(:ev)

      assert events |> Enum.filter(&(&1.event == :tool_start)) |> Enum.map(& &1.payload.id) == [
               "s1"
             ]

      assert events |> Enum.filter(&(&1.event == :tool_end)) |> Enum.map(& &1.payload.id) == [
               "s1"
             ]

      # Turn 2 request received the steering message immediately after the tool results.
      [_req1_msgs, req2_msgs] = drain_tagged(:recorded_messages)
      assert List.last(req2_msgs) == Message.user("Stop and switch to plan B")
    end

    test "injects steering message even after the final batch and overrides :stop_after_tool" do
      tool =
        Tool.inline(
          name: "finish_tool",
          description: "finish",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ -> {:ok, "done"} end
        )

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "f1", name: "finish_tool", input: %{}}]),
          TestProvider.text_response("handled steering after single batch")
        ])

      assert {:ok,
              %Result{status: :completed, text: "handled steering after single batch", turns: 2}} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [tool],
                 stop_after_tool: "finish_tool",
                 steering: fn _state -> [Message.user("Wait, check one more thing")] end
               )
    end

    test "fails cleanly with sanitized error and valid transcript on invalid return or exception in :steering" do
      tool =
        Tool.inline(
          name: "t",
          description: "t",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ -> {:ok, "ok"} end
        )

      for bad_steering <- [
            fn _ -> "sk-secret-raw-string" end,
            fn _ -> ["not a message struct"] end,
            fn _ -> [%Message{role: :system, content: "bad role"}] end,
            fn _ -> [%Message{role: :user, content: nil}] end,
            fn _ -> raise "credential=sk-runtime-secret" end,
            fn _ -> raise KeyError, key: :missing, term: %{secret: "sk-leak-999"} end,
            fn _ -> throw(%{secret: "sk-throw-999"}) end
          ] do
        {:ok, pid} =
          TestProvider.start_link([
            TestProvider.tool_use_response([
              %{id: "b1", name: "t", input: %{}},
              %{id: "b2", name: "t", input: %{}}
            ])
          ])

        assert {:error, %Result{status: :error, error: err} = result} =
                 Alloy.run("go",
                   provider: {TestProvider, agent_pid: pid},
                   tools: [tool],
                   tool_concurrency: 1,
                   steering: bad_steering
                 )

        assert is_binary(err)
        assert err =~ "steering callback"
        serialized = inspect(result.messages)

        for secret <- ["sk-secret-raw-string", "sk-runtime-secret", "sk-leak-999", "sk-throw-999"] do
          refute err =~ secret
          refute serialized =~ secret
        end

        assert :ok == Transcript.validate(result.messages)
      end
    end

    test "cancellation takes precedence over :steering outcomes and steering works between parallel and sequential batches" do
      parent = self()

      par_tool =
        Tool.inline(
          name: "par_t",
          description: "parallel",
          concurrent?: true,
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ ->
            send(parent, :par_ran)
            {:ok, "par ok"}
          end
        )

      seq_tool =
        Tool.inline(
          name: "seq_t",
          description: "sequential",
          concurrent?: false,
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ ->
            send(parent, :seq_ran)
            {:ok, "seq ok"}
          end
        )

      # 1. Steering between a parallel batch and a sequential batch under default tool_concurrency
      {:ok, pid_mix} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "m1", name: "par_t", input: %{}},
            %{id: "m2", name: "par_t", input: %{}},
            %{id: "m3", name: "seq_t", input: %{}}
          ]),
          TestProvider.text_response("steered after parallel batch")
        ])

      assert {:ok, %Result{status: :completed, text: "steered after parallel batch"} = mix_res} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid_mix},
                 tools: [par_tool, seq_tool],
                 steering: fn _ -> [Message.user("skip sequential step")] end
               )

      assert_received :par_ran
      assert_received :par_ran
      refute_received :seq_ran
      assert :ok == Transcript.validate(mix_res.messages)

      # 2. Cancellation inside :steering overrides non-empty messages, invalid returns, raises, throws, and exits
      for steering_action <- [
            fn token ->
              Cancel.cancel(token)
              [Message.user("too late")]
            end,
            fn token ->
              Cancel.cancel(token)
              :invalid_return
            end,
            fn token ->
              Cancel.cancel(token)
              raise "boom after cancel"
            end,
            fn token ->
              Cancel.cancel(token)
              throw(:thrown_after_cancel)
            end,
            fn token ->
              Cancel.cancel(token)
              exit(:exited_after_cancel)
            end
          ] do
        token = Cancel.new()

        {:ok, pid} =
          TestProvider.start_link([
            TestProvider.tool_use_response([
              %{id: "c1", name: "par_t", input: %{}},
              %{id: "c2", name: "seq_t", input: %{}}
            ])
          ])

        assert {:error, %Result{status: :cancelled, error: :cancelled} = res} =
                 Alloy.run("go",
                   provider: {TestProvider, agent_pid: pid},
                   tools: [par_tool, seq_tool],
                   cancel_token: token,
                   steering: fn _state -> steering_action.(token) end
                 )

        assert :ok == Transcript.validate(res.messages)

        assert [
                 %{tool_use_id: "c1", content: "par ok"},
                 %{tool_use_id: "c2", content: "Not executed: Cancelled", is_error: true}
               ] = res.messages |> List.last() |> Map.fetch!(:content)
      end
    end
  end

  describe ":follow_up completion callback" do
    test "continues loop before :end_turn, runs :after_completion only on final completion" do
      parent = self()

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("first answer"),
          TestProvider.text_response("second answer")
        ])

      queue = :atomics.new(1, signed: false)

      follow_up = fn state ->
        send(parent, {:follow_up_turn, state.turn})

        if :atomics.compare_exchange(queue, 1, 0, 1) == :ok do
          [Message.user("Now summarize in 1 word")]
        else
          []
        end
      end

      assert {:ok, %Result{status: :completed, text: "second answer", turns: 2} = result} =
               Alloy.run("start",
                 provider: {TestProvider, agent_pid: pid},
                 middleware: [AfterToolExecutionRecorder],
                 context: %{test_pid: parent},
                 follow_up: follow_up
               )

      assert_received {:follow_up_turn, 1}
      assert_received {:follow_up_turn, 2}
      assert_received {:after_completion_ran, 2}
      refute_received {:after_completion_ran, 1}
      assert :ok == Transcript.validate(result.messages)
    end

    test "respects :max_turns, :timeout_ms, and :cancel_token bounds" do
      # 1. max_turns: 1 with non-empty follow-up stops with :max_turns
      {:ok, pid1} =
        TestProvider.start_link([
          TestProvider.text_response("turn 1"),
          TestProvider.text_response("should not run")
        ])

      assert {:ok, %Result{status: :max_turns, turns: 1}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid1},
                 max_turns: 1,
                 follow_up: fn _ -> [Message.user("more")] end
               )

      assert length(Agent.get(pid1, & &1)) == 1

      # 2. max_turns: 1 with empty follow-up still completes as :completed
      {:ok, pid2} = TestProvider.start_link([TestProvider.text_response("turn 1")])

      assert {:ok, %Result{status: :completed, turns: 1}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid2},
                 max_turns: 1,
                 follow_up: fn _ -> [] end
               )

      # 3. timeout_ms expiry inside follow_up halts with timeout :error
      {:ok, pid3} =
        TestProvider.start_link([
          TestProvider.text_response("turn 1"),
          TestProvider.text_response("should not run")
        ])

      assert {:error, %Result{status: :error, turns: 1}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid3},
                 timeout_ms: 80,
                 follow_up: fn _ ->
                   Process.sleep(120)
                   [Message.user("more")]
                 end
               )

      # 4. cancel_token flipped inside follow_up overrides messages, invalid returns, raises, throws, and exits
      for follow_up_action <- [
            fn token ->
              Cancel.cancel(token)
              [Message.user("more")]
            end,
            fn token ->
              Cancel.cancel(token)
              :not_a_list
            end,
            fn token ->
              Cancel.cancel(token)
              raise "boom after cancel"
            end,
            fn token ->
              Cancel.cancel(token)
              throw(:thrown_after_cancel)
            end,
            fn token ->
              Cancel.cancel(token)
              exit(:exited_after_cancel)
            end
          ] do
        token = Cancel.new()
        {:ok, pid4} = TestProvider.start_link([TestProvider.text_response("turn 1")])

        assert {:error, %Result{status: :cancelled, error: :cancelled, turns: 1}} =
                 Alloy.run("hi",
                   provider: {TestProvider, agent_pid: pid4},
                   cancel_token: token,
                   follow_up: fn _ -> follow_up_action.(token) end
                 )
      end
    end

    test "is not polled on :max_tokens, :stop_after_tool, refusals, or pending :until_tool, and sanitizes errors" do
      parent = self()

      # 1. Not polled on :max_tokens
      {:ok, pid_mt} =
        TestProvider.start_link([
          {:ok,
           %{
             stop_reason: :max_tokens,
             messages: [Message.assistant("cut off")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        ])

      assert {:ok, %Result{status: :completed, stop_reason: :max_tokens}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid_mt},
                 follow_up: fn _ ->
                   send(parent, :follow_up_called_on_max_tokens)
                   [Message.user("nope")]
                 end
               )

      refute_received :follow_up_called_on_max_tokens

      # 2. Not polled on :stop_after_tool
      tool =
        Tool.inline(
          name: "done_tool",
          description: "done",
          input_schema: %{type: "object", properties: %{}, required: []},
          execute: fn _, _ -> {:ok, "final"} end
        )

      {:ok, pid_sat} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "d1", name: "done_tool", input: %{}}])
        ])

      assert {:ok, %Result{status: :completed, text: "final"}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid_sat},
                 tools: [tool],
                 stop_after_tool: "done_tool",
                 follow_up: fn _ ->
                   send(parent, :follow_up_called_on_stop_after_tool)
                   [Message.user("nope")]
                 end
               )

      refute_received :follow_up_called_on_stop_after_tool

      # 3. Not polled on stop_reason: :refusal OR end_turn with refusal content block (even without :output_schema)
      {:ok, pid_refusal_sr} =
        TestProvider.start_link([
          {:ok,
           %{
             stop_reason: :refusal,
             messages: [Message.assistant("cannot comply")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        ])

      assert {:error, %Result{status: :error, stop_reason: :refusal}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid_refusal_sr},
                 follow_up: fn _ ->
                   send(parent, :follow_up_called_on_refusal)
                   [Message.user("nope")]
                 end
               )

      refute_received :follow_up_called_on_refusal

      {:ok, pid_refusal_block} =
        TestProvider.start_link([
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               %Message{
                 role: :assistant,
                 content: [%{type: "text", text: "I cannot assist with that.", refusal: true}]
               }
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        ])

      assert {:ok, %Result{status: :completed}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid_refusal_block},
                 follow_up: fn _ ->
                   send(parent, :follow_up_called_on_refusal_block)
                   [Message.user("nope")]
                 end
               )

      refute_received :follow_up_called_on_refusal_block

      # 4. Not polled while :until_tool is pending; polled once :until_tool has succeeded
      {:ok, pid_until} =
        TestProvider.start_link([
          TestProvider.text_response("forgot to call tool"),
          TestProvider.tool_use_response([%{id: "u1", name: "done_tool", input: %{}}]),
          TestProvider.text_response("now done")
        ])

      assert {:ok, %Result{status: :completed, text: "now done", turns: 3}} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid_until},
                 tools: [tool],
                 until_tool: "done_tool",
                 follow_up: fn state ->
                   send(parent, {:follow_up_until_turn, state.turn})
                   []
                 end
               )

      refute_received {:follow_up_until_turn, 1}
      assert_received {:follow_up_until_turn, 3}

      # 5. Invalid returns and exceptions (including RuntimeError secrets) in :follow_up are sanitized
      for bad_fu <- [
            fn _ -> %{secret: "sk-fu-secret"} end,
            fn _ -> [%Message{role: :system, content: "bad role"}] end,
            fn _ -> [%Message{role: :user, content: nil}] end,
            fn _ -> raise "credential=sk-fu-runtime" end,
            fn _ -> raise MatchError, term: %{token: "sk-fu-match"} end,
            fn _ -> exit(%{secret: "sk-fu-exit"}) end
          ] do
        {:ok, pid_bad} = TestProvider.start_link([TestProvider.text_response("ok")])

        assert {:error, %Result{status: :error, error: err}} =
                 Alloy.run("hi",
                   provider: {TestProvider, agent_pid: pid_bad},
                   follow_up: bad_fu
                 )

        assert err =~ "follow_up callback"

        for secret <- ["sk-fu-secret", "sk-fu-runtime", "sk-fu-match", "sk-fu-exit"] do
          refute err =~ secret
        end
      end
    end
  end
end
