defmodule Alloy.Agent.ServerModelSwitchTest do
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

  describe "set_model/2" do
    test "changes provider module and config" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))

      # Create a second test provider to switch to
      pid2 = start_provider([TestProvider.text_response("Switched!")])

      assert :ok =
               Server.set_model(agent,
                 provider: {Alloy.Provider.Test, agent_pid: pid2}
               )

      # Chat should use the new provider
      {:ok, result} = Server.chat(agent, "Hello after switch")
      assert result.text == "Switched!"
    end

    test "preserves conversation history after switch" do
      pid =
        start_provider([
          TestProvider.text_response("First reply")
        ])

      {:ok, agent} = Server.start_link(opts(pid))

      # Have a conversation first
      {:ok, _} = Server.chat(agent, "Hello")
      messages_before = Server.messages(agent)
      assert length(messages_before) == 2

      # Switch provider
      pid2 = start_provider([TestProvider.text_response("After switch")])

      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      # Messages should still be there
      messages_after = Server.messages(agent)
      assert messages_after == messages_before
    end

    test "preserves other config fields (tools, system_prompt, max_turns, etc.)" do
      pid = start_provider([TestProvider.text_response("Hi")])

      {:ok, agent} =
        Server.start_link(
          opts(pid,
            system_prompt: "You are helpful",
            max_turns: 10,
            working_directory: "/tmp"
          )
        )

      # Switch model
      pid2 = start_provider([])
      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      # Inspect state via messages call -- we can't directly read config,
      # but we can verify the agent still works. Let's verify by doing a chat
      # that exercises the same server. The config fields are preserved internally.
      # We test this indirectly: if provider changed but the server is still
      # functioning with its tools and system_prompt, then config was preserved.

      # For a more direct test, let's use :sys.get_state/1
      state = :sys.get_state(agent)
      assert state.config.system_prompt == "You are helpful"
      assert state.config.max_turns == 10
      assert state.config.working_directory == "/tmp"
      assert state.config.provider == Alloy.Provider.Test
      assert state.config.provider_config.agent_pid == pid2
    end

    test "chatting after model switch uses the new provider" do
      pid1 =
        start_provider([
          TestProvider.text_response("From provider 1")
        ])

      {:ok, agent} = Server.start_link(opts(pid1))

      # Chat with original provider
      {:ok, r1} = Server.chat(agent, "Hello")
      assert r1.text == "From provider 1"

      # Switch to a new provider
      pid2 =
        start_provider([
          TestProvider.text_response("From provider 2")
        ])

      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      # Chat should now use provider 2
      {:ok, r2} = Server.chat(agent, "Hello again")
      assert r2.text == "From provider 2"
    end

    test "accepts a bare module atom (no config keyword list)" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))

      # Switch using just an atom (no config keyword list)
      :ok = Server.set_model(agent, provider: Alloy.Provider.Test)

      state = :sys.get_state(agent)
      assert state.config.provider == Alloy.Provider.Test
      assert state.config.provider_config == %{}
    end

    test "preserves accumulated usage after switch" do
      pid1 = start_provider([TestProvider.text_response("One")])
      {:ok, agent} = Server.start_link(opts(pid1))

      # Accumulate some usage
      {:ok, _} = Server.chat(agent, "First")
      usage_before = Server.usage(agent)
      assert usage_before.input_tokens > 0

      # Switch provider
      pid2 = start_provider([TestProvider.text_response("Two")])
      :ok = Server.set_model(agent, provider: {Alloy.Provider.Test, agent_pid: pid2})

      # Usage should be preserved
      usage_after = Server.usage(agent)
      assert usage_after == usage_before
    end

    test "recomputes derived max_tokens on model switch" do
      {:ok, agent} =
        Server.start_link(
          provider: {Alloy.Provider.OpenAI, [api_key: "sk-test", model: "gpt-5.4"]}
        )

      assert :sys.get_state(agent).config.max_tokens == 1_050_000

      assert :ok =
               Server.set_model(agent,
                 provider:
                   {Alloy.Provider.Anthropic, [api_key: "sk-ant-test", model: "claude-haiku-4-5"]}
               )

      assert :sys.get_state(agent).config.max_tokens == 200_000
    end

    test "preserves explicit max_tokens on model switch" do
      {:ok, agent} =
        Server.start_link(
          provider: {Alloy.Provider.OpenAI, [api_key: "sk-test", model: "gpt-5.4"]},
          max_tokens: 123_456
        )

      assert :ok =
               Server.set_model(agent,
                 provider:
                   {Alloy.Provider.Anthropic, [api_key: "sk-ant-test", model: "claude-haiku-4-5"]}
               )

      assert :sys.get_state(agent).config.max_tokens == 123_456
    end
  end
end
