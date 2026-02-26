defmodule Alloy.Tool.Core.Bash do
  @moduledoc """
  Built-in tool: execute shell commands via `bash -c`.

  Returns stdout/stderr merged with the exit code appended. Output is
  truncated at 30,000 characters to prevent context overflow.
  Commands that exceed the timeout are killed and return an error.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Bash], ...}

  The agent can then call:

      %{command: "ls -la", timeout: 5000}
  """

  @behaviour Alloy.Tool

  @typedoc """
  A custom command executor. Receives the shell command string and the working
  directory path, and must return `{output, exit_code}`.

  The default executor calls `System.cmd/3`. Supply a custom executor via
  the `:bash_executor` key in the agent's `:context` map to sandbox or
  proxy shell execution.
  """
  @type executor :: (command :: String.t(), dir :: String.t() -> {String.t(), non_neg_integer()})

  @default_timeout 120_000
  @max_output 30_000

  @impl true
  def name, do: "bash"

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
          description: "Timeout in milliseconds (default: 120000)",
          default: @default_timeout
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(input, context) do
    command = input["command"]
    timeout = input["timeout"] || @default_timeout
    working_dir = Map.get(context, :working_directory)
    executor = Map.get(context, :bash_executor)

    if executor do
      run_custom_executor(executor, command, working_dir, timeout)
    else
      run_host(command, working_dir, timeout)
    end
  end

  defp run_host(command, working_dir, timeout) do
    opts =
      [stderr_to_stdout: true]
      |> maybe_add_cd(working_dir)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, "#{truncate(output)}\nexit code: #{exit_code}"}

      {:exit, reason} ->
        {:error, "Executor crashed: #{inspect(reason)}"}

      nil ->
        {:error,
         "Command timed out after #{timeout}ms. The process may have started a server, entered an infinite loop, or is waiting for input. Try a non-blocking approach."}
    end
  end

  defp run_custom_executor(executor, command, working_dir, timeout) do
    task = Task.async(fn -> executor.(command, working_dir) end)

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
  defp maybe_add_cd(opts, dir), do: Keyword.put(opts, :cd, dir)

  defp truncate(output) when byte_size(output) > @max_output do
    String.slice(output, 0, @max_output) <> "\n... (output truncated)"
  end

  defp truncate(output), do: output
end
