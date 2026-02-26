defmodule Alloy.Tool.Core.Read do
  @moduledoc "Reads a file and returns contents with line numbers."

  @behaviour Alloy.Tool

  @default_limit 2000

  @impl true
  def name, do: "read"

  @impl true
  def description, do: "Read a file from the filesystem. Returns contents with line numbers."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to read"},
        offset: %{type: "integer", description: "Line number to start reading from (1-based)"},
        limit: %{type: "integer", description: "Maximum number of lines to return"}
      },
      required: ["file_path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = Alloy.Tool.resolve_path(input["file_path"], context)
    offset = input["offset"] || 1
    limit = input["limit"] || @default_limit

    case File.read(path) do
      {:ok, content} ->
        result =
          content
          |> String.split("\n")
          |> maybe_drop_trailing_empty()
          |> Enum.with_index(1)
          |> Enum.drop(offset - 1)
          |> Enum.take(limit)
          |> format_lines()

        {:ok, result}

      {:error, reason} ->
        {:error, "File does not exist or cannot be read: #{path} (#{reason})"}
    end
  end

  defp maybe_drop_trailing_empty(lines) do
    if List.last(lines) == "", do: List.delete_at(lines, -1), else: lines
  end

  defp format_lines(numbered_lines) do
    max_num = numbered_lines |> List.last() |> elem(1)
    width = max(String.length(Integer.to_string(max_num)), 6)

    numbered_lines
    |> Enum.map_join("\n", fn {line, num} ->
      num_str = Integer.to_string(num) |> String.pad_leading(width)
      "#{num_str}\t#{line}"
    end)
    |> Kernel.<>("\n")
  end
end
