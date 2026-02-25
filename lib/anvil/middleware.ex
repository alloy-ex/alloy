defmodule Anvil.Middleware do
  @moduledoc """
  Behaviour for middleware that wraps the agent loop.

  Middleware runs at defined hook points:
  - `:before_completion` - Before calling the provider
  - `:after_completion` - After provider response, before tool execution
  - `:after_tool_execution` - After tools have been executed
  - `:on_error` - When an error occurs

  Middleware can modify state (e.g., add logging, enforce policies,
  track metrics) but should not change the fundamental loop behavior.
  """

  alias Anvil.Agent.State

  @type hook ::
          :before_completion
          | :after_completion
          | :after_tool_execution
          | :on_error

  @doc """
  Called at the specified hook point. Returns modified state.
  """
  @callback call(hook(), State.t()) :: State.t()

  @doc """
  Runs all middleware for a given hook point.
  """
  @spec run(hook(), State.t()) :: State.t()
  def run(hook, %State{} = state) do
    Enum.reduce(state.config.middleware, state, fn middleware, acc ->
      middleware.call(hook, acc)
    end)
  end
end
