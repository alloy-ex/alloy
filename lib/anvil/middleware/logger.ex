defmodule Anvil.Middleware.Logger do
  @moduledoc """
  Middleware that logs at each hook point using Elixir's Logger.
  """

  @behaviour Anvil.Middleware

  alias Anvil.Agent.State

  require Logger

  @impl true
  def call(:before_completion, %State{} = state) do
    Logger.debug("Anvil turn #{state.turn}: sending completion request")
    state
  end

  def call(:after_completion, %State{} = state) do
    Logger.info("Anvil turn #{state.turn}: completion received, status=#{state.status}")
    state
  end

  def call(:after_tool_execution, %State{} = state) do
    Logger.debug("Anvil turn #{state.turn}: tool execution complete")
    state
  end

  def call(:on_error, %State{} = state) do
    Logger.error("Anvil turn #{state.turn}: error - #{inspect(state.error)}")
    state
  end
end
