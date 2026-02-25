defmodule Anvil.SchedulerTest do
  use ExUnit.Case, async: true

  alias Anvil.Scheduler
  alias Anvil.Provider.Test, as: TestProvider

  defp make_agent_opts(responses) do
    {:ok, pid} = TestProvider.start_link(responses)

    [
      provider: {Anvil.Provider.Test, agent_pid: pid},
      tools: []
    ]
  end

  describe "start_link/1" do
    test "starts with no jobs" do
      assert {:ok, pid} = Scheduler.start_link(jobs: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with initial jobs" do
      agent_opts = make_agent_opts([TestProvider.text_response("ok")])

      assert {:ok, pid} =
               Scheduler.start_link(
                 jobs: [
                   %{
                     name: :test_job,
                     every: :timer.minutes(60),
                     prompt: "Say hi",
                     agent_opts: agent_opts
                   }
                 ]
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "list_jobs/1" do
    test "lists registered jobs" do
      agent_opts = make_agent_opts([TestProvider.text_response("ok")])

      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{name: :alpha, every: 1000, prompt: "A", agent_opts: agent_opts},
            %{name: :beta, every: 2000, prompt: "B", agent_opts: agent_opts}
          ]
        )

      jobs = Scheduler.list_jobs(pid)
      assert length(jobs) == 2
      names = Enum.map(jobs, & &1.name) |> Enum.sort()
      assert names == [:alpha, :beta]
      GenServer.stop(pid)
    end
  end

  describe "scheduling" do
    test "fires job on schedule" do
      test_pid = self()

      agent_opts =
        make_agent_opts([
          TestProvider.text_response("scheduled reply 1"),
          TestProvider.text_response("scheduled reply 2")
        ])

      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :fast_job,
              every: 50,
              prompt: "Tick",
              agent_opts: agent_opts,
              on_result: fn result -> send(test_pid, {:job_result, result}) end
            }
          ]
        )

      # Wait for at least one execution
      assert_receive {:job_result, {:ok, result}}, 2000
      assert result.text == "scheduled reply 1"
      GenServer.stop(pid)
    end

    test "skips tick if job is still running" do
      test_pid = self()

      # Provider that takes a while to respond (simulated by many responses)
      {:ok, provider_pid} =
        TestProvider.start_link([
          TestProvider.text_response("slow response"),
          TestProvider.text_response("second response")
        ])

      # Use a very short interval — the job should overlap
      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :slow_job,
              every: 30,
              prompt: "Slow tick",
              agent_opts: [
                provider: {Anvil.Provider.Test, agent_pid: provider_pid},
                tools: []
              ],
              on_result: fn result -> send(test_pid, {:slow_result, result}) end
            }
          ]
        )

      # First should fire
      assert_receive {:slow_result, {:ok, _}}, 2000
      # Scheduler should still be alive (didn't crash from overlap)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "add_job/2 and remove_job/2" do
    test "adds a job dynamically" do
      test_pid = self()
      {:ok, pid} = Scheduler.start_link(jobs: [])
      assert Scheduler.list_jobs(pid) == []

      agent_opts = make_agent_opts([TestProvider.text_response("dynamic reply")])

      :ok =
        Scheduler.add_job(pid, %{
          name: :dynamic_job,
          every: 50,
          prompt: "Dynamic",
          agent_opts: agent_opts,
          on_result: fn result -> send(test_pid, {:dynamic_result, result}) end
        })

      assert length(Scheduler.list_jobs(pid)) == 1
      assert_receive {:dynamic_result, {:ok, result}}, 2000
      assert result.text == "dynamic reply"
      GenServer.stop(pid)
    end

    test "removes a job" do
      agent_opts = make_agent_opts([TestProvider.text_response("ok")])

      {:ok, pid} =
        Scheduler.start_link(
          jobs: [%{name: :removable, every: 60_000, prompt: "X", agent_opts: agent_opts}]
        )

      assert length(Scheduler.list_jobs(pid)) == 1
      :ok = Scheduler.remove_job(pid, :removable)
      assert Scheduler.list_jobs(pid) == []
      GenServer.stop(pid)
    end
  end

  describe "trigger/2" do
    test "manually triggers a job immediately" do
      test_pid = self()
      agent_opts = make_agent_opts([TestProvider.text_response("manual reply")])

      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :manual_job,
              every: :timer.minutes(60),
              prompt: "Manual trigger",
              agent_opts: agent_opts,
              on_result: fn result -> send(test_pid, {:manual_result, result}) end
            }
          ]
        )

      :ok = Scheduler.trigger(pid, :manual_job)
      assert_receive {:manual_result, {:ok, result}}, 2000
      assert result.text == "manual reply"
      GenServer.stop(pid)
    end

    test "returns error for unknown job" do
      {:ok, pid} = Scheduler.start_link(jobs: [])
      assert {:error, :not_found} = Scheduler.trigger(pid, :nonexistent)
      GenServer.stop(pid)
    end
  end
end
