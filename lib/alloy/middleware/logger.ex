defmodule Alloy.Middleware.Logger do
  @moduledoc """
  Middleware that logs at each hook point using Elixir's Logger.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State

  require Logger

  @impl true
  def call(:before_completion, %State{} = state) do
    Logger.debug("Alloy turn #{state.turn}: sending completion request")
    state
  end

  def call(:after_completion, %State{} = state) do
    Logger.info("Alloy turn #{state.turn}: completion received, status=#{state.status}")
    state
  end

  def call(:after_tool_execution, %State{} = state) do
    Logger.debug("Alloy turn #{state.turn}: tool execution complete")
    state
  end

  def call(:on_error, %State{} = state) do
    Logger.error("Alloy turn #{state.turn}: error - #{inspect(state.error)}")
    state
  end

  def call(_hook, %State{} = state), do: state
end
