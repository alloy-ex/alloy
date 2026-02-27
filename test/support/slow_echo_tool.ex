defmodule Alloy.Test.SlowEchoTool do
  @moduledoc false
  @behaviour Alloy.Tool

  @impl true
  def name, do: "slow_echo"

  @impl true
  def description, do: "Echoes input back after sleeping"

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        text: %{type: "string"},
        sleep_ms: %{type: "integer"}
      },
      required: ["text"]
    }
  end

  @impl true
  def execute(%{"text" => text} = input, _context) do
    sleep_ms = Map.get(input, "sleep_ms", 0)
    if sleep_ms > 0, do: Process.sleep(sleep_ms)
    {:ok, "Echo: #{text}"}
  end
end
