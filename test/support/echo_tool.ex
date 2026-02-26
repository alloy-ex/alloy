defmodule Anvil.Test.EchoTool do
  @moduledoc false
  @behaviour Anvil.Tool

  @impl true
  def name, do: "echo"

  @impl true
  def description, do: "Echoes input back"

  @impl true
  def input_schema do
    %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]}
  end

  @impl true
  def execute(%{"text" => text}, _context) do
    {:ok, "Echo: #{text}"}
  end
end
