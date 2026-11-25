defmodule Alloy.Tool.Core.Write do
  @moduledoc """
  Built-in tool: write files, creating parent directories as needed.

  Overwrites the target file completely. Parent directories are created
  automatically via `File.mkdir_p!/1`. Paths are resolved against the
  agent's `:working_directory` context.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Write], ...}

  The agent can then call:

      %{file_path: "lib/new_file.ex", content: "defmodule NewFile do\\nend"}
  """

  @behaviour Alloy.Tool

  @impl true
  def name, do: "write"

  @impl true
  def concurrent?, do: false
  @impl true
  def description, do: "Write content to a file. Creates parent directories if needed."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to write"},
        content: %{type: "string", description: "Content to write to the file"}
      },
      required: ["file_path", "content"]
    }
  end

  @impl true
  def execute(input, context) do
    with {:ok, content} <- validate_content(input["content"]),
         {:ok, path} <- Alloy.Tool.resolve_path(input["file_path"], context),
         :ok <- make_parent_dir(path) do
      case File.write(path, content) do
        :ok -> {:ok, "Successfully wrote to #{path}"}
        {:error, reason} -> {:error, "Failed to write to #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp validate_content(content) when is_binary(content), do: {:ok, content}

  defp validate_content(content),
    do:
      {:error,
       "content must be a string, got: #{inspect(content, limit: 20, printable_limit: 500)}"}

  defp make_parent_dir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot create directory: #{inspect(reason)}"}
    end
  end
end
