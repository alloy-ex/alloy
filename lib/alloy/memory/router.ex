defmodule Alloy.Memory.Router do
  @moduledoc false
  # Runs one memory tool command against an `Alloy.Memory` store: path
  # checks, the root guards, view_range and the optional new_str all follow
  # Anthropic's memory tool contract, so stores only handle storage.

  alias Alloy.Memory

  @root "/memories"

  @doc """
  Runs the command in `input` against the `{module, store}` binding.
  """
  @spec dispatch({module(), Memory.store()}, map()) :: {:ok, String.t()} | {:error, String.t()}
  def dispatch({module, store}, input) when is_atom(module) and is_map(input) do
    case execute(module, store, input) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp execute(module, store, %{"command" => "view", "path" => path} = input) do
    with {:ok, path} <- Memory.validate_path(path),
         {:ok, range} <- view_range(input["view_range"]),
         {:ok, text} <- module.view(store, path) do
      slice_lines(text, range)
    end
  end

  defp execute(module, store, %{
         "command" => "create",
         "path" => path,
         "file_text" => file_text
       })
       when is_binary(file_text) do
    with {:ok, path} <- Memory.validate_path(path) do
      module.create(store, path, file_text)
    end
  end

  # new_str is optional in the memory tool contract; omitting it deletes
  # old_str.
  defp execute(module, store, %{"command" => "str_replace", "new_str" => nil} = input),
    do: execute(module, store, %{input | "new_str" => ""})

  defp execute(module, store, %{"command" => "str_replace"} = input)
       when not is_map_key(input, "new_str"),
       do: execute(module, store, Map.put(input, "new_str", ""))

  defp execute(module, store, %{
         "command" => "str_replace",
         "path" => path,
         "old_str" => old_str,
         "new_str" => new_str
       })
       when is_binary(old_str) and is_binary(new_str) do
    with {:ok, path} <- Memory.validate_path(path) do
      module.str_replace(store, path, old_str, new_str)
    end
  end

  defp execute(module, store, %{
         "command" => "insert",
         "path" => path,
         "insert_line" => insert_line,
         "insert_text" => insert_text
       })
       when is_integer(insert_line) and insert_line >= 0 and is_binary(insert_text) do
    with {:ok, path} <- Memory.validate_path(path) do
      module.insert(store, path, insert_line, insert_text)
    end
  end

  defp execute(module, store, %{"command" => "delete", "path" => path}) do
    case Memory.validate_path(path) do
      {:ok, @root} -> {:error, "Cannot delete the #{@root} directory itself."}
      {:ok, path} -> module.delete(store, path)
      {:error, _reason} = error -> error
    end
  end

  defp execute(module, store, %{
         "command" => "rename",
         "old_path" => old_path,
         "new_path" => new_path
       }) do
    with {:ok, old_path} <- Memory.validate_path(old_path),
         {:ok, new_path} <- Memory.validate_path(new_path) do
      rename(module, store, old_path, new_path)
    end
  end

  defp execute(_module, _store, input) do
    {:error, "invalid memory tool input: #{inspect(input)}"}
  end

  defp rename(_module, _store, old_path, new_path) when @root in [old_path, new_path],
    do: {:error, "Cannot rename the #{@root} directory itself, or onto it."}

  defp rename(module, store, old_path, new_path), do: module.rename(store, old_path, new_path)

  defp view_range(nil), do: {:ok, nil}

  defp view_range([first, last])
       when is_integer(first) and first >= 1 and
              (last == -1 or (is_integer(last) and last >= first)),
       do: {:ok, {first, last}}

  defp view_range(other) do
    {:error,
     "view_range must be [start_line, end_line] with start_line >= 1 and " <>
       "end_line >= start_line, or -1 for the end of the file; got: #{inspect(other)}"}
  end

  defp slice_lines(text, nil), do: {:ok, text}

  defp slice_lines(text, {first, last}) when is_binary(text) do
    lines = text |> String.replace_suffix("\n", "") |> String.split("\n")
    count = length(lines)
    last = if last == -1, do: count, else: min(last, count)

    if first > count do
      {:error, "view_range starts at line #{first}, but the file has #{count} lines."}
    else
      {:ok, lines |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.join("\n")}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
