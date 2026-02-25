defmodule Anvil.Tool.Core.Bash do
  @moduledoc "Executes shell commands and returns stdout/stderr with exit code."

  @behaviour Anvil.Tool

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

    opts =
      [stderr_to_stdout: true]
      |> maybe_add_cd(working_dir)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        output = truncate(output)
        {:ok, "#{output}\nexit code: #{exit_code}"}

      nil ->
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp maybe_add_cd(opts, nil), do: opts
  defp maybe_add_cd(opts, dir), do: Keyword.put(opts, :cd, dir)

  defp truncate(output) when byte_size(output) > @max_output do
    String.slice(output, 0, @max_output) <> "\n... (output truncated)"
  end

  defp truncate(output), do: output
end
