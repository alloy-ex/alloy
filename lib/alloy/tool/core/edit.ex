defmodule Alloy.Tool.Core.Edit do
  @moduledoc """
  Built-in tool: search-and-replace edits on files.

  Finds `old_string` in the file and replaces it with `new_string`.
  By default, the match must be unique (appears exactly once). Set
  `replace_all: true` to replace all occurrences. Returns an error
  if no match is found, if the match is ambiguous, if `old_string` is
  empty, or if the edit would change nothing.

  Matching ignores the difference between CRLF and LF, and the file keeps
  its line endings and any UTF-8 byte order mark.

  ## Usage

      config = %{tools: [Alloy.Tool.Core.Edit], ...}

  The agent can then call:

      %{file_path: "lib/app.ex", old_string: "v1", new_string: "v2"}
  """

  @behaviour Alloy.Tool

  alias Alloy.Internal.Sanitize

  @binary_sniff_bytes 8_192
  @max_file_bytes 10 * 1024 * 1024

  @impl true
  def name, do: "edit"

  @impl true
  def concurrent?, do: false
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
    with {:ok, replace_all} <- parse_replace_all(input["replace_all"]),
         {:ok, old_string, new_string} <- strings(input["old_string"], input["new_string"]),
         {:ok, path} <- Alloy.Tool.resolve_path(input["file_path"], context),
         {:ok, raw} <- read_file(path) do
      # The model works from `read` output and writes LF without a BOM, so
      # match on LF text and put the file's BOM and line endings back.
      {bom, content} = split_bom(raw)
      ending = line_ending(content)

      with {:ok, edited} <- do_replace(to_lf(content), old_string, new_string, replace_all) do
        write_file(path, bom <> from_lf(edited, ending))
      end
    end
  end

  defp parse_replace_all(nil), do: {:ok, false}
  defp parse_replace_all(value) when is_boolean(value), do: {:ok, value}

  defp parse_replace_all(value),
    do: {:error, "replace_all must be a boolean, got: #{Sanitize.inspect_bounded(value)}"}

  defp strings(old_string, new_string) when is_binary(old_string) and is_binary(new_string) do
    case {to_lf(old_string), to_lf(new_string)} do
      {"", _new} ->
        {:error,
         "old_string must not be empty. Use the write tool to create or overwrite a file."}

      {same, same} ->
        {:error, "old_string and new_string are identical; the edit would change nothing."}

      {old, new} ->
        {:ok, old, new}
    end
  end

  defp strings(_old_string, _new_string),
    do: {:error, "old_string and new_string must be strings."}

  defp read_file(path) do
    with :ok <- check_file_bounds(path),
         {:ok, content} <- read_bounded(path) do
      head = binary_part(content, 0, min(byte_size(content), @binary_sniff_bytes))

      if String.contains?(head, <<0>>) do
        {:error, "#{path} is a binary file; edit only supports text files."}
      else
        {:ok, content}
      end
    end
  end

  defp check_file_bounds(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        :ok

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, "Cannot edit #{path}: file is #{size} bytes (max #{@max_file_bytes} bytes)."}

      {:ok, _other} ->
        {:error, "Cannot read #{path}: not a regular file"}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      {:ok, :eof} ->
        {:ok, ""}

      {:ok, {:error, reason}} ->
        {:error, "Cannot read #{path}: #{reason}"}

      {:ok, content} when is_binary(content) and byte_size(content) > @max_file_bytes ->
        {:error, "Cannot edit #{path}: file exceeds #{@max_file_bytes} bytes."}

      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> {:ok, "Successfully edited #{path}"}
      {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
    end
  end

  defp split_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {<<0xEF, 0xBB, 0xBF>>, rest}
  defp split_bom(content), do: {"", content}

  # The first line ending decides, as in pi and most editors.
  defp line_ending(content) do
    case :binary.match(content, "\n") do
      {pos, _} when pos > 0 and binary_part(content, pos - 1, 1) == "\r" -> "\r\n"
      _lf_or_single_line -> "\n"
    end
  end

  defp to_lf(text), do: String.replace(text, "\r\n", "\n")

  defp from_lf(text, "\r\n"), do: String.replace(text, "\n", "\r\n")
  defp from_lf(text, "\n"), do: text

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
    length(String.split(content, substring)) - 1
  end
end
