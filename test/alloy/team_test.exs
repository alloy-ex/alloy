defmodule Alloy.TeamTest do
  use ExUnit.Case, async: true

  alias Alloy.Team
  alias Alloy.Agent.Server
  alias Alloy.Provider.Test, as: TestProvider

  defp start_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp agent_opts(responses, overrides \\ []) do
    pid = start_provider(responses)
    Keyword.merge([provider: {Alloy.Provider.Test, agent_pid: pid}], overrides)
  end

  # ── start_link/1 ──────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts a team with named agents" do
      {:ok, team} =
        Team.start_link(
          agents: [
            alice: agent_opts([TestProvider.text_response("I'm Alice")]),
            bob: agent_opts([TestProvider.text_response("I'm Bob")])
          ]
        )

      agents = Team.agents(team)
      assert length(agents) == 2
      names = Keyword.keys(agents)
      assert :alice in names
      assert :bob in names
    end

    test "starts with no agents" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.agents(team) == []
    end

    test "accepts a name option" do
      name = :"team_#{System.unique_integer([:positive])}"
      {:ok, _} = Team.start_link(name: name, agents: [])
      assert Process.whereis(name) != nil
    end
  end

  # ── delegate/3 ────────────────────────────────────────────────────────

  describe "delegate/3" do
    test "sends message to named agent and returns result" do
      {:ok, team} =
        Team.start_link(
          agents: [
            greeter: agent_opts([TestProvider.text_response("Hello!")])
          ]
        )

      assert {:ok, result} = Team.delegate(team, :greeter, "Hi")
      assert result.text == "Hello!"
      assert result.status == :completed
    end

    test "returns error for unknown agent" do
      {:ok, team} = Team.start_link(agents: [])
      assert {:error, {:unknown_agent, :nobody}} = Team.delegate(team, :nobody, "Hello")
    end

    test "preserves conversation history per agent" do
      {:ok, team} =
        Team.start_link(
          agents: [
            agent:
              agent_opts([
                TestProvider.text_response("First reply"),
                TestProvider.text_response("Second reply")
              ])
          ]
        )

      {:ok, _} = Team.delegate(team, :agent, "Message 1")
      {:ok, _} = Team.delegate(team, :agent, "Message 2")

      pid = Team.get_agent(team, :agent)
      messages = Server.messages(pid)
      # user1, assistant1, user2, assistant2
      assert length(messages) == 4
    end

    test "concurrent delegates to different agents run in parallel" do
      {:ok, team} =
        Team.start_link(
          agents: [
            alice: agent_opts([TestProvider.text_response("Alice done")]),
            bob: agent_opts([TestProvider.text_response("Bob done")])
          ]
        )

      # Launch two delegates concurrently
      task_alice = Task.async(fn -> Team.delegate(team, :alice, "Go Alice") end)
      task_bob = Task.async(fn -> Team.delegate(team, :bob, "Go Bob") end)

      {:ok, r_alice} = Task.await(task_alice)
      {:ok, r_bob} = Task.await(task_bob)

      assert r_alice.text == "Alice done"
      assert r_bob.text == "Bob done"
    end
  end

  # ── broadcast/2 ──────────────────────────────────────────────────────

  describe "broadcast/2" do
    test "sends message to all agents and returns results map" do
      {:ok, team} =
        Team.start_link(
          agents: [
            alice: agent_opts([TestProvider.text_response("Alice here")]),
            bob: agent_opts([TestProvider.text_response("Bob here")])
          ]
        )

      results = Team.broadcast(team, "Roll call!")
      assert map_size(results) == 2
      assert {:ok, alice_result} = results[:alice]
      assert alice_result.text == "Alice here"
      assert {:ok, bob_result} = results[:bob]
      assert bob_result.text == "Bob here"
    end

    test "returns empty map for team with no agents" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.broadcast(team, "Anyone?") == %{}
    end
  end

  # ── handoff/3 ─────────────────────────────────────────────────────────

  describe "handoff/3" do
    test "chains agents, piping text output as next input" do
      {:ok, team} =
        Team.start_link(
          agents: [
            step1: agent_opts([TestProvider.text_response("Step 1 complete")]),
            step2: agent_opts([TestProvider.text_response("Step 2 finalized")])
          ]
        )

      assert {:ok, result} = Team.handoff(team, [:step1, :step2], "Start")
      # Result is from the last agent in the chain
      assert result.text == "Step 2 finalized"
    end

    test "stops chain on error and returns it" do
      {:ok, team} =
        Team.start_link(
          agents: [
            step1: agent_opts([TestProvider.error_response("boom")]),
            step2: agent_opts([TestProvider.text_response("Never reached")])
          ]
        )

      assert {:error, _} = Team.handoff(team, [:step1, :step2], "Start")
    end

    test "returns error if agent in chain is unknown" do
      {:ok, team} =
        Team.start_link(
          agents: [
            step1: agent_opts([TestProvider.text_response("Done")])
          ]
        )

      assert {:error, {:unknown_agent, :missing}} =
               Team.handoff(team, [:step1, :missing], "Go")
    end
  end

  # ── add_agent/3 and remove_agent/2 ──────────────────────────────────

  describe "add_agent/3" do
    test "dynamically adds an agent to the team" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.agents(team) == []

      :ok = Team.add_agent(team, :newcomer, agent_opts([TestProvider.text_response("I'm new!")]))

      assert length(Team.agents(team)) == 1

      {:ok, result} = Team.delegate(team, :newcomer, "Welcome!")
      assert result.text == "I'm new!"
    end

    test "returns error when adding duplicate name" do
      {:ok, team} =
        Team.start_link(agents: [existing: agent_opts([TestProvider.text_response("Hi")])])

      assert {:error, :agent_already_exists} =
               Team.add_agent(team, :existing, agent_opts([]))
    end
  end

  describe "remove_agent/2" do
    test "removes an agent and stops its process" do
      {:ok, team} =
        Team.start_link(agents: [doomed: agent_opts([TestProvider.text_response("Bye")])])

      pid = Team.get_agent(team, :doomed)
      assert Process.alive?(pid)

      :ok = Team.remove_agent(team, :doomed)
      Process.sleep(20)

      refute Process.alive?(pid)
      assert Team.agents(team) == []
    end

    test "returns error when removing unknown agent" do
      {:ok, team} = Team.start_link(agents: [])
      assert {:error, {:unknown_agent, :ghost}} = Team.remove_agent(team, :ghost)
    end
  end

  # ── get_agent/2 ──────────────────────────────────────────────────────

  describe "get_agent/2" do
    test "returns pid for direct Server access" do
      {:ok, team} =
        Team.start_link(agents: [worker: agent_opts([TestProvider.text_response("Direct!")])])

      pid = Team.get_agent(team, :worker)
      assert is_pid(pid)

      # Can use Server API directly
      {:ok, result} = Server.chat(pid, "Hello directly")
      assert result.text == "Direct!"
    end

    test "returns nil for unknown agent" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.get_agent(team, :nobody) == nil
    end
  end

  # ── fault isolation ──────────────────────────────────────────────────

  describe "fault isolation" do
    test "crashed agent is removed, others unaffected" do
      {:ok, team} =
        Team.start_link(
          agents: [
            stable:
              agent_opts([
                TestProvider.text_response("Still here 1"),
                TestProvider.text_response("Still here 2")
              ]),
            fragile: agent_opts([TestProvider.text_response("About to crash")])
          ]
        )

      # Verify both agents exist
      assert Team.get_agent(team, :stable) != nil
      assert Team.get_agent(team, :fragile) != nil

      # Use stable agent first
      {:ok, r1} = Team.delegate(team, :stable, "Check 1")
      assert r1.text == "Still here 1"

      # Kill fragile agent
      fragile_pid = Team.get_agent(team, :fragile)
      Process.exit(fragile_pid, :kill)
      Process.sleep(50)

      # Stable agent still works
      {:ok, r2} = Team.delegate(team, :stable, "Check 2")
      assert r2.text == "Still here 2"

      # Fragile was cleaned up
      assert Team.get_agent(team, :fragile) == nil
    end

    test "team process survives agent crash" do
      {:ok, team} =
        Team.start_link(agents: [worker: agent_opts([TestProvider.text_response("Ok")])])

      pid = Team.get_agent(team, :worker)
      Process.exit(pid, :kill)
      Process.sleep(50)

      assert Process.alive?(team)
    end
  end

  # ── shared context ────────────────────────────────────────────────────

  describe "shared context" do
    test "put_context/3 and get_context/2 store and retrieve values" do
      {:ok, team} = Team.start_link(agents: [])

      :ok = Team.put_context(team, :task_status, "in_progress")
      assert Team.get_context(team, :task_status) == "in_progress"
    end

    test "get_context/3 returns default for missing keys" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.get_context(team, :missing, :default_val) == :default_val
    end

    test "get_context/2 returns nil for missing keys" do
      {:ok, team} = Team.start_link(agents: [])
      assert Team.get_context(team, :missing) == nil
    end

    test "context persists across delegate calls" do
      {:ok, team} =
        Team.start_link(agents: [worker: agent_opts([TestProvider.text_response("Done")])])

      :ok = Team.put_context(team, :run_count, 1)
      {:ok, _} = Team.delegate(team, :worker, "Go")
      assert Team.get_context(team, :run_count) == 1
    end

    test "initial shared_context can be provided at start" do
      {:ok, team} =
        Team.start_link(
          agents: [],
          shared_context: %{project: "alloy", version: "0.2"}
        )

      assert Team.get_context(team, :project) == "alloy"
      assert Team.get_context(team, :version) == "0.2"
    end
  end

  # ── stop/1 ───────────────────────────────────────────────────────────

  describe "stop/1" do
    test "stops the team and all agent processes" do
      {:ok, team} =
        Team.start_link(
          agents: [
            a: agent_opts([TestProvider.text_response("Hi")]),
            b: agent_opts([TestProvider.text_response("Hi")])
          ]
        )

      a_pid = Team.get_agent(team, :a)
      b_pid = Team.get_agent(team, :b)

      :ok = Team.stop(team)
      Process.sleep(50)

      refute Process.alive?(team)
      refute Process.alive?(a_pid)
      refute Process.alive?(b_pid)
    end
  end
end
