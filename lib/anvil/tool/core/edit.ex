defmodule Anvil.Tool.Core.Edit do
  @moduledoc "Performs search-and-replace edits on files."

  @behaviour Anvil.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description, do: "Search and replace text in a file."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to edit"},
        old_string: %{type: "string", description: "The text to find and replace"},
        new_string: %{type: "string", description: "The replacement text"},
        replace_all: %{
          type: "boolean",
          description: "Replace all occurrences (default: false)",
          default: false
        }
      },
      required: ["file_path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(input, context) do
    path = Anvil.Tool.resolve_path(input["file_path"], context)
    old_string = input["old_string"]
    new_string = input["new_string"]
    replace_all = input["replace_all"] || false

    with {:ok, content} <- read_file(path),
         {:ok, new_content} <- do_replace(content, old_string, new_string, replace_all) do
      case File.write(path, new_content) do
        :ok -> {:ok, "Successfully edited #{path}"}
        {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  defp do_replace(content, old_string, new_string, replace_all) do
    count = count_occurrences(content, old_string)

    cond do
      count == 0 ->
        {:error, "No match found for the provided old_string in the file."}

      count > 1 and not replace_all ->
        {:error,
         "old_string appears #{count} times (ambiguous). Use replace_all: true to replace all occurrences."}

      replace_all ->
        {:ok, String.replace(content, old_string, new_string)}

      true ->
        {:ok, String.replace(content, old_string, new_string, global: false)}
    end
  end

  defp count_occurrences(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
