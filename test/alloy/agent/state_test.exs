defmodule Alloy.Agent.StateTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias Alloy.Provider.Error
  alias Alloy.Provider.Test, as: TestProvider

  setup do
    %{config: %Config{provider: TestProvider, provider_config: %{}}}
  end

  describe "append_messages/2" do
    test "state.messages holds every appended message in order", %{config: config} do
      state =
        config
        |> State.init([Message.user("first")])
        |> State.append_messages([Message.assistant("reply")])
        |> State.append_messages(Message.user("second"))

      assert Enum.map(state.messages, & &1.content) == ["first", "reply", "second"]
      assert State.messages(state) == state.messages
    end
  end

  describe "last_assistant_text/1" do
    test "returns the newest assistant message's text", %{config: config} do
      state =
        config
        |> State.init([Message.user("hello")])
        |> State.append_messages([Message.assistant("first reply")])
        |> State.append_messages([Message.user("followup")])
        |> State.append_messages([Message.assistant("last reply")])

      assert State.last_assistant_text(state) == "last reply"
    end

    test "is nil without an assistant message", %{config: config} do
      assert config |> State.init([Message.user("hello")]) |> State.last_assistant_text() == nil
    end
  end

  describe "init/2" do
    test "uses context.session_id as the agent id", %{config: config} do
      state = State.init(%{config | context: %{session_id: "sess-1"}})
      assert state.agent_id == "sess-1"
    end

    test "generates an agent id otherwise", %{config: config} do
      assert %State{agent_id: id} = State.init(config)
      assert byte_size(id) > 0
    end
  end

  describe "cancel/1 and put_provider_error/2" do
    test "cancel/1 sets status and error to :cancelled", %{config: config} do
      state = config |> State.init() |> State.cancel()
      assert state.status == :cancelled
      assert state.error == :cancelled
    end

    test "put_provider_error/2 records Alloy.Provider.Error and ignores other terms", %{
      config: config
    } do
      state = State.init(config)
      error = %Error{kind: :rate_limit, message: "slow down", status: 429}

      updated = State.put_provider_error(state, error)
      assert updated.run_metadata.provider_error == error

      assert State.put_provider_error(state, "plain string") == state
    end
  end

  describe "Inspect implementation" do
    test "hides internal tool_schema_cache", %{config: config} do
      state = %{State.init(config) | tool_schema_cache: %{"echo" => :internal_compiled_schema}}
      inspected = inspect(state)

      assert inspected =~ "#Alloy.Agent.State<"
      refute inspected =~ "tool_schema_cache"
      refute inspected =~ "internal_compiled_schema"
    end
  end
end
