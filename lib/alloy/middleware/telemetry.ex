defmodule Alloy.Middleware.Telemetry do
  @moduledoc """
  Middleware that emits `:telemetry` events at each hook point.

  ## Events

  - `[:alloy, :completion, :start]` - before provider call
  - `[:alloy, :completion, :stop]` - after provider response
  - `[:alloy, :tool_execution, :stop]` - after tools executed
  - `[:alloy, :error]` - on error
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State
  alias Alloy.Usage

  @impl true
  def call(:before_completion, %State{} = state) do
    :telemetry.execute(
      [:alloy, :completion, :start],
      %{turn: state.turn},
      %{}
    )

    state
  end

  def call(:after_completion, %State{} = state) do
    :telemetry.execute(
      [:alloy, :completion, :stop],
      %{turn: state.turn, tokens: Usage.total(state.usage)},
      %{status: state.status}
    )

    state
  end

  def call(:after_tool_execution, %State{} = state) do
    :telemetry.execute(
      [:alloy, :tool_execution, :stop],
      %{turn: state.turn, tokens: Usage.total(state.usage)},
      %{status: state.status}
    )

    state
  end

  def call(:on_error, %State{} = state) do
    :telemetry.execute(
      [:alloy, :error],
      %{turn: state.turn},
      %{status: state.status, error: state.error}
    )

    state
  end

  def call(_hook, %State{} = state), do: state
end
