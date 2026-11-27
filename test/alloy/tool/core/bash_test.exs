defmodule Alloy.Tool.Core.BashTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias Alloy.Tool.Core.Bash
  alias Alloy.Tool.{Executor, Registry}

  @moduletag :core_tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "alloy_bash_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "behaviour" do
    test "implements Alloy.Tool" do
      assert Bash.name() == "bash"
      assert is_binary(Bash.description())
      assert is_map(Bash.input_schema())
    end
  end

  describe "execute/2" do
    test "runs a simple command and returns output", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "echo hello"}, %{working_directory: tmp_dir})

      assert result =~ "hello"
      assert result =~ "exit code: 0"
    end

    test "returns non-zero exit code", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "exit 42"}, %{working_directory: tmp_dir})

      assert result =~ "exit code: 42"
    end

    test "captures stderr", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo error_msg >&2"},
                 %{working_directory: tmp_dir}
               )

      assert result =~ "error_msg"
    end

    test "respects working_directory", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(%{"command" => "pwd"}, %{working_directory: tmp_dir})

      assert result =~ tmp_dir
    end

    test "truncates output beyond 30000 chars", %{tmp_dir: tmp_dir} do
      # Generate output longer than 30000 chars
      cmd = "python3 -c \"print('x' * 40000)\""

      assert {:ok, result} =
               Bash.execute(%{"command" => cmd}, %{working_directory: tmp_dir})

      assert String.length(result) <= 31_000
      assert result =~ "truncated"
    end

    test "enforces timeout with a descriptive message", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "sleep 10", "timeout" => 100},
                 %{working_directory: tmp_dir}
               )

      assert msg =~ "timed out"
      assert msg =~ ~r/server|loop|input/i
    end

    test "a timeout kills the command, not just the Elixir task", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "marker")

      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "sleep 1; touch #{marker}", "timeout" => 200},
                 %{working_directory: tmp_dir}
               )

      assert msg =~ "timed out"
      Process.sleep(1_500)
      refute File.exists?(marker)
    end

    test "a timeout kills background children too", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "bg_marker")

      assert {:error, _msg} =
               Bash.execute(
                 %{"command" => "(sleep 1; touch #{marker}) & sleep 5", "timeout" => 200},
                 %{working_directory: tmp_dir}
               )

      Process.sleep(1_500)
      refute File.exists?(marker)
    end

    test "the command dies with the process that ran it", %{tmp_dir: tmp_dir} do
      # The executor kills a tool's task on :tool_timeout; the shell it
      # started must not outlive it.
      marker = Path.join(tmp_dir, "orphan_marker")

      caller =
        spawn(fn ->
          Bash.execute(
            %{"command" => "sleep 1; touch #{marker}", "timeout" => 10_000},
            %{working_directory: tmp_dir}
          )
        end)

      Process.sleep(200)
      Process.exit(caller, :kill)
      Process.sleep(1_500)
      refute File.exists?(marker)
    end

    # A steady flood of output must not postpone the timeout: the deadline
    # is checked before each receive, not only when the mailbox is empty.
    test "a command that floods output still times out and is killed", %{tmp_dir: tmp_dir} do
      tag = "alloy-flood-#{System.unique_integer([:positive])}"

      {elapsed_us, result} =
        :timer.tc(fn ->
          Bash.execute(%{"command" => "yes #{tag}", "timeout" => 300}, %{
            working_directory: tmp_dir
          })
        end)

      assert {:error, msg} = result
      assert msg =~ "timed out after 300ms"
      assert elapsed_us < 2_000_000

      Process.sleep(200)
      assert {"", 1} = System.cmd("pgrep", ["-f", tag])
    end

    test "the model's timeout is clamped to :bash_max_timeout", %{tmp_dir: tmp_dir} do
      {elapsed_us, result} =
        :timer.tc(fn ->
          Bash.execute(
            %{"command" => "sleep 5", "timeout" => 600_000},
            %{working_directory: tmp_dir, bash_max_timeout: 200}
          )
        end)

      assert {:error, msg} = result
      assert msg =~ "timed out after 200ms"
      assert elapsed_us < 2_000_000
    end

    test "a missing working directory is an error", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nope")

      assert {:error, msg} = Bash.execute(%{"command" => "pwd"}, %{working_directory: missing})
      assert msg =~ "Working directory does not exist"
    end

    test "honors explicit timeouts above the default", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "sleep 11", "timeout" => 12_000},
                 %{working_directory: tmp_dir}
               )

      assert result =~ "exit code: 0"
    end

    test "executes in bash not sh", %{tmp_dir: tmp_dir} do
      # $0 reports the name of the invoking shell: "bash" when called as bash, "sh" when called as sh
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo $0"},
                 %{working_directory: tmp_dir}
               )

      assert result =~ "bash"
    end

    test "uses default working directory when not in context" do
      assert {:ok, result} = Bash.execute(%{"command" => "echo works"}, %{})
      assert result =~ "works"
    end
  end

  describe "environment" do
    setup do
      # Unique names: the OS environment is global and tests run async.
      suffix = System.unique_integer([:positive])
      secret = "ALLOY_TEST_#{suffix}_API_KEY"
      token = "alloy_test_#{suffix}_token"
      plain = "ALLOY_TEST_#{suffix}_PLAIN"
      System.put_env(%{secret => "sk-secret", token => "tok-secret", plain => "visible"})
      on_exit(fn -> Enum.each([secret, token, plain], &System.delete_env/1) end)

      {:ok, secret: secret, token: token, plain: plain}
    end

    test "secret-looking variables are not inherited by default", vars do
      out = printenv([vars.secret, vars.token, vars.plain], %{})

      assert out =~ "#{vars.secret}=unset"
      assert out =~ "#{vars.token}=unset"
      assert out =~ "#{vars.plain}=visible"
      refute out =~ "secret"
    end

    test ":bash_env sets or removes variables explicitly", vars do
      context = %{bash_env: %{vars.secret => "granted", vars.plain => nil}}
      out = printenv([vars.secret, vars.token, vars.plain], context)

      assert out =~ "#{vars.secret}=granted"
      assert out =~ "#{vars.token}=unset"
      assert out =~ "#{vars.plain}=unset"
    end

    test "bash_env: :inherit passes the whole environment", vars do
      out = printenv([vars.secret, vars.plain], %{bash_env: :inherit})

      assert out =~ "#{vars.secret}=sk-secret"
      assert out =~ "#{vars.plain}=visible"
    end
  end

  describe "output limits" do
    test "keeps the head and the tail, where errors appear", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "seq 1 100000; echo THE_REAL_TAIL; exit 3"},
                 %{working_directory: tmp_dir}
               )

      assert String.starts_with?(result, "1\n2\n3\n")
      assert result =~ ~r/bytes of output truncated/
      assert String.ends_with?(result, "100000\nTHE_REAL_TAIL\n\nexit code: 3")
      assert String.length(result) <= Bash.max_result_chars()
    end

    test "the executor does not truncate bash output a second time" do
      executor = fn _cmd, _dir -> {String.duplicate("a", 39_000) <> "THE_REAL_TAIL", 1} end
      {_defs, tool_fns} = Registry.build([Bash])

      state =
        State.init(%Config{
          provider: Alloy.Provider.Test,
          provider_config: %{},
          tools: [Bash],
          context: %{bash_executor: executor}
        })

      call = %{id: "b", name: "bash", type: "tool_use", input: %{"command" => "x"}}

      assert %Message{content: [%{content: out}]} =
               Executor.execute_all([call], tool_fns, state)

      assert length(Regex.scan(~r/truncated/, out)) == 1
      assert String.ends_with?(out, "THE_REAL_TAIL\nexit code: 1")
    end

    test "multibyte output is only marked truncated when something was cut" do
      short = String.duplicate("é", 10_000)
      long = String.duplicate("é", 20_001)

      assert {:ok, result} =
               Bash.execute(%{"command" => "x"}, %{bash_executor: fn _, _ -> {short, 0} end})

      assert result == short <> "\nexit code: 0"

      assert {:ok, result} =
               Bash.execute(%{"command" => "x"}, %{bash_executor: fn _, _ -> {long, 0} end})

      assert result =~ "truncated"
      assert String.length(result) < String.length(long)
      assert String.valid?(result)
    end

    test "a timed-out command reports the output it produced", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "echo started; sleep 5", "timeout" => 300},
                 %{working_directory: tmp_dir}
               )

      assert msg =~ "started"
      assert msg =~ "timed out"
    end

    test "supervisor shutdown of host runner task kills background shell children", %{
      tmp_dir: tmp_dir
    } do
      pid_file = Path.join(tmp_dir, "bg.pid")

      caller =
        Task.async(fn ->
          Bash.execute(
            %{"command" => "sleep 30 & echo $! > #{pid_file}; wait", "timeout" => 10_000},
            %{working_directory: tmp_dir, bash_restricted: false}
          )
        end)

      assert eventually(fn -> File.exists?(pid_file) end), "background child never wrote pid"
      bg_pid = pid_file |> File.read!() |> String.trim()
      assert os_alive?(bg_pid)

      [runner] =
        for pid <- Task.Supervisor.children(Alloy.TaskSupervisor),
            {:dictionary, dict} <- [Process.info(pid, :dictionary)],
            caller.pid in Keyword.get(dict, :"$callers", []),
            do: pid

      Process.exit(runner, :shutdown)
      assert {:error, msg} = Task.await(caller, 2_000)
      assert msg =~ "Executor crashed: :shutdown"
      assert eventually(fn -> not os_alive?(bg_pid) end)
    end

    @tag timeout: 60_000
    test "huge output is capped while it streams, not buffered", %{tmp_dir: tmp_dir} do
      bytes = 64 * 1024 * 1024
      parent = self()

      sampler =
        spawn_link(fn ->
          :erlang.garbage_collect()
          sample_peak(:erlang.memory(:binary), parent)
        end)

      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "head -c #{bytes} /dev/zero | tr '\\0' a", "timeout" => 50_000},
                 %{working_directory: tmp_dir}
               )

      send(sampler, :stop)
      assert_receive {:peak_growth, growth}, 1_000

      # Buffering the whole output (as before) grows binary memory by
      # roughly twice its size; streaming keeps it to a few chunks.
      assert growth < div(bytes, 2)
      assert result =~ "truncated"
      assert String.length(result) <= Bash.max_result_chars()
    end
  end

  defp printenv(names, context) do
    command = Enum.map_join(names, "; ", &~s(echo "#{&1}=${#{&1}-unset}"))
    {:ok, out} = Bash.execute(%{"command" => command}, context)
    out
  end

  defp sample_peak(base, parent, peak \\ 0) do
    receive do
      :stop -> send(parent, {:peak_growth, peak})
    after
      5 -> sample_peak(base, parent, max(peak, :erlang.memory(:binary) - base))
    end
  end

  defp os_alive?(os_pid) do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    {_output, status} =
      System.cmd("/bin/sh", ["-c", ~S(kill -0 "$1"), "probe", os_pid],
        env: no_env,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end

  describe "custom bash_executor" do
    test "uses custom executor function when provided in context" do
      executor = fn _command, _working_dir -> {"custom output", 0} end

      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "echo hello"},
                 %{bash_executor: executor}
               )

      assert result =~ "custom output"
      assert result =~ "exit code: 0"
    end

    test "custom executor receives command and working_dir arguments", %{tmp_dir: tmp_dir} do
      test_pid = self()

      executor = fn command, working_dir ->
        send(test_pid, {:called_with, command, working_dir})
        {"ok", 0}
      end

      Bash.execute(
        %{"command" => "echo test"},
        %{bash_executor: executor, working_directory: tmp_dir}
      )

      assert_receive {:called_with, "echo test", ^tmp_dir}
    end

    test "custom executor timeout returns error when executor exceeds timeout" do
      executor = fn _command, _working_dir ->
        Process.sleep(5_000)
        {"never returned", 0}
      end

      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "anything", "timeout" => 100},
                 %{bash_executor: executor}
               )

      assert msg =~ "timed out"
    end

    test "custom executor output is truncated when over 30000 chars" do
      big_output = String.duplicate("x", 40_000)
      executor = fn _command, _working_dir -> {big_output, 0} end

      assert {:ok, result} =
               Bash.execute(
                 %{"command" => "anything"},
                 %{bash_executor: executor}
               )

      assert String.length(result) <= 31_000
      assert result =~ "truncated"
    end

    test "rejects non-string and NUL-byte commands" do
      assert {:error, bash_msg} = Bash.execute(%{"command" => 123}, %{})
      assert bash_msg =~ "string"
      assert {:error, nul_msg} = Bash.execute(%{"command" => "echo hi\0"}, %{})
      assert nul_msg =~ "NUL"
    end

    test "custom executor reports invalid return shapes instead of timeout or crash" do
      for bad_return <- [{:error, :boom}, {nil, 0}, {"ok", "0"}, "raw-string"] do
        assert {:error, msg} =
                 Bash.execute(%{"command" => "echo hi"}, %{
                   bash_executor: fn _cmd, _dir -> bad_return end
                 })

        assert msg =~ "Custom bash executor returned invalid result"
        refute msg =~ "timed out"
      end
    end

    test "custom executor reports raises, Erlang errors, throws, and exits cleanly" do
      cases = [
        {fn _, _ -> raise "boom" end, "boom"},
        {fn _, _ -> :erlang.error(:badarg) end, "argument error"},
        {fn _, _ -> throw(:stop_now) end, "stop_now"},
        {fn _, _ -> exit(:gone) end, "gone"}
      ]

      for {executor, expected} <- cases do
        assert {:error, msg} =
                 Bash.execute(%{"command" => "echo hi"}, %{bash_executor: executor})

        assert msg =~ "Executor crashed:"
        assert msg =~ expected
      end
    end

    test "custom executor crashes omit secrets captured in structural errors, exits, and throws" do
      secret = "sk-bash-executor-secret-42"
      creds = Map.new(api_key: secret, ssh_token: secret)

      cases = [
        {fn _, _ -> Map.fetch!(creds, :missing_key) end, "KeyError (key :missing_key not found)"},
        {fn _, _ -> {:ok, _} = Function.identity({:error, creds}) end, "MatchError"},
        {fn _, _ -> exit({:failed, creds}) end, "exit: {:failed, ...}"},
        {fn _, _ -> throw(creds) end, "throw: unexpected map"}
      ]

      for {executor, expected} <- cases do
        assert {:error, msg} =
                 Bash.execute(%{"command" => "echo hi"}, %{bash_executor: executor})

        assert msg =~ "Executor crashed:"
        assert msg =~ expected
        refute msg =~ secret
      end
    end

    test "custom executor dies when caller is killed and inherits Logger metadata and OTel context" do
      test_pid = self()
      logger_meta = [request_id: "bash-req-7"]
      reset_meta = [request_id: nil]
      Logger.metadata(logger_meta)
      Process.put(:"$__current_otel_ctx", {:fake_otel_ctx, "bash-span"})

      try do
        assert {:ok, _} =
                 Bash.execute(%{"command" => "ctx"}, %{
                   bash_executor: fn _cmd, _dir ->
                     send(
                       test_pid,
                       {:bash_ctx, Logger.metadata()[:request_id],
                        Process.get(:"$__current_otel_ctx")}
                     )

                     {"ok", 0}
                   end
                 })

        assert_received {:bash_ctx, "bash-req-7", {:fake_otel_ctx, "bash-span"}}
      after
        Logger.metadata(reset_meta)
        Process.delete(:"$__current_otel_ctx")
      end

      blocking_executor = fn _cmd, _dir ->
        send(test_pid, {:exec_started, self()})
        Process.sleep(10_000)
        {"never", 0}
      end

      caller =
        spawn(fn ->
          Bash.execute(%{"command" => "sleep"}, %{bash_executor: blocking_executor})
        end)

      assert_receive {:exec_started, exec_pid}, 1_000
      ref = Process.monitor(exec_pid)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^exec_pid, :killed}, 1_000
    end

    test "custom executor crash terminates linked children and timeout kills exit-trapping workers" do
      test_pid = self()

      crashing_executor = fn _cmd, _dir ->
        child = spawn_link(fn -> Process.sleep(:infinity) end)
        send(test_pid, {:bash_linked_child, child})
        raise "executor boom"
      end

      assert {:error, msg} =
               Bash.execute(%{"command" => "boom"}, %{bash_executor: crashing_executor})

      assert msg =~ "Executor crashed:"
      assert msg =~ "executor boom"

      assert_receive {:bash_linked_child, child}, 1_000
      child_ref = Process.monitor(child)
      assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 1_000

      trapping_executor = fn _cmd, _dir ->
        Process.flag(:trap_exit, true)
        send(test_pid, {:bash_trapping_worker, self()})

        receive do
          :never -> {"never", 0}
        end
      end

      bash_task =
        Task.async(fn ->
          Bash.execute(%{"command" => "hang", "timeout" => 50}, %{
            bash_executor: trapping_executor
          })
        end)

      assert_receive {:bash_trapping_worker, worker}, 1_000
      worker_ref = Process.monitor(worker)
      assert {:error, timeout_msg} = Task.await(bash_task, 2_000)
      assert timeout_msg =~ "timed out"
      assert timeout_msg =~ "non-blocking approach"
      refute Process.alive?(worker)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
    end

    test "custom executor external kill returns sanitized error without crashing caller" do
      test_pid = self()

      executor = fn _cmd, _dir ->
        send(test_pid, {:kill_me_worker, self()})
        Process.sleep(:infinity)
      end

      task =
        Task.async(fn ->
          Bash.execute(%{"command" => "wait"}, %{bash_executor: executor})
        end)

      assert_receive {:kill_me_worker, worker}, 1_000
      Process.exit(worker, :kill)

      assert {:error, "Executor crashed: :killed"} = Task.await(task, 2_000)

      # Huge crash payloads are bounded so they cannot flood the model transcript.
      big = String.duplicate("x", 10_000)

      assert {:error, big_err} =
               Bash.execute(%{"command" => "boom"}, %{bash_executor: fn _, _ -> exit(big) end})

      assert byte_size(big_err) <= 550
    end
  end
end
