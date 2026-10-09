defmodule Alloy.Tool.Core.Bash do
  @moduledoc """
  Built-in tool: execute shell commands via `bash -rc` (restricted shell).

  Returns stdout/stderr merged with the exit code appended. Output is
  truncated at 30,000 characters to prevent context overflow.
  Commands that exceed the timeout are killed, together with every
  process they started, and return an error. The model's `timeout` is
  capped at 10 minutes, or at `:bash_max_timeout` (milliseconds) from the
  agent's `:context`.

  ## Security

  By default, commands run in restricted bash (`bash -r`), which prevents:
  - Changing directories with `cd`
  - Setting or unsetting `SHELL`, `ENV`, `BASH_ENV`, or `PATH`
  - Specifying commands containing `/`
  - Redirecting output with `>`, `>>`, etc.

  Set `:bash_restricted` to `false` in the agent's `:context` map to
  disable restricted mode.

  Configure `:allowed_paths` in context to restrict file tool access.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Bash], ...}

  The agent can then call:

      %{command: "ls -la", timeout: 5000}
  """

  @behaviour Alloy.Tool

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
  @max_output 30_000

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
      nil -> run_host(command, working_dir, timeout, Map.get(context, :bash_restricted, true))
      executor -> run_custom_executor(executor, command, working_dir, timeout)
    end
  end

  defp run_host(command, working_dir, timeout, restricted?) do
    with {:ok, bash} <- find_bash(),
         :ok <- check_dir(working_dir) do
      args = [if(restricted?, do: "-rc", else: "-c"), command]
      caller = self()

      # The port lives in its own process so the shell is killed even when
      # the caller is: the executor brutally kills a tool's task on
      # :tool_timeout, and closing a port does not stop the shell.
      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          run_port(bash, args, working_dir, timeout, caller)
        end)

      case Task.yield(task, timeout + @kill_grace_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:exited, status, output}} -> {:ok, "#{truncate(output)}\nexit code: #{status}"}
        {:ok, {:timeout, _output}} -> {:error, timeout_message(timeout)}
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

  defp timeout_message(timeout) do
    "Command timed out after #{timeout}ms. The process may have started a server, " <>
      "entered an infinite loop, or is waiting for input. Try a non-blocking approach."
  end

  defp run_port(bash, args, working_dir, timeout, caller) do
    caller_ref = Process.monitor(caller)

    opts =
      maybe_add_cd([:binary, :exit_status, :stderr_to_stdout, :hide, args: args], working_dir)

    port = Port.open({:spawn_executable, bash}, opts)

    run = %{
      port: port,
      os_pid: os_pid(port),
      caller_ref: caller_ref,
      deadline: System.monotonic_time(:millisecond) + timeout
    }

    result = collect(run, [])
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
        collect(run, [output | data])

      {^port, {:exit_status, status}} ->
        {:exited, status, IO.iodata_to_binary(output)}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        kill_group(run.os_pid)
        :caller_down
    after
      max(run.deadline - System.monotonic_time(:millisecond), 0) ->
        kill_group(run.os_pid)
        {:timeout, IO.iodata_to_binary(output)}
    end
  end

  # Every port program is a session and process-group leader (OTP's
  # erl_child_setup calls setsid()), so signalling the negative pid kills
  # the shell and every process it started, background jobs included.
  # bash's builtin kill avoids depending on a separate kill binary.
  defp kill_group(nil), do: :ok

  defp kill_group(os_pid) do
    {_output, _status} =
      System.cmd("bash", ["-c", "kill -KILL -- -#{os_pid}"], stderr_to_stdout: true)

    :ok
  end

  defp run_custom_executor(executor, command, working_dir, timeout) do
    task =
      Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
        executor.(command, working_dir)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, "#{truncate(output)}\nexit code: #{exit_code}"}

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

  defp truncate(output) when byte_size(output) > @max_output do
    String.slice(output, 0, @max_output) <> "\n... (output truncated)"
  end

  defp truncate(output), do: output
end
