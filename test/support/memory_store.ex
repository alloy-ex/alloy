defmodule Alloy.Test.MemoryStore do
  @moduledoc """
  Reference in-memory `Alloy.Memory` implementation used by Alloy's own
  tests. Kept under `test/support/` and intentionally NOT exported from
  the package — production stores belong in `alloy_agent` or user code.

  The store is a plain map wrapped in an Agent process so tests can
  exercise state mutation across tool calls. Construct one per test
  with `start_link/0`, then pass `{__MODULE__, pid}` as the `:memory`
  option to `Alloy.run/2`.
  """

  @behaviour Alloy.Memory

  use Agent

  @spec start_link() :: {:ok, pid()}
  def start_link, do: Agent.start_link(fn -> %{} end)

  @spec contents(pid()) :: map()
  def contents(pid), do: Agent.get(pid, & &1)

  @impl true
  def view(pid, path) do
    case Agent.get(pid, &Map.fetch(&1, path)) do
      {:ok, contents} ->
        {:ok, contents}

      :error ->
        children = list_children(pid, path)

        if children == [] do
          {:error, "path not found: #{path}"}
        else
          {:ok, Enum.join(children, "\n")}
        end
    end
  end

  @impl true
  def create(pid, path, file_text) do
    Agent.update(pid, &Map.put(&1, path, file_text))
    {:ok, "created #{path}"}
  end

  @impl true
  def str_replace(pid, path, old_str, new_str) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, path) do
        {:ok, contents} ->
          if String.contains?(contents, old_str) do
            updated = String.replace(contents, old_str, new_str, global: false)
            {{:ok, "replaced in #{path}"}, Map.put(state, path, updated)}
          else
            {{:error, "old_str not found in #{path}"}, state}
          end

        :error ->
          {{:error, "path not found: #{path}"}, state}
      end
    end)
  end

  @impl true
  def insert(pid, path, insert_line, text) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, path) do
        {:ok, contents} ->
          lines = String.split(contents, "\n")
          {before, after_} = Enum.split(lines, insert_line)
          updated = Enum.join(before ++ [text] ++ after_, "\n")
          {{:ok, "inserted at line #{insert_line} of #{path}"}, Map.put(state, path, updated)}

        :error ->
          {{:error, "path not found: #{path}"}, state}
      end
    end)
  end

  @impl true
  def delete(pid, path) do
    Agent.update(pid, fn state ->
      Enum.reject(state, fn {k, _} -> k == path or String.starts_with?(k, path <> "/") end)
      |> Map.new()
    end)

    {:ok, "deleted #{path}"}
  end

  @impl true
  def rename(pid, old_path, new_path) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, old_path) do
        {:ok, contents} ->
          new_state = state |> Map.delete(old_path) |> Map.put(new_path, contents)
          {{:ok, "renamed #{old_path} -> #{new_path}"}, new_state}

        :error ->
          {{:error, "path not found: #{old_path}"}, state}
      end
    end)
  end

  defp list_children(pid, path) do
    prefix = if String.ends_with?(path, "/"), do: path, else: path <> "/"

    pid
    |> contents()
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end
end
