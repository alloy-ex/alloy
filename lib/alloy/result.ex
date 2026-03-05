defmodule Alloy.Result do
  @moduledoc """
  Structured result from an agent run.

  Returned by `Alloy.run/2` and `Alloy.Agent.Server.chat/3`.
  Implements `Access` for bracket-syntax compatibility (`result[:text]`).

  ## Fields

    * `:text` — the final assistant text (or `nil` if the model returned no text)
    * `:messages` — full conversation history
    * `:usage` — accumulated `%Alloy.Usage{}` token counts
    * `:tool_calls` — list of tool execution metadata maps
    * `:status` — final run status (`:completed`, `:max_turns`, `:error`, `:halted`)
    * `:turns` — number of agent loop iterations
    * `:error` — error term (or `nil` on success)
    * `:request_id` — correlation ID for async requests (or `nil` for sync)
  """

  @behaviour Access

  alias Alloy.Agent.State
  alias Alloy.{Message, Usage}

  @type t :: %__MODULE__{
          text: String.t() | nil,
          messages: [Message.t()],
          usage: Usage.t(),
          tool_calls: [map()],
          status: State.status(),
          turns: non_neg_integer(),
          error: term() | nil,
          request_id: binary() | nil
        }

  defstruct [
    :text,
    :error,
    :request_id,
    messages: [],
    usage: %Usage{},
    tool_calls: [],
    status: :completed,
    turns: 0
  ]

  @doc """
  Build a `Result` from a final `State`.

  Extracts text, messages, usage, tool calls, status, turns, and error
  from the state. The `request_id` is left as `nil` — async callers
  overlay it via `%{result | request_id: id}`.
  """
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      text: State.last_assistant_text(state),
      messages: State.messages(state),
      usage: state.usage,
      tool_calls: state.tool_calls,
      status: state.status,
      turns: state.turn,
      error: state.error
    }
  end

  # ── Access callbacks ─────────────────────────────────────────────────────

  @impl Access
  def fetch(result, key), do: Map.fetch(result, key)

  @impl Access
  def get_and_update(result, key, fun), do: Map.get_and_update(result, key, fun)

  @impl Access
  def pop(result, key) do
    value = Map.get(result, key)
    {value, Map.put(result, key, nil)}
  end
end
