defmodule Alloy.Middleware do
  @moduledoc """
  Behaviour for middleware that wraps the agent loop.

  Middleware runs at defined hook points:
  - `:before_completion` - Prepare request inputs before the provider call; list preparation before compaction
  - `:after_completion` - Finalize a normal answer or successful `:stop_after_tool` completion
  - `:after_compaction` - After context compaction occurs (only fires when messages changed)
  - `:after_tool_request` - After provider response with :tool_use (gates tool execution)
  - `:after_tool_execution` - After tools have been executed
  - `:before_tool_call` - Compose argument edits and policy checks before execution
  - `:after_tool_call` - Replace each result's content/data before publication
  - `:on_context_overflow` - Shrink messages after the provider rejects the context; retry once
  - `:on_error` - When an error occurs
  - `:session_start`, `:session_end` - Not fired by the loop; reserved for
    runtimes such as `alloy_agent` that wrap it in a process

  Middleware runs in list order and should return the state unchanged for
  hooks it does not handle (`def call(_hook, state), do: state`), since
  new hooks may be added.

  ## Compaction

  `Alloy.Context.Compactor` is middleware: it compacts on
  `:before_completion` when the history nears the context budget, and
  forces compaction on `:on_context_overflow`. `Alloy.run/2` puts it last
  so it budgets the prepared inputs, unless you pass `compaction: false`
  or list it yourself to choose its position.
  """

  alias Alloy.Agent.State
  alias Alloy.Internal.Sanitize

  @type hook ::
          :before_completion
          | :after_completion
          | :after_compaction
          | :after_tool_request
          | :after_tool_execution
          | :on_context_overflow
          | :on_error
          | :before_tool_call
          | :after_tool_call
          | :session_start
          | :session_end

  @type tool_result :: %{content: String.t(), data: map() | nil, is_error: boolean()}
  @type call_result ::
          State.t()
          | {:block, String.t()}
          | {:halt, String.t()}
          | {:halt, String.t(), State.t()}
          | {:edit, map()}
          | {:result, tool_result()}

  @doc """
  Called at the specified hook point. Returns modified state,
  `{:block, reason}` for `:before_tool_call` to prevent execution,
  or `{:halt, reason}` to stop the entire agent loop immediately.

  A halted run keeps the changes earlier middleware made to the state in
  that hook (for example, compaction and the usage of its summary
  request). Return `{:halt, reason, state}` to halt with changes of your
  own. `:before_tool_call` is the exception: it decides about one tool
  call and never changes the loop's state, so a halt there keeps the
  state as it was before the hook.
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
        {:halt, reason} when is_binary(reason) ->
          {:halt, {:halted, reason, acc}}

        {:halt, reason, %State{} = halted} when is_binary(reason) ->
          {:halt, {:halted, reason, halted}}

        %State{status: :cancelled} = cancelled ->
          {:halt, cancelled}

        %State{} = new_state ->
          {:cont, new_state}

        {:block, reason} ->
          raise ArgumentError,
                "#{inspect(middleware)} returned {:block, #{Sanitize.shape_summary(reason)}} " <>
                  "from hook #{inspect(hook)}, but {:block, reason} is only valid for " <>
                  "the :before_tool_call hook. Use {:halt, reason} to stop the agent loop."

        other ->
          raise ArgumentError,
                "#{inspect(middleware)} returned unsupported value #{Sanitize.shape_summary(other)} " <>
                  "from hook #{inspect(hook)}. Expected %Alloy.Agent.State{}, {:halt, reason}, " <>
                  "or {:halt, reason, state}."
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

  Edits pass the modified call to subsequent middleware. Block and halt
  stop the chain. State returned from this hook does not alter loop state.
  """
  @spec run_before_tool_call(State.t(), map()) ::
          :ok | {:block, String.t()} | {:edit, map()} | {:halted, String.t()}
  def run_before_tool_call(%State{} = state, tool_call) do
    result =
      Enum.reduce_while(state.config.middleware, {:edit, tool_call}, fn middleware,
                                                                        {:edit, current} ->
        updated_state = tool_state(state, current)

        case middleware.call(:before_tool_call, updated_state) do
          {:block, reason} when is_binary(reason) ->
            {:halt, {:block, reason}}

          {:halt, reason} when is_binary(reason) ->
            {:halt, {:halted, reason}}

          {:halt, reason, %State{}} when is_binary(reason) ->
            {:halt, {:halted, reason}}

          {:edit, modified_call} when is_map(modified_call) and not is_struct(modified_call) ->
            validate_edit!(tool_call, modified_call)
            {:cont, {:edit, modified_call}}

          %State{} ->
            {:cont, {:edit, current}}

          other ->
            raise ArgumentError,
                  "#{inspect(middleware)} returned unsupported value #{Sanitize.shape_summary(other)} " <>
                    "from :before_tool_call. Expected %Alloy.Agent.State{}, {:edit, call}, " <>
                    "{:block, reason}, or {:halt, reason}."
        end
      end)

    if result == {:edit, tool_call}, do: :ok, else: result
  end

  @doc """
  Runs `:after_tool_call` before publishing each tool outcome.

  Context contains `:current_tool_call` and `:current_tool_result` with
  `:content`, `:data`, and `:is_error`. Return `{:result, result}` to replace
  content and structured data, or the state unchanged. Replacements compose;
  they must retain `:is_error`. State changes are not applied to the loop.
  Hook failures abort execution rather than publishing an unredacted result.
  """
  @spec run_after_tool_call(State.t(), map(), tool_result()) :: tool_result()
  def run_after_tool_call(state, call, result) do
    Enum.reduce(state.config.middleware, result, fn middleware, current ->
      scoped = tool_state(state, call, current)

      case middleware.call(:after_tool_call, scoped) do
        %State{} ->
          current

        {:result, replacement} ->
          validate_result!(current, replacement)

        other ->
          raise ArgumentError,
                "#{inspect(middleware)} returned unsupported value #{Sanitize.shape_summary(other)} " <>
                  "from :after_tool_call. Expected %Alloy.Agent.State{} or {:result, result}."
      end
    end)
  end

  defp tool_state(state, call, result \\ nil) do
    context =
      state.config.context
      |> Map.put(:current_tool_call, call)
      |> Map.put(:current_tool_result, result)

    %{state | config: %{state.config | context: context}}
  end

  defp validate_result!(original, %{content: content, data: data, is_error: error} = result)
       when is_binary(content) and (is_map(data) or is_nil(data)) and error == original.is_error,
       do: Map.take(result, [:content, :data, :is_error])

  defp validate_result!(_original, _result) do
    raise ArgumentError,
          "tool result replacement requires string content, map/nil data, and unchanged is_error"
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
