defmodule Alloy.Session do
  @moduledoc """
  Serializable session container.

  > #### Moved to `alloy_agent` {: .warning}
  >
  > This struct has moved to `AlloyAgent.Session` in the
  > [`alloy_agent`](https://hex.pm/packages/alloy_agent) package. This
  > copy will be removed in Alloy 0.13.0. Migrate by replacing
  > `%Alloy.Session{}` with `%AlloyAgent.Session{}` and
  > `Alloy.Session.new/1` with `AlloyAgent.Session.new/1`.

  Wraps the conversation state in a format that can be serialized
  to JSON, stored in a database, or passed between processes.
  No database required — sessions are plain structs.
  """

  alias Alloy.{Message, Usage}

  @type t :: %__MODULE__{
          id: String.t(),
          messages: [Message.t()],
          usage: Usage.t(),
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    messages: [],
    usage: %Usage{},
    metadata: %{},
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Creates a new session with a generated ID.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      messages: Keyword.get(opts, :messages, []),
      usage: Keyword.get(opts, :usage, %Usage{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Updates a session with results from an agent run.
  """
  @spec update_from_result(t(), map()) :: t()
  def update_from_result(%__MODULE__{} = session, result) do
    %{
      session
      | messages: result.messages,
        usage: result.usage,
        metadata: Map.merge(session.metadata, Map.get(result, :metadata, %{})),
        updated_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
