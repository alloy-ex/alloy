defmodule Alloy.Middleware do
  @moduledoc """
  Behaviour for middleware that wraps the agent loop.

  Middleware runs at defined hook points:
  - `:before_completion` - Before calling the provider. Middleware may
    rewrite `state.messages` here; compaction does.
  - `:after_completion` - After provider response with :end_turn (final state)
  - `:after_compaction` - After compaction changed the messages
  - `:after_tool_request` - After provider response with :tool_use (gates tool execution)
  - `:before_tool_call` - Before each tool call; may block or edit the call
  - `:after_tool_execution` - After tools have been executed
  - `:on_context_overflow` - The provider rejected the request as too long.
    Middleware may shrink `state.messages`; if the messages changed, the
    loop retries the request once, otherwise the run fails.
  - `:on_error` - When an error occurs
  - `:session_start`, `:session_end` - Not fired by the loop; reserved for
    runtimes such as `alloy_agent` that wrap it in a process

  Middleware runs in list order and should return the state unchanged for
  hooks it does not handle (`def call(_hook, state), do: state`), since
  new hooks may be added.

  ## Compaction

  `Alloy.Context.Compactor` is middleware: it compacts on
  `:before_completion` when the history nears the context budget, and
  forces compaction on `:on_context_overflow`. `Alloy.run/2` puts it first
  in the list unless you pass `compaction: false` or list it yourself
  (to run it after other middleware).
  """

  alias Alloy.Agent.State

  @type hook ::
          :before_completion
          | :after_completion
          | :after_compaction
          | :after_tool_request
          | :after_tool_execution
          | :on_context_overflow
          | :on_error
          | :before_tool_call
          | :session_start
          | :session_end

  @type call_result ::
          State.t()
          | {:block, String.t()}
          | {:halt, String.t()}
          | {:halt, String.t(), State.t()}
          | {:edit, map()}

  @doc """
  Called at the specified hook point. Returns modified state,
  `{:block, reason}` for `:before_tool_call` to prevent execution,
  or `{:halt, reason}` to stop the entire agent loop immediately.

  A halted run keeps the changes earlier middleware made to the state in
  that hook (for example, compaction and the usage of its summary
  request). Return `{:halt, reason, state}` to halt with changes of your
  own.
  """
  @callback call(hook(), State.t()) :: call_result()

  @doc """
  Runs all middleware for a given hook point.

  Middleware can return `{:halt, reason}` to stop processing immediately
  and mark the agent as halted. Returns either the final state or
  `{:halted, reason}` tuple.
  """
  @spec run(hook(), State.t()) :: State.t() | {:halted, String.t()}
  def run(hook, %State{} = state) do
    case run_hook(hook, state) do
      {:halted, reason, _state} -> {:halted, reason}
      %State{} = state -> state
    end
  end

  @doc false
  # Like run/2, but a halt carries the state as it stood when the chain
  # stopped, so the loop can keep work earlier middleware already paid for.
  @spec run_hook(hook(), State.t()) :: State.t() | {:halted, String.t(), State.t()}
  def run_hook(hook, %State{} = state) do
    Enum.reduce_while(state.config.middleware, state, fn middleware, acc ->
      case middleware.call(hook, acc) do
        {:halt, reason} ->
          {:halt, {:halted, reason, acc}}

        {:halt, reason, %State{} = halted} ->
          {:halt, {:halted, reason, halted}}

        %State{} = new_state ->
          {:cont, new_state}

        {:block, reason} ->
          raise ArgumentError,
                "#{inspect(middleware)} returned {:block, #{inspect(reason)}} " <>
                  "from hook #{inspect(hook)}, but {:block, reason} is only valid for " <>
                  "the :before_tool_call hook. Use {:halt, reason} to stop the agent loop."
      end
    end)
  end

  @doc """
  Runs `:before_tool_call` middleware for a single tool call.

  Injects the tool call into `state.config.context[:current_tool_call]`
  before running middleware. Returns `:ok`, `{:block, reason}`,
  `{:edit, modified_call}`, or `{:halted, reason}`.

  The `{:edit, modified_call}` return lets middleware rewrite tool arguments
  before execution. The modified call must keep the same `:id` and `:name`.

  Note: `{:edit, ...}`, `{:block, ...}`, and `{:halt, ...}` all stop the
  middleware chain immediately. The first middleware that returns one of
  these wins — subsequent middleware modules will not see the tool call.
  """
  @spec run_before_tool_call(State.t(), map()) ::
          :ok | {:block, String.t()} | {:edit, map()} | {:halted, String.t()}
  def run_before_tool_call(%State{} = state, tool_call) do
    updated_context = Map.put(state.config.context, :current_tool_call, tool_call)
    updated_config = %{state.config | context: updated_context}
    updated_state = %{state | config: updated_config}

    Enum.reduce_while(updated_state.config.middleware, :ok, fn middleware, _acc ->
      case middleware.call(:before_tool_call, updated_state) do
        {:block, reason} ->
          {:halt, {:block, reason}}

        {:halt, reason} ->
          {:halt, {:halted, reason}}

        {:halt, reason, %State{}} ->
          {:halt, {:halted, reason}}

        {:edit, modified_call} ->
          validate_edit!(tool_call, modified_call)
          {:halt, {:edit, modified_call}}

        %State{} ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_edit!(original, modified) do
    unless Map.get(modified, :id) == Map.get(original, :id) and
             Map.get(modified, :name) == Map.get(original, :name) do
      raise ArgumentError,
            "Middleware :edit must preserve the tool call :id and :name. " <>
              "Original: #{inspect(Map.take(original, [:id, :name]))}, " <>
              "Modified: #{inspect(Map.take(modified, [:id, :name]))}"
    end
  end
end
