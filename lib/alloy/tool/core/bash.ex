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
  - `:bash_executor` - an `t:executor/0` that runs the command instead of
    the local shell, for a container, VM or remote runner. The options
    above, except the timeout, do not apply to it.
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

  alias Alloy.OSProcess

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
    max_timeout = Map.get(context, :bash_max_timeout, @max_timeout)
    timeout = normalize_timeout(input["timeout"], max_timeout)
    working_dir = Map.get(context, :working_directory)

    case Map.get(context, :bash_executor) do
      nil -> run_host(command, working_dir, timeout, context)
      executor -> run_custom_executor(executor, command, working_dir, timeout)
    end
  end

  defp run_host(command, working_dir, timeout, context) do
    with {:ok, bash} <- find_bash(),
         :ok <- check_dir(working_dir) do
      flag = if Map.get(context, :bash_restricted, true), do: "-rc", else: "-c"
      env = port_env(Map.get(context, :bash_env, %{}))

      opts =
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: [flag, command], env: env]
        |> maybe_add_cd(working_dir)

      caller = self()

      # The port lives in its own process so the shell is killed even when
      # the caller is: the executor brutally kills a tool's task on
      # :tool_timeout, and closing a port does not stop the shell.
      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          run_port(bash, opts, timeout, caller)
        end)

      case Task.yield(task, timeout + @kill_grace_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:exited, status, output}} -> {:ok, "#{output}\nexit code: #{status}"}
        {:ok, {:timeout, output}} -> {:error, with_output(output, timeout_message(timeout))}
        {:exit, reason} -> {:error, "Executor crashed: #{inspect(reason)}"}
        nil -> {:error, timeout_message(timeout)}
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

  defp run_port(bash, opts, timeout, caller) do
    caller_ref = Process.monitor(caller)
    port = Port.open({:spawn_executable, bash}, opts)

    run = %{
      port: port,
      os_pid: os_pid(port),
      caller_ref: caller_ref,
      deadline: System.monotonic_time(:millisecond) + timeout
    }

    result = collect(run, new_output())
    Process.demonitor(caller_ref, [:flush])
    result
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp collect(%{port: port, caller_ref: caller_ref} = run, output) do
    receive do
      {^port, {:data, data}} ->
        collect(run, append(output, data))

      {^port, {:exit_status, status}} ->
        {:exited, status, render(output)}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        OSProcess.signal_group(run.os_pid, "KILL")
        :caller_down
    after
      max(run.deadline - System.monotonic_time(:millisecond), 0) ->
        OSProcess.signal_group(run.os_pid, "KILL")
        {:timeout, render(output)}
    end
  end

  defp run_custom_executor(executor, command, working_dir, timeout) do
    task =
      Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
        executor.(command, working_dir)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, "#{new_output() |> append(output) |> render()}\nexit code: #{exit_code}"}

      {:exit, reason} ->
        {:error, "Executor crashed: #{inspect(reason)}"}

      nil ->
        {:error, "Command timed out after #{timeout}ms."}
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
