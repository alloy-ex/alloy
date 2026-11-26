defmodule Alloy.Tool.Core.Bash do
  @moduledoc """
  Built-in tool: execute shell commands via `bash -rc` (restricted shell).

  Returns stdout/stderr merged with the exit code appended. Output is
  capped while the command runs: the first 8,000 and the last 20,000
  bytes are kept (errors usually come last) and the middle is replaced by
  a marker giving the number of bytes left out, so the result fits in
  `max_result_chars/0` and memory stays bounded however much a command
  prints. Commands that exceed the timeout are killed, together with every
  process they started, and return an error.

  ## Context options

  Set these in the agent's `:context` map:

  - `:bash_env` - the command's environment. By default the BEAM's
    environment is inherited *minus* every variable whose name contains
    `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `CREDENTIAL` (case-insensitive),
    so the model cannot `printenv ANTHROPIC_API_KEY`. A map such as
    `%{"GITHUB_TOKEN" => token, "DATABASE_URL" => nil}` is applied on top
    of that: a string sets a variable (even a secret-looking one), `nil`
    removes it. `:inherit` passes the whole environment unchanged (the
    behaviour before 0.12.5).
  - `:bash_restricted` - run `bash -r` (default `true`). See Security.
  - `:bash_max_timeout` - ceiling in milliseconds for the `timeout` the
    model asks for (default 10 minutes). The agent's `:tool_timeout`
    still applies on top of it.
  - `:bash_on_output` - optional 1-arity callback `(binary() -> any())` invoked
    in a dedicated supervised worker for each raw output chunk as it arrives
    from the shell port (before head/tail truncation), allowing hosts to spill
    full output to disk or inspect raw bytes without blocking shell timeout or
    cancellation cleanup. The worker queue is bounded (at most 128 chunks and
    256 KiB queued in memory; excess chunks are dropped under backpressure), and
    command exit waits at most a short flush grace period (`250ms`, clamped to
    the remaining command timeout) so a slow callback never turns a finished
    command into a timeout. Raising callbacks are rescued and logged once per
    command; throws or exits terminate only the callback worker while command
    execution continues.
  - `:bash_executor` - an `t:executor/0` that runs the command instead of
    the local shell, for a container, VM or remote runner. The options
    above, except the timeout, do not apply to it. Custom executors run inside
    a supervised worker that is brutally killed on timeout or cancellation
    (avoid setting `:trap_exit` unless your executor handles termination).
  - `:working_directory` - where the command runs (set by the agent).

  ## Security

  This tool runs arbitrary commands as the operating-system user of the
  BEAM. It is not a sandbox; treat the model's shell access like a
  contractor's laptop on your network.

  - Restricted mode stops the top-level shell from using `cd`, changing
    `PATH`, `SHELL`, `ENV` or `BASH_ENV`, running a command whose name
    contains `/`, and redirecting output. It does not apply to programs
    the shell runs, so `bash -c 'cd / && ...'`, `python3 -c`, `env`,
    `find -exec` and any other interpreter on `PATH` bypass it. It guards
    against accidents, not against a model or a prompt injection that
    tries to escape.
  - `:allowed_paths` limits the read, write and edit tools only; this tool
    ignores it.
  - The secret filter is a name heuristic: a credential stored under
    another name (a `DATABASE_URL` with an embedded password, say) is
    still inherited. Pass an explicit `:bash_env` for anything sensitive.
  - Timeouts kill the command's process group. A command that starts a
    new session (`setsid`, a double-forking daemon) leaves that group and
    survives.

  For isolation, supply a `:bash_executor` that runs commands in a
  container or VM.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Bash], ...}

  The agent can then call:

      %{command: "ls -la", timeout: 5000}
  """

  @behaviour Alloy.Tool

  alias Alloy.Internal.Sanitize
  alias Alloy.{OSProcess, OwnedWorker}

  require Logger

  @typedoc """
  A custom command executor. Receives the shell command string and the working
  directory path, and must return `{output, exit_code}`.

  Supply a custom executor via the `:bash_executor` key in the agent's
  `:context` map to sandbox or proxy shell execution.
  """
  @type executor :: (command :: String.t(), dir :: String.t() -> {String.t(), non_neg_integer()})

  @default_timeout 10_000
  @max_timeout 600_000
  @kill_grace_ms 2_000
  @head_bytes 8_000
  @tail_bytes 20_000

  @impl true
  def name, do: "bash"

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 30_000
  @impl true
  def description, do: "Execute a shell command and return its output."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string", description: "The shell command to execute"},
        timeout: %{
          type: "integer",
          description:
            "Timeout in milliseconds (default: #{@default_timeout}, maximum: #{@max_timeout})",
          default: @default_timeout
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(input, context) do
    command = input["command"]

    with :ok <- validate_command(command) do
      max_timeout = Map.get(context, :bash_max_timeout, @max_timeout)
      timeout = normalize_timeout(input["timeout"], max_timeout)
      working_dir = Map.get(context, :working_directory)

      case Map.get(context, :bash_executor) do
        nil -> run_host(command, working_dir, timeout, context)
        executor -> run_custom_executor(executor, command, working_dir, timeout)
      end
    end
  end

  defp validate_command(command) when is_binary(command) do
    if String.contains?(command, <<0>>) do
      {:error, "command must not contain NUL bytes."}
    else
      :ok
    end
  end

  defp validate_command(command),
    do: {:error, "command must be a string, got: #{Sanitize.inspect_bounded(command)}"}

  defp run_host(command, working_dir, timeout, context) do
    with {:ok, bash} <- find_bash(),
         :ok <- check_dir(working_dir) do
      flag = if Map.get(context, :bash_restricted, true), do: "-rc", else: "-c"
      env = port_env(Map.get(context, :bash_env, %{}))

      opts =
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: [flag, command], env: env]
        |> maybe_add_cd(working_dir)

      caller = self()
      callbacks = extract_output_callbacks(context)

      # The port lives in its own process so the shell is killed even when
      # the caller is: the executor brutally kills a tool's task on
      # :tool_timeout, and closing a port does not stop the shell.
      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          run_port(bash, opts, timeout, caller, callbacks)
        end)

      result = Task.yield(task, timeout + @kill_grace_ms) || Task.shutdown(task, :brutal_kill)
      os_pid = take_os_pid(task.pid)

      case result do
        {:ok, {:exited, status, output}} ->
          {:ok, "#{output}\nexit code: #{status}"}

        {:ok, {:timeout, output}} ->
          {:error, with_output(output, timeout_message(timeout))}

        {:exit, reason} ->
          OSProcess.signal_group(os_pid, "KILL")
          {:error, "Executor crashed: #{OwnedWorker.format_exit_reason(reason)}"}

        # The runner missed its own deadline and was killed before it could
        # stop the shell, so stop it here.
        nil ->
          OSProcess.signal_group(os_pid, "KILL")
          {:error, timeout_message(timeout)}
      end
    end
  end

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, "bash was not found on PATH."}
      bash -> {:ok, bash}
    end
  end

  defp check_dir(nil), do: :ok

  defp check_dir(dir) do
    if File.dir?(dir), do: :ok, else: {:error, "Working directory does not exist: #{dir}"}
  end

  defp with_output("", message), do: message
  defp with_output(output, message), do: output <> "\n\n" <> message

  defp timeout_message(timeout) do
    "Command timed out after #{timeout}ms. The process may have started a server, " <>
      "entered an infinite loop, or is waiting for input. Try a non-blocking approach."
  end

  # Alloy usually runs inside a server whose environment holds its own
  # provider keys and database credentials; the model should not be able
  # to `printenv` them. Names are matched case-insensitively.
  @secret_name_parts ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"]

  defp port_env(:inherit), do: []

  defp port_env(overrides) when is_map(overrides) do
    overrides = Map.new(overrides, fn {name, value} -> {to_string(name), value} end)

    scrubbed =
      for {name, _value} <- System.get_env(),
          secret_name?(name),
          not Map.has_key?(overrides, name),
          do: {name, nil}

    Enum.map(scrubbed ++ Map.to_list(overrides), fn
      {name, nil} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp secret_name?(name) do
    name = String.upcase(name)
    Enum.any?(@secret_name_parts, &String.contains?(name, &1))
  end

  defp extract_output_callbacks(context) do
    on_tool_update =
      case Map.get(context, :on_tool_update) do
        fun when is_function(fun, 1) -> fun
        _ -> nil
      end

    bash_on_output =
      case Map.get(context, :bash_on_output) do
        fun when is_function(fun, 1) -> fun
        _ -> nil
      end

    %{
      on_tool_update: on_tool_update,
      bash_on_output: bash_on_output
    }
  end

  @output_worker_max_chunks 128
  @output_worker_max_bytes 262_144
  @output_flush_grace_ms 250

  defp run_port(bash, opts, timeout, caller, callbacks) do
    # Trapping exits lets a supervisor shutdown stop the shell process group too.
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)

    receive do
      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        :caller_down

      {:EXIT, from, reason} when is_pid(from) ->
        Process.demonitor(caller_ref, [:flush])
        exit(reason)
    after
      0 ->
        port = Port.open({:spawn_executable, bash}, opts)
        output_worker = start_output_worker(callbacks.bash_on_output)

        run = %{
          port: port,
          os_pid: OSProcess.os_pid(port),
          caller_ref: caller_ref,
          deadline: System.monotonic_time(:millisecond) + timeout,
          on_tool_update: callbacks.on_tool_update,
          utf8_carry: <<>>,
          output_worker: output_worker
        }

        send(caller, {:bash_os_pid, self(), run.os_pid})

        try do
          collect(run, new_output())
        catch
          kind, reason ->
            OSProcess.signal_group(run.os_pid, "KILL")
            kill_output_worker(run.output_worker)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          Process.demonitor(caller_ref, [:flush])
        end
    end
  end

  # Flushes the runner's start message in every outcome; the pid is only
  # needed when the runner itself had to be killed.
  defp take_os_pid(runner) do
    receive do
      {:bash_os_pid, ^runner, os_pid} -> os_pid
    after
      0 -> nil
    end
  end

  # The deadline is absolute and checked before each receive, so a steady
  # stream of output can't postpone the timeout.
  defp collect(run, output) do
    case run.deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> receive_output(run, output, remaining)
      _expired -> time_out(run, output)
    end
  end

  defp receive_output(%{port: port, caller_ref: caller_ref} = run, output, remaining) do
    receive do
      {^port, {:data, data}} ->
        utf8_carry = emit_utf8_update(run.on_tool_update, run.utf8_carry, data)
        dispatch_bash_on_output(run.output_worker, data)
        collect(%{run | utf8_carry: utf8_carry}, append(output, data))

      {^port, {:exit_status, status}} ->
        flush_utf8_carry(run.on_tool_update, run.utf8_carry)

        case flush_output_worker(run.output_worker, run.caller_ref, run.deadline) do
          :ok ->
            {:exited, status, render(output)}

          :caller_down ->
            :caller_down

          {:exit, reason} ->
            Process.demonitor(caller_ref, [:flush])
            exit(reason)
        end

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        OSProcess.signal_group(run.os_pid, "KILL")
        kill_output_worker(run.output_worker)
        :caller_down

      {:EXIT, from, reason} when is_pid(from) ->
        OSProcess.signal_group(run.os_pid, "KILL")
        kill_output_worker(run.output_worker)
        Process.demonitor(caller_ref, [:flush])
        exit(reason)
    after
      remaining -> time_out(run, output)
    end
  end

  defp time_out(run, output) do
    OSProcess.signal_group(run.os_pid, "KILL")
    kill_output_worker(run.output_worker)
    flush_utf8_carry(run.on_tool_update, run.utf8_carry)
    {:timeout, render(output)}
  end

  # Runs :bash_on_output in its own supervised worker so a blocking callback
  # never prevents run_port from enforcing timeouts or killing the OS process
  # group on caller death. Monitors run_port so the worker exits immediately if
  # run_port crashes or is brutally killed, and bounds queued chunks/bytes so
  # verbose commands with a slow callback cannot exhaust memory.
  defp start_output_worker(nil), do: nil

  defp start_output_worker(fun) when is_function(fun, 1) do
    owner = self()
    # Slot 1: queued chunks, Slot 2: queued bytes
    budget = :atomics.new(2, signed: false)

    {:ok, pid} =
      Task.Supervisor.start_child(Alloy.TaskSupervisor, fn ->
        owner_ref = Process.monitor(owner)
        output_worker_loop(fun, owner_ref, budget, false)
      end)

    ref = Process.monitor(pid)
    {pid, ref, budget}
  end

  defp output_worker_loop(fun, owner_ref, budget, logged?) do
    receive do
      {:chunk, data} ->
        :atomics.sub(budget, 1, 1)
        :atomics.sub(budget, 2, byte_size(data))
        next_logged? = invoke_bash_on_output(fun, data, logged?)
        output_worker_loop(fun, owner_ref, budget, next_logged?)

      {:flush, from, ref} ->
        Process.demonitor(owner_ref, [:flush])
        send(from, {:output_worker_flushed, ref})
        :ok

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok
    end
  end

  defp invoke_bash_on_output(fun, data, logged?) do
    fun.(data)
    logged?
  rescue
    exception ->
      if not logged? do
        sanitized_trace = Sanitize.stacktrace(__STACKTRACE__)

        Logger.warning(
          "[Alloy.Tool.Core.Bash] :bash_on_output callback failed (#{Sanitize.exception_summary(exception, 500)}); command continues (further failures suppressed).\n" <>
            Exception.format_stacktrace(sanitized_trace)
        )
      end

      true
  end

  defp dispatch_bash_on_output(nil, _data), do: :ok

  defp dispatch_bash_on_output({pid, _ref, budget}, data) do
    size = byte_size(data)
    chunks = :atomics.add_get(budget, 1, 1)
    bytes = :atomics.add_get(budget, 2, size)

    if chunks <= @output_worker_max_chunks and bytes <= @output_worker_max_bytes do
      send(pid, {:chunk, data})
      :ok
    else
      :atomics.sub(budget, 1, 1)
      :atomics.sub(budget, 2, size)
      :ok
    end
  end

  defp flush_output_worker(nil, _caller_ref, _deadline), do: :ok

  defp flush_output_worker({pid, mon_ref, _budget} = worker, caller_ref, deadline) do
    flush_ref = make_ref()
    send(pid, {:flush, self(), flush_ref})
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    grace = min(remaining, @output_flush_grace_ms)

    receive do
      {:output_worker_flushed, ^flush_ref} ->
        Process.demonitor(mon_ref, [:flush])
        :ok

      {:DOWN, ^mon_ref, :process, ^pid, _reason} ->
        :ok

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        kill_output_worker(worker)
        :caller_down

      {:EXIT, from, reason} when is_pid(from) ->
        kill_output_worker(worker)
        {:exit, reason}
    after
      grace ->
        kill_output_worker(worker)
        :ok
    end
  end

  defp kill_output_worker(nil), do: :ok

  defp kill_output_worker({pid, mon_ref, _budget}) do
    Process.exit(pid, :kill)
    Process.demonitor(mon_ref, [:flush])
    :ok
  end

  # Carries incomplete trailing multibyte UTF-8 sequences across port chunks so
  # split codepoints (e.g. "€" split across reads) render cleanly in :tool_update.
  defp emit_utf8_update(nil, _carry, _data), do: <<>>

  defp emit_utf8_update(fun, carry, data) do
    {ready, next_carry} = split_complete_utf8(carry <> data, [])
    if byte_size(ready) > 0, do: fun.(ready)
    next_carry
  end

  defp flush_utf8_carry(nil, _carry), do: :ok
  defp flush_utf8_carry(_fun, <<>>), do: :ok
  defp flush_utf8_carry(fun, carry), do: fun.(String.replace_invalid(carry))

  defp split_complete_utf8(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  defp split_complete_utf8(bin, acc) do
    case :unicode.characters_to_binary(bin) do
      valid when is_binary(valid) ->
        {IO.iodata_to_binary(Enum.reverse([valid | acc])), <<>>}

      {:incomplete, valid, rest} ->
        {IO.iodata_to_binary(Enum.reverse([valid | acc])), rest}

      {:error, valid, <<_bad, rest::binary>>} ->
        split_complete_utf8(rest, ["\uFFFD", valid | acc])
    end
  end

  # Runs the custom executor inside a linked worker owned by a supervised task
  # that monitors the caller before starting the worker and propagates Logger
  # metadata and OpenTelemetry context.
  defp run_custom_executor(executor, command, working_dir, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    owner = OwnedWorker.start(deadline, fn -> executor.(command, working_dir) end)

    case Task.yield(owner, timeout + 1_000) do
      {:ok, {:ok, {output, exit_code}}} when is_binary(output) and is_integer(exit_code) ->
        {:ok, "#{new_output() |> append(output) |> render()}\nexit code: #{exit_code}"}

      {:ok, {:ok, other}} ->
        {:error,
         "Custom bash executor returned invalid result: #{Sanitize.inspect_bounded(other)}"}

      {:ok, {:worker_exit, {:worker_crash, kind, reason, stacktrace}}} ->
        {:error, "Executor crashed: #{Sanitize.crash_summary(kind, reason, stacktrace)}"}

      {:ok, {:worker_exit, reason}} ->
        {:error, "Executor crashed: #{OwnedWorker.format_exit_reason(reason)}"}

      {:exit, reason} ->
        {:error, "Executor crashed: #{OwnedWorker.format_exit_reason(reason)}"}

      {:ok, :timeout} ->
        {:error, timeout_message(timeout)}

      nil ->
        OwnedWorker.cancel(owner)
        {:error, timeout_message(timeout)}
    end
  end

  defp maybe_add_cd(opts, nil), do: opts
  defp maybe_add_cd(opts, dir), do: [{:cd, dir} | opts]

  defp normalize_timeout(timeout, max) when is_integer(timeout) and timeout > 0,
    do: min(timeout, max)

  defp normalize_timeout(_timeout, max), do: min(@default_timeout, max)

  # Output is capped as it streams: the first @head_bytes and the last
  # @tail_bytes are kept and the middle is only counted, so a command that
  # prints gigabytes costs a few chunks of memory. Errors usually come
  # last, so most of the budget goes to the tail. The result (plus the
  # marker and exit code) stays under max_result_chars/0, so the executor
  # never truncates it a second time.
  defp new_output, do: %{head: "", tail: [], tail_size: 0, total: 0}

  defp append(output, data) do
    output = %{output | total: output.total + byte_size(data)}
    room = @head_bytes - byte_size(output.head)

    case data do
      <<to_head::binary-size(^room), rest::binary>> ->
        append_tail(%{output | head: output.head <> to_head}, rest)

      _fits_in_head ->
        %{output | head: output.head <> data}
    end
  end

  defp append_tail(output, ""), do: output

  defp append_tail(output, data) do
    size = output.tail_size + byte_size(data)

    if size > 2 * @tail_bytes do
      tail = last_bytes(IO.iodata_to_binary([output.tail, data]), @tail_bytes)
      %{output | tail: tail, tail_size: @tail_bytes}
    else
      %{output | tail: [output.tail, data], tail_size: size}
    end
  end

  defp render(%{head: head, tail: tail, total: total}) do
    tail = last_bytes(IO.iodata_to_binary(tail), @tail_bytes)

    text =
      case total - byte_size(head) - byte_size(tail) do
        0 -> head <> tail
        omitted -> head <> "\n\n[... #{omitted} bytes of output truncated ...]\n\n" <> tail
      end

    # A cut can split a multibyte character; the result must stay UTF-8.
    String.replace_invalid(text)
  end

  defp last_bytes(binary, n) when byte_size(binary) > n,
    do: binary_part(binary, byte_size(binary) - n, n)

  defp last_bytes(binary, _n), do: binary
end
