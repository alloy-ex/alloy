defmodule Anvil.Middleware.Telemetry do
  @moduledoc """
  Middleware that emits `:telemetry` events at each hook point.

  ## Events

  - `[:anvil, :completion, :start]` - before provider call
  - `[:anvil, :completion, :stop]` - after provider response
  - `[:anvil, :tool_execution, :stop]` - after tools executed
  - `[:anvil, :error]` - on error
  """

  @behaviour Anvil.Middleware

  alias Anvil.Agent.State
  alias Anvil.Usage

  @impl true
  def call(:before_completion, %State{} = state) do
    :telemetry.execute(
      [:anvil, :completion, :start],
      %{turn: state.turn},
      %{}
    )

    state
  end

  def call(:after_completion, %State{} = state) do
    :telemetry.execute(
      [:anvil, :completion, :stop],
      %{turn: state.turn, tokens: Usage.total(state.usage)},
      %{status: state.status}
    )

    state
  end

  def call(:after_tool_execution, %State{} = state) do
    :telemetry.execute(
      [:anvil, :tool_execution, :stop],
      %{turn: state.turn, tokens: Usage.total(state.usage)},
      %{status: state.status}
    )

    state
  end

  def call(:on_error, %State{} = state) do
    :telemetry.execute(
      [:anvil, :error],
      %{turn: state.turn},
      %{status: state.status, error: state.error}
    )

    state
  end
end
