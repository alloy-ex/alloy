defmodule Alloy.PersistenceTest do
  use ExUnit.Case, async: true

  alias Alloy.{Session, Usage}

  # A minimal in-memory implementation to verify the behaviour contract.
  defmodule InMemoryStore do
    @behaviour Alloy.Persistence

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    @impl Alloy.Persistence
    def save_session(%Session{} = session) do
      Agent.update(__MODULE__, &Map.put(&1, session.id, session))
      :ok
    end

    @impl Alloy.Persistence
    def load_session(id) when is_binary(id) do
      case Agent.get(__MODULE__, &Map.get(&1, id)) do
        nil -> {:error, :not_found}
        session -> {:ok, session}
      end
    end

    @impl Alloy.Persistence
    def delete_session(id) when is_binary(id) do
      Agent.update(__MODULE__, &Map.delete(&1, id))
      :ok
    end

    @impl Alloy.Persistence
    def list_sessions do
      Agent.get(__MODULE__, &Map.values(&1))
    end
  end

  setup do
    {:ok, _} = InMemoryStore.start_link()
    :ok
  end

  describe "behaviour contract" do
    test "module defines the expected callbacks" do
      callbacks = Alloy.Persistence.behaviour_info(:callbacks)

      assert {:save_session, 1} in callbacks
      assert {:load_session, 1} in callbacks
      assert {:delete_session, 1} in callbacks
      assert {:list_sessions, 0} in callbacks
    end
  end

  describe "save_session/1 + load_session/1" do
    test "round-trips a session" do
      session = Session.new(id: "test-123", metadata: %{agent: "tester"})

      assert :ok = InMemoryStore.save_session(session)
      assert {:ok, loaded} = InMemoryStore.load_session("test-123")

      assert loaded.id == "test-123"
      assert loaded.metadata == %{agent: "tester"}
      assert loaded.messages == []
      assert %Usage{} = loaded.usage
    end

    test "overwrites existing session on re-save" do
      session = Session.new(id: "overwrite-1")
      assert :ok = InMemoryStore.save_session(session)

      updated =
        Session.update_from_result(session, %{
          messages: [%Alloy.Message{role: :user, content: "hello"}],
          usage: %Usage{input_tokens: 10}
        })

      assert :ok = InMemoryStore.save_session(updated)
      assert {:ok, loaded} = InMemoryStore.load_session("overwrite-1")
      assert length(loaded.messages) == 1
      assert loaded.usage.input_tokens == 10
    end
  end

  describe "load_session/1 not found" do
    test "returns {:error, :not_found} for missing session" do
      assert {:error, :not_found} = InMemoryStore.load_session("nonexistent")
    end
  end

  describe "delete_session/1" do
    test "removes a previously saved session" do
      session = Session.new(id: "delete-me")
      assert :ok = InMemoryStore.save_session(session)
      assert {:ok, _} = InMemoryStore.load_session("delete-me")

      assert :ok = InMemoryStore.delete_session("delete-me")
      assert {:error, :not_found} = InMemoryStore.load_session("delete-me")
    end

    test "succeeds silently for missing session" do
      assert :ok = InMemoryStore.delete_session("never-existed")
    end
  end

  describe "list_sessions/0" do
    test "returns all saved sessions" do
      assert InMemoryStore.list_sessions() == []

      s1 = Session.new(id: "list-1")
      s2 = Session.new(id: "list-2")
      InMemoryStore.save_session(s1)
      InMemoryStore.save_session(s2)

      sessions = InMemoryStore.list_sessions()
      ids = Enum.map(sessions, & &1.id) |> Enum.sort()
      assert ids == ["list-1", "list-2"]
    end
  end
end
