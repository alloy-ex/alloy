defmodule Alloy.Persistence do
  @moduledoc """
  Optional behaviour for session persistence backends.

  Defines the contract that host applications implement to persist
  agent sessions. Alloy itself is in-memory only — this behaviour
  is the formal seam between the engine and any runtime that adds
  durability (e.g., AnvilOS, or your own Ecto/SQLite/Redis adapter).

  ## Implementing a backend

      defmodule MyApp.SessionStore do
        @behaviour Alloy.Persistence

        @impl true
        def save_session(%Alloy.Session{} = session) do
          # Write to your database
          :ok
        end

        @impl true
        def load_session(id) do
          case Repo.get(SessionSchema, id) do
            nil -> {:error, :not_found}
            record -> {:ok, to_session(record)}
          end
        end

        @impl true
        def delete_session(id) do
          Repo.delete_all(from s in SessionSchema, where: s.id == ^id)
          :ok
        end

        @impl true
        def list_sessions do
          Repo.all(SessionSchema) |> Enum.map(&to_session/1)
        end
      end

  ## Wiring it up

  Pass your store module to `Alloy.Agent.Server` via middleware or
  the `:on_shutdown` callback:

      Alloy.Agent.Server.start_link(
        provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-opus-4-6"},
        on_shutdown: fn session -> MyApp.SessionStore.save_session(session) end
      )

  Or use middleware for automatic persistence after every turn:

      defmodule PersistMiddleware do
        @behaviour Alloy.Middleware

        @impl true
        def call(:after_completion, state) do
          session = Alloy.Session.new(messages: Alloy.Agent.State.messages(state), usage: state.usage)
          MyApp.SessionStore.save_session(session)
          state
        end

        def call(_hook, state), do: state
      end
  """

  alias Alloy.Session

  @doc """
  Persist a session. Overwrites any existing session with the same ID.
  """
  @callback save_session(Session.t()) :: :ok | {:error, term()}

  @doc """
  Load a session by ID. Returns `{:error, :not_found}` if it doesn't exist.
  """
  @callback load_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found | term()}

  @doc """
  Delete a session by ID. Succeeds silently if the session doesn't exist.
  """
  @callback delete_session(String.t()) :: :ok | {:error, term()}

  @doc """
  List all persisted sessions.
  """
  @callback list_sessions() :: [Session.t()]
end
