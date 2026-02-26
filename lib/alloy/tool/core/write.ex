defmodule Alloy.Tool.Core.Write do
  @moduledoc "Writes content to a file, creating parent directories as needed."

  @behaviour Alloy.Tool

  @impl true
  def name, do: "write"

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
    path = Alloy.Tool.resolve_path(input["file_path"], context)

    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, input["content"]) do
      :ok ->
        {:ok, "Successfully wrote to #{path}"}

      {:error, reason} ->
        {:error, "Failed to write to #{path}: #{reason}"}
    end
  end
end
