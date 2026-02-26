defmodule Alloy.Middleware do
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

  alias Alloy.Agent.State

  @type hook ::
          :before_completion
          | :after_completion
          | :after_tool_execution
          | :on_error
          | :before_tool_call
          | :session_start
          | :session_end

  @type call_result :: State.t() | {:block, String.t()}

  @doc """
  Called at the specified hook point. Returns modified state,
  or `{:block, reason}` for `:before_tool_call` to prevent execution.
  """
  @callback call(hook(), State.t()) :: call_result()

  @doc """
  Runs all middleware for a given hook point.
  """
  @spec run(hook(), State.t()) :: State.t()
  def run(hook, %State{} = state) do
    Enum.reduce(state.config.middleware, state, fn middleware, acc ->
      middleware.call(hook, acc)
    end)
  end

  @doc """
  Runs `:before_tool_call` middleware for a single tool call.

  Injects the tool call into `state.config.context[:current_tool_call]`
  before running middleware. Returns `:ok` or `{:block, reason}`.
  """
  @spec run_before_tool_call(State.t(), map()) :: :ok | {:block, String.t()}
  def run_before_tool_call(%State{} = state, tool_call) do
    # Inject the tool call into context so middleware can inspect it
    updated_context = Map.put(state.config.context, :current_tool_call, tool_call)
    updated_config = %{state.config | context: updated_context}
    updated_state = %{state | config: updated_config}

    Enum.reduce_while(updated_state.config.middleware, :ok, fn middleware, _acc ->
      case middleware.call(:before_tool_call, updated_state) do
        {:block, reason} -> {:halt, {:block, reason}}
        %State{} -> {:cont, :ok}
      end
    end)
  end
end
