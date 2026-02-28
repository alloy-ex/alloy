defmodule Alloy.Tool.Core.Read do
  @moduledoc """
  Built-in tool: read files with line numbers.

  Returns file contents formatted as `line_number\\tcontent` (matching
  `cat -n` output). Supports pagination via `:offset` and `:limit`
  parameters, defaulting to the first 2,000 lines.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Read], ...}

  The agent can then call:

      %{file_path: "lib/app.ex", offset: 10, limit: 50}
  """

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

    if File.regular?(path) do
      lines =
        path
        |> File.stream!()
        |> Stream.map(&String.trim_trailing(&1, "\n"))
        |> Stream.with_index(1)
        |> Stream.drop(offset - 1)
        |> Stream.take(limit)
        |> Enum.to_list()

      if lines == [] do
        {:ok, ""}
      else
        {:ok, format_lines(lines)}
      end
    else
      {:error, "File does not exist or is not a readable file: #{path}"}
    end
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
