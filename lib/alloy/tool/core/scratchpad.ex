defmodule Alloy.Tool.Core.Scratchpad do
  @moduledoc """
  Persistent in-memory key-value store that survives context compaction.

  When the compactor truncates old tool results from the message window,
  anything saved here remains intact. Use it to record key findings,
  file paths, progress notes, or any state that must persist across turns.

  The scratchpad is backed by an Elixir `Agent` process whose PID is stored
  in `Agent.State.scratchpad` and threaded into the tool context by the
  Executor. It starts automatically when this module is in the tools list.
  """

  @behaviour Alloy.Tool

  @impl true
  def name, do: "scratchpad"

  @impl true
  def description do
    "Persistent memory that survives context compaction. " <>
      "Use 'write' to save key findings before the context window fills up, " <>
      "and 'read' to recall them later. Stored values outlast any compaction."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["read", "write", "clear"],
          description: "read: show all notes, write: save a note by key, clear: delete all notes"
        },
        key: %{
          type: "string",
          description: "Key name for write (e.g. 'target_file', 'progress', 'findings')"
        },
        value: %{
          type: "string",
          description: "Value to store (required for write)"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(input, context) do
    case Map.get(context, :scratchpad_pid) do
      nil ->
        {:error,
         "Scratchpad is not available. Add Alloy.Tool.Core.Scratchpad to your tools list."}

      pid ->
        do_execute(input["action"], input, pid)
    end
  end

  defp do_execute("read", _input, pid) do
    notes = Agent.get(pid, & &1)

    if map_size(notes) == 0 do
      {:ok, "(scratchpad is empty)"}
    else
      text = Enum.map_join(notes, "\n", fn {k, v} -> "#{k}: #{v}" end)
      {:ok, text}
    end
  end

  defp do_execute("write", input, pid) do
    key = input["key"]
    value = input["value"]

    cond do
      is_nil(key) ->
        {:error, "'write' requires a 'key'"}

      is_nil(value) ->
        {:error, "'write' requires a 'value'"}

      true ->
        Agent.update(pid, &Map.put(&1, key, value))
        {:ok, "Saved: #{key}"}
    end
  end

  defp do_execute("clear", _input, pid) do
    Agent.update(pid, fn _ -> %{} end)
    {:ok, "Scratchpad cleared."}
  end

  defp do_execute(other, _input, _pid) do
    {:error, "Unknown action '#{other}'. Use 'read', 'write', or 'clear'."}
  end
end
