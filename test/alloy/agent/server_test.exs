defmodule Alloy.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Server
  alias Alloy.Provider.Test, as: TestProvider

  defp start_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp opts(provider_pid, overrides \\ []) do
    Keyword.merge(
      [provider: {Alloy.Provider.Test, agent_pid: provider_pid}],
      overrides
    )
  end

  describe "start_link/1" do
    test "starts a linked GenServer" do
      pid = start_provider([TestProvider.text_response("Hi")])
      assert {:ok, agent} = Server.start_link(opts(pid))
      assert Process.alive?(agent)
    end

    test "accepts a name option" do
      pid = start_provider([TestProvider.text_response("Hi")])
      name = :"test_server_#{System.unique_integer()}"
      assert {:ok, _} = Server.start_link(opts(pid, name: name))
      assert Process.whereis(name) != nil
    end
  end

  describe "chat/2" do
    test "returns {:ok, result} with text" do
      pid = start_provider([TestProvider.text_response("Hello from Alloy!")])
      {:ok, agent} = Server.start_link(opts(pid))
      assert {:ok, result} = Server.chat(agent, "Hello")
      assert result.text == "Hello from Alloy!"
      assert result.status == :completed
    end

    test "persists conversation history across calls" do
      pid =
        start_provider([
          TestProvider.text_response("First reply"),
          TestProvider.text_response("Second reply")
        ])

      {:ok, agent} = Server.start_link(opts(pid))

      {:ok, _} = Server.chat(agent, "First message")
      {:ok, _} = Server.chat(agent, "Second message")

      messages = Server.messages(agent)
      # user1, assistant1, user2, assistant2
      assert length(messages) == 4
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == "First message"
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 2).role == :user
      assert Enum.at(messages, 2).content == "Second message"
    end

    test "returns :turns in result" do
      pid = start_provider([TestProvider.text_response("Done")])
      {:ok, agent} = Server.start_link(opts(pid))
      {:ok, result} = Server.chat(agent, "Go")
      assert result.turns == 1
    end
  end

  describe "messages/1" do
    test "returns [] before any chat" do
      pid = start_provider([])
      {:ok, agent} = Server.start_link(opts(pid))
      assert Server.messages(agent) == []
    end

    test "returns full history after chat" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "Hello")
      assert length(Server.messages(agent)) == 2
    end
  end

  describe "reset/1" do
    test "clears message history" do
      pid =
        start_provider([
          TestProvider.text_response("Hi"),
          TestProvider.text_response("After reset")
        ])

      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "Hello")
      assert length(Server.messages(agent)) == 2

      :ok = Server.reset(agent)
      assert Server.messages(agent) == []
    end
  end

  describe "usage/1" do
    test "accumulates token usage across calls" do
      pid =
        start_provider([
          TestProvider.text_response("One"),
          TestProvider.text_response("Two")
        ])

      {:ok, agent} = Server.start_link(opts(pid))
      Server.chat(agent, "First")
      usage_after_one = Server.usage(agent)

      Server.chat(agent, "Second")
      usage_after_two = Server.usage(agent)

      # Usage should grow after second call
      assert usage_after_two.input_tokens >= usage_after_one.input_tokens
    end
  end
end
