defmodule Alloy.Provider.CodexRunner do
  @moduledoc false
  # Subprocess / port lifecycle for `Alloy.Provider.Codex`: temp-dir isolation,
  # deadline enforcement, cancellation, streaming line framing, and injected
  # test-runner execution.

  alias Alloy.Cancel
  alias Alloy.Internal.Sanitize
  alias Alloy.{OSProcess, OwnedWorker}
  alias Alloy.Provider.Error

  @default_timeout_ms 120_000
  @default_codex_bin "codex"
  # How long codex gets to exit after SIGTERM before the group is killed.
  @term_grace_ms 100
  # The owning task replies by its deadline plus the kill grace; this only
  # bounds the wait if it stops responding.
  @reply_grace_ms 5_000
  @cancel_poll_ms 25
  @cancel_shutdown_ms 1_500

  # sh only wires up redirects: the prompt file on stdin (codex reads it to
  # EOF, which a port cannot send) and stderr to a file, so stdout carries
  # nothing but --json events. Paths and arguments are positional parameters,
  # never spliced into the script. `exec` keeps the port's OS pid on codex.
  # Note: do NOT pass `--` to `exec` — dash (Ubuntu's /bin/sh) treats `--` as
  # the executable name. Option-like codex_bin values are rejected up front.
  @launch_script ~S(set -C; prompt="$1"; stderr="$2"; shift 2; exec "$@" < "$prompt" 2> "$stderr")

  @spec execute(
          String.t(),
          String.t() | nil,
          (map() -> [String.t()]),
          String.t(),
          map(),
          (String.t() -> String.t() | nil)
        ) :: {:ok, map()} | {:error, term()}
  def execute(
        prompt,
        codex_home,
        build_args,
        schema_json,
        %{command_runner: runner} = config,
        _reply_fn
      ) do
    cancel_token = Map.get(config, :alloy_cancel_token)

    with :ok <- check_cancelled(cancel_token),
         {:ok, _timeout, _deadline} <- resolve_deadline(config) do
      in_temp_dir(config, fn paths ->
        with :ok <- write_inputs(paths, schema_json, prompt) do
          runner
          |> run_injected(build_args.(paths) ++ [prompt], codex_home, paths, config)
          |> maybe_override_cancelled(cancel_token)
        end
      end)
    else
      {:expired, timeout} -> {:error, timed_out(timeout)}
      {:error, _} = err -> err
    end
  end

  # The OS process belongs to a supervised task rather than the caller, so it
  # is stopped and its files removed even when the caller is killed (the
  # loop kills a cancelled turn, and `after` blocks do not run on a kill).
  def execute(prompt, codex_home, build_args, schema_json, config, reply_fn) do
    cancel_token = Map.get(config, :alloy_cancel_token)

    with :ok <- check_cancelled(cancel_token),
         :ok <- check_workdir(config),
         :ok <- check_codex_bin(config),
         {:ok, sh} <- find_sh(),
         {:ok, timeout, deadline} <- resolve_deadline(config) do
      caller = self()
      tag = make_ref()
      on_chunk = Map.get(config, :alloy_on_chunk)
      emit = if on_chunk, do: fn text -> send(caller, {tag, text}) end

      runner_opts = %{
        sh: sh,
        build_args: build_args,
        schema_json: schema_json,
        emit: emit,
        reply_fn: reply_fn,
        cancel_token: cancel_token
      }

      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          own_run(caller, prompt, codex_home, config, timeout, deadline, runner_opts)
        end)

      case await_task(task, tag, on_chunk, deadline + @reply_grace_ms, cancel_token) do
        {:ok, result} ->
          maybe_override_cancelled(result, cancel_token)

        :cancelled ->
          {:error, cancelled_error()}

        {:exit, reason} ->
          if OwnedWorker.shutdown_reason?(reason) do
            {:error, %Error{kind: :shutdown, message: "codex exec interrupted by shutdown"}}
          else
            {:error,
             %Error{message: "codex exec failed: #{OwnedWorker.format_exit_reason(reason)}"}}
          end

        nil ->
          {:error, timed_out(timeout)}
      end
    else
      {:expired, timeout} -> {:error, timed_out(timeout)}
      {:error, _} = err -> err
    end
  end

  @spec codex_bin(map()) :: String.t()
  def codex_bin(config), do: Map.get(config, :codex_bin, @default_codex_bin)

  @spec not_runnable(map(), String.t()) :: Error.t()
  def not_runnable(config, detail) do
    %Error{
      message:
        "could not run codex executable #{inspect(codex_bin(config))}; install the Codex CLI " <>
          "or set :codex_bin (#{detail})"
    }
  end

  @doc false
  @spec create_temp_dir(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create_temp_dir(parent, dir_name, opts \\ []) do
    base_dir = Path.join(parent, dir_name)

    with :ok <- File.mkdir_p(parent),
         :ok <- mkdir_private_exclusive(base_dir, opts) do
      {:ok, base_dir}
    else
      {:error, reason} ->
        # Never remove base_dir when mkdir failed (e.g. :eexist on a pre-existing directory).
        {:error, temp_dir_error(reason)}
    end
  end

  # Create the directory atomically with 0700 permissions via a child shell's
  # umask so a permissive BEAM umask never opens a window for another local user
  # to plant files (such as last_message.json) before chmod runs. Fail closed if
  # atomic private creation is unavailable rather than falling back to a racy
  # mkdir + chmod sequence.
  defp mkdir_private_exclusive(base_dir, opts) do
    find_sh = Keyword.get(opts, :find_sh, &OSProcess.find_sh/0)
    find_mkdir = Keyword.get(opts, :find_mkdir, fn -> System.find_executable("mkdir") end)

    with sh when is_binary(sh) <- find_sh.(),
         mkdir when is_binary(mkdir) <- find_mkdir.() do
      mkdir_via_sh(sh, mkdir, base_dir)
    else
      _ -> {:error, :atomic_mkdir_unavailable}
    end
  end

  defp mkdir_via_sh(sh, mkdir, base_dir) do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    case System.cmd(
           sh,
           ["-c", ~S(umask 077 && exec "$1" -- "$2"), "alloy-mkdir", mkdir, base_dir],
           env: no_env,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, status} ->
        if File.exists?(base_dir),
          do: {:error, :eexist},
          else: {:error, {:mkdir_failed, status, String.trim(out)}}
    end
  end

  @doc false
  @spec write_inputs(map(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def write_inputs(paths, schema_json, prompt) do
    with :ok <- File.write(paths.schema_path, schema_json, [:exclusive]),
         :ok <- File.write(paths.prompt_path, prompt, [:exclusive]) do
      :ok
    else
      {:error, reason} ->
        {:error,
         %Error{
           kind: :unknown,
           message: "failed to write Codex input files: #{inspect(reason)}"
         }}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp check_codex_bin(config) do
    case codex_bin(config) do
      bin when is_binary(bin) and byte_size(bin) > 0 and binary_part(bin, 0, 1) != "-" ->
        :ok

      other ->
        {:error, not_runnable(config, "invalid executable name: #{inspect(other)}")}
    end
  end

  defp find_sh do
    case OSProcess.find_sh() do
      sh when is_binary(sh) -> {:ok, sh}
      nil -> {:error, %Error{message: "could not find sh executable to launch codex"}}
    end
  end

  defp await_task(%Task{ref: ref} = task, tag, on_chunk, deadline, cancel_token) do
    if Cancel.cancelled?(cancel_token) do
      shutdown_cancelled_task(task, tag)
    else
      wait_ms = next_wait_ms(deadline, cancel_token)

      receive do
        {^tag, text} ->
          if Cancel.cancelled?(cancel_token) do
            shutdown_cancelled_task(task, tag)
          else
            deliver_chunk(task, tag, on_chunk, text)
            await_task(task, tag, on_chunk, deadline, cancel_token)
          end

        {^ref, result} ->
          _ = Task.ignore(task)
          {:ok, result}

        {:DOWN, ^ref, :process, _pid, reason} ->
          {:exit, reason}
      after
        wait_ms ->
          handle_await_timeout(task, tag, on_chunk, deadline, cancel_token)
      end
    end
  end

  defp handle_await_timeout(task, tag, on_chunk, deadline, cancel_token) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        shutdown_cancelled_task(task, tag)

      deadline <= System.monotonic_time(:millisecond) ->
        _ = Task.shutdown(task)
        flush_chunks(tag)
        nil

      true ->
        await_task(task, tag, on_chunk, deadline, cancel_token)
    end
  end

  defp shutdown_cancelled_task(%Task{ref: ref} = task, tag) do
    _ = Task.shutdown(task, @cancel_shutdown_ms)
    flush_task_reply(ref)
    flush_chunks(tag)
    :cancelled
  end

  defp flush_task_reply(ref) do
    receive do
      {^ref, _reply} -> flush_task_reply(ref)
    after
      0 -> :ok
    end
  end

  defp next_wait_ms(deadline, nil),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp next_wait_ms(deadline, _cancel_token),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), @cancel_poll_ms)

  defp deliver_chunk(task, tag, on_chunk, text) do
    on_chunk.(text)
  catch
    kind, reason ->
      _ = Task.shutdown(task)
      flush_chunks(tag)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp flush_chunks(tag) do
    receive do
      {^tag, _text} -> flush_chunks(tag)
    after
      0 -> :ok
    end
  end

  # The port reports a missing directory only as "exit status 2" with the
  # reason on stderr, so check it up front for a clear error.
  defp check_workdir(%{workdir: workdir}) when is_binary(workdir) do
    if File.dir?(workdir),
      do: :ok,
      else: {:error, %Error{message: "Codex :workdir #{workdir} is not a directory"}}
  end

  defp check_workdir(_config), do: :ok

  defp own_run(caller, prompt, codex_home, config, timeout, deadline, runner_opts) do
    # Trapping exits lets a supervisor shutdown stop codex too.
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)

    receive do
      {:DOWN, ^caller_ref, :process, _pid, reason} ->
        {:error,
         %Error{
           message:
             "codex exec cancelled: caller exited (#{OwnedWorker.format_exit_reason(reason)})"
         }}

      {:EXIT, from, reason} when is_pid(from) ->
        Process.demonitor(caller_ref, [:flush])
        exit(reason)
    after
      0 ->
        try do
          run_owned_port(caller_ref, prompt, codex_home, config, timeout, deadline, runner_opts)
        catch
          # Propagate :shutdown / {:shutdown, _} exits (including supervisor
          # shutdown signals) so execute/6 maps them to kind: :shutdown.
          :exit, reason
          when reason == :shutdown or (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
            exit(reason)

          _kind, reason ->
            {:error,
             %Error{
               kind: :unknown,
               message: "codex exec failed: #{OwnedWorker.format_exit_reason(reason)}"
             }}
        after
          Process.demonitor(caller_ref, [:flush])
        end
    end
  end

  defp run_owned_port(caller_ref, prompt, codex_home, config, timeout, deadline, runner_opts) do
    with :ok <- check_cancelled(runner_opts.cancel_token),
         :ok <- check_deadline(deadline, timeout) do
      in_temp_dir(config, fn paths ->
        run_port_in_dir(
          caller_ref,
          prompt,
          codex_home,
          config,
          timeout,
          deadline,
          runner_opts,
          paths
        )
      end)
    end
  end

  defp run_port_in_dir(
         caller_ref,
         prompt,
         codex_home,
         config,
         timeout,
         deadline,
         runner_opts,
         paths
       ) do
    with :ok <- write_inputs(paths, runner_opts.schema_json, prompt),
         :ok <- check_cancelled(runner_opts.cancel_token),
         :ok <- check_deadline(deadline, timeout) do
      args = runner_opts.build_args.(paths) ++ ["-"]
      port = open_port(runner_opts.sh, args, codex_home, paths, config)

      run = %{
        port: port,
        os_pid: OSProcess.os_pid(port),
        caller_ref: caller_ref,
        deadline: deadline,
        timeout: timeout,
        cancel_token: runner_opts.cancel_token,
        emit: runner_opts.emit,
        reply_fn: runner_opts.reply_fn,
        stream_buffer: [],
        stream_candidate: nil,
        streamed_text: nil
      }

      try do
        with {:ok, output, status, streamed_text} <- collect(run, []) do
          {:ok,
           Map.put(
             command_result(output, read_stderr(paths), status, paths),
             :streamed_text,
             streamed_text
           )}
        end
      catch
        kind, reason ->
          stop(run)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp check_cancelled(cancel_token) do
    if Cancel.cancelled?(cancel_token), do: {:error, cancelled_error()}, else: :ok
  end

  defp cancelled_error, do: %Error{kind: :cancelled, message: "codex exec cancelled"}

  defp maybe_override_cancelled({:error, _} = err, cancel_token) do
    if Cancel.cancelled?(cancel_token), do: {:error, cancelled_error()}, else: err
  end

  defp maybe_override_cancelled({:ok, %{status: status}} = result, cancel_token)
       when status != 0 do
    if Cancel.cancelled?(cancel_token), do: {:error, cancelled_error()}, else: result
  end

  defp maybe_override_cancelled(ok, _cancel_token), do: ok

  defp check_deadline(deadline, timeout) do
    if deadline <= System.monotonic_time(:millisecond),
      do: {:error, timed_out(timeout)},
      else: :ok
  end

  defp in_temp_dir(config, fun) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    # Atomic 0700 creation via umask 077 + mkdir: the prompt file holds the
    # whole conversation, so avoid colliding with or exposing files on shared /tmp.
    with {:ok, base_dir} <- create_temp_dir(parent, "alloy-codex-#{suffix}") do
      try do
        fun.(paths(base_dir, config))
      after
        _ = File.rm_rf(base_dir)
      end
    end
  end

  defp temp_dir_error(reason) do
    %Error{
      kind: :unknown,
      message: "failed to prepare Codex temp directory: #{inspect(reason)}"
    }
  end

  defp paths(base_dir, config) do
    %{
      base_dir: base_dir,
      prompt_path: Path.join(base_dir, "prompt.txt"),
      schema_path: Path.join(base_dir, "response_schema.json"),
      last_message_path: Path.join(base_dir, "last_message.json"),
      stderr_path: Path.join(base_dir, "stderr.log"),
      workdir: Map.get(config, :workdir, base_dir)
    }
  end

  defp resolve_deadline(config) do
    now = System.monotonic_time(:millisecond)
    timeout = effective_timeout(config)
    relative_deadline = now + timeout

    case Map.get(config, :alloy_request_deadline) do
      hard_deadline when is_integer(hard_deadline) ->
        deadline = min(relative_deadline, hard_deadline)

        if deadline <= now do
          {:expired, timeout}
        else
          {:ok, min(timeout, deadline - now), deadline}
        end

      _none ->
        {:ok, timeout, relative_deadline}
    end
  end

  defp effective_timeout(config) do
    [
      Map.get(config, :timeout_ms) || @default_timeout_ms,
      Map.get(config, :receive_timeout),
      config |> Map.get(:req_options, []) |> Keyword.get(:receive_timeout)
    ]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.min()
  end

  defp run_injected(runner, args, codex_home, paths, config) do
    opts = [cd: paths.workdir, env: codex_env(codex_home)]

    case runner.(codex_bin(config), args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, command_result(output, "", status, paths)}

      other ->
        {:error,
         %Error{
           kind: :unknown,
           message: "codex exec returned unexpected result: #{Sanitize.inspect_bounded(other)}"
         }}
    end
  rescue
    error in ErlangError -> {:error, not_runnable(config, Exception.message(error))}
  end

  defp open_port(sh, args, codex_home, paths, config) do
    env =
      Enum.map(codex_env(codex_home), fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    launch_args =
      ["-c", @launch_script, "alloy-codex", paths.prompt_path, paths.stderr_path] ++
        [codex_bin(config) | args]

    Port.open(
      {:spawn_executable, sh},
      [{:args, launch_args}, {:cd, paths.workdir}, {:env, env}, :binary, :exit_status, :use_stdio]
    )
  end

  # The deadline is absolute: checking it before each receive keeps a
  # steady stream of output from postponing the timeout.
  defp collect(run, acc) do
    cond do
      Cancel.cancelled?(run.cancel_token) ->
        :ok = stop(run)
        {:error, cancelled_error()}

      run.deadline <= System.monotonic_time(:millisecond) ->
        time_out(run)

      true ->
        receive_output(run, acc, next_wait_ms(run.deadline, run.cancel_token))
    end
  end

  defp receive_output(%{port: port, caller_ref: caller_ref} = run, acc, wait_ms) do
    receive do
      {^port, {:data, data}} ->
        collect(stream_output(run, data), [acc, data])

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status, run.streamed_text}

      {:DOWN, ^caller_ref, :process, _pid, reason} ->
        :ok = stop(run)

        {:error,
         %Error{
           message:
             "codex exec cancelled: caller exited (#{OwnedWorker.format_exit_reason(reason)})"
         }}

      {:EXIT, from, reason} when is_pid(from) ->
        # Caught by run_port_in_dir/8 which calls stop(run) once before re-raising.
        exit(reason)
    after
      wait_ms ->
        collect(run, acc)
    end
  end

  defp stream_output(%{emit: nil} = run, _data), do: run
  defp stream_output(%{streamed_text: text} = run, _data) when is_binary(text), do: run

  defp stream_output(run, data) do
    consume_lines(:binary.split(data, "\n", [:global]), run)
  end

  defp consume_lines([partial], run),
    do: %{run | stream_buffer: [partial | run.stream_buffer]}

  defp consume_lines([line | rest], run) do
    complete = [line | run.stream_buffer] |> Enum.reverse() |> IO.iodata_to_binary()
    consume_lines(rest, stream_event(complete, %{run | stream_buffer: []}))
  end

  defp stream_event(_line, %{streamed_text: text} = run) when is_binary(text), do: run

  defp stream_event(line, run) do
    case Jason.decode(line) do
      {:ok, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}} ->
        %{run | stream_candidate: run.reply_fn.(text)}

      {:ok, %{"type" => "turn.completed"}} when is_binary(run.stream_candidate) ->
        run.emit.(run.stream_candidate)
        %{run | streamed_text: run.stream_candidate}

      _other ->
        run
    end
  end

  defp time_out(run) do
    :ok = stop(run)
    {:error, timed_out(run.timeout)}
  end

  # SIGTERM, a short grace for codex to exit, then unconditional SIGKILL for
  # the process group so descendants that ignore SIGTERM cannot survive even
  # when the leader exits promptly (ESRCH on an empty group is harmless).
  defp stop(%{os_pid: nil}), do: :ok

  defp stop(%{port: port, os_pid: os_pid}) do
    :ok = OSProcess.signal_group(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @term_grace_ms -> :ok
    end

    OSProcess.signal_group(os_pid, "KILL")
  end

  defp timed_out(timeout),
    do: %Error{kind: :timeout, message: "codex exec timed out after #{timeout}ms"}

  defp read_stderr(paths) do
    case File.read(paths.stderr_path) do
      {:ok, stderr} -> stderr
      {:error, _reason} -> ""
    end
  end

  defp command_result(output, stderr, status, paths) do
    %{
      output: output,
      stderr: stderr,
      status: status,
      events: decode_events(output),
      last_message: File.read(paths.last_message_path)
    }
  end

  # `codex exec --json` writes one event object per line.
  defp decode_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = event} when is_binary(type) -> [event]
        _other -> []
      end
    end)
  end

  defp codex_env(nil), do: [{"OTEL_SDK_DISABLED", "true"}]
  defp codex_env(codex_home), do: [{"OTEL_SDK_DISABLED", "true"}, {"CODEX_HOME", codex_home}]
end
