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
