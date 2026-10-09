defmodule Alloy.Tool.Core.Read do
  @moduledoc """
  Built-in tool: read files with line numbers.

  Returns file contents formatted as `line_number\\tcontent` (matching
  `cat -n` output). Supports pagination via `:offset` (1-based) and
  `:limit` parameters, defaulting to the first 2,000 lines. Output stops
  at a whole line before `max_result_chars/0`; whenever lines remain, it
  ends with `[Showing lines X-Y of N. Use offset=Z to continue.]`.

  Binary files (a NUL byte in the first 8KB) are refused.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Read], ...}

  The agent can then call:

      %{file_path: "lib/app.ex", offset: 10, limit: 50}
  """

  @behaviour Alloy.Tool

  @default_limit 2000
  @binary_sniff_bytes 8_192
  @max_result_chars 50_000
  # Leaves room for the continuation hint.
  @max_output_bytes @max_result_chars - 200

  @impl true
  def name, do: "read"

  @impl true
  def max_result_chars, do: @max_result_chars
  @impl true
  def description, do: "Read a file from the filesystem. Returns contents with line numbers."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to read"},
        offset: %{
          type: "integer",
          description: "Line number to start reading from (1-based, default 1)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of lines to return (default #{@default_limit})"
        }
      },
      required: ["file_path"]
    }
  end

  @impl true
  def execute(input, context) do
    with {:ok, offset} <- positive_integer(input["offset"], "offset", 1),
         {:ok, limit} <- positive_integer(input["limit"], "limit", @default_limit),
         {:ok, path} <- Alloy.Tool.resolve_path(input["file_path"], context),
         :ok <- check_text_file(path) do
      read_lines(path, offset, limit)
    end
  end

  defp positive_integer(nil, _name, default), do: {:ok, default}

  defp positive_integer(value, _name, _default) when is_integer(value) and value >= 1,
    do: {:ok, value}

  defp positive_integer(value, name, _default),
    do:
      {:error,
       "#{name} must be an integer >= 1 (lines are numbered from 1), got: #{inspect(value)}"}

  defp check_text_file(path) do
    if File.regular?(path),
      do: check_not_binary(path),
      else: {:error, "File does not exist or is not a readable file: #{path}"}
  end

  # Same heuristic as git and grep: a NUL byte near the start means binary.
  defp check_not_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @binary_sniff_bytes)) do
      {:ok, head} when is_binary(head) ->
        if String.contains?(head, <<0>>),
          do: {:error, "#{path} is a binary file; read only returns text files."},
          else: :ok

      {:ok, _eof} ->
        :ok

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # One streaming pass: keeps the requested window (up to the output
  # budget) and counts every line, so the hint can give the total.
  defp read_lines(path, offset, limit) do
    last_wanted = offset + limit - 1
    width = number_width(last_wanted)

    window =
      path
      |> File.stream!()
      |> Stream.with_index(1)
      |> Enum.reduce(%{shown: [], bytes: 0, full?: false, total: 0}, fn {line, n}, acc ->
        take_line(%{acc | total: n}, line, n, offset..last_wanted//1, width)
      end)

    render(window, offset)
  end

  defp take_line(%{full?: true} = acc, _line, _n, _wanted, _width), do: acc

  defp take_line(acc, line, n, wanted, width) do
    cost = width + 1 + byte_size(line)

    cond do
      n not in wanted -> acc
      acc.shown != [] and acc.bytes + cost > @max_output_bytes -> %{acc | full?: true}
      true -> %{acc | shown: [{line, n} | acc.shown], bytes: acc.bytes + cost}
    end
  end

  defp render(%{total: total}, offset) when offset > max(total, 1) do
    {:error,
     "Offset #{offset} is beyond the end of the file (#{total} lines). " <>
       "Use an offset between 1 and #{max(total, 1)}."}
  end

  defp render(%{shown: []}, _offset), do: {:ok, ""}

  defp render(%{shown: [{_line, last} | _] = shown, total: total}, offset) do
    text = shown |> Enum.reverse() |> format_lines()

    if last < total do
      {:ok,
       text <>
         "\n[Showing lines #{offset}-#{last} of #{total}. Use offset=#{last + 1} to continue.]"}
    else
      {:ok, text}
    end
  end

  defp number_width(n), do: max(String.length(Integer.to_string(n)), 6)

  defp format_lines(numbered_lines) do
    {_line, max_num} = List.last(numbered_lines)
    width = number_width(max_num)

    Enum.map_join(numbered_lines, fn {line, num} ->
      String.pad_leading(Integer.to_string(num), width) <> "\t" <> display(line) <> "\n"
    end)
  end

  # Latin-1 and other non-UTF-8 text has no NUL byte, so it is not
  # refused as binary; its invalid bytes become U+FFFD so the result is
  # always valid UTF-8, even when read is called outside the executor.
  defp display(line) do
    line
    |> String.replace_suffix("\n", "")
    |> String.replace_suffix("\r", "")
    |> String.replace_invalid()
  end
end
