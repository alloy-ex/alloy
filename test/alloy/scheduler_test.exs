defmodule Alloy.SchedulerTest.BlockingProvider do
  @moduledoc false
  @behaviour Alloy.Provider

  @impl true
  def complete(_messages, _tool_defs, config) do
    send(config[:notify_pid], {:provider_called, self()})

    receive do
      :unblock ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Alloy.Message.assistant("done")],
           usage: %{input_tokens: 10, output_tokens: 5}
         }}
    end
  end

  @impl true
  def stream(_, _, _, _), do: {:error, :not_supported}
end

defmodule Alloy.SchedulerTest do
  use ExUnit.Case, async: true

  alias Alloy.Scheduler
  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.SchedulerTest.BlockingProvider

  defp make_agent_opts(responses) do
    {:ok, pid} = TestProvider.start_link(responses)

    [
      provider: {Alloy.Provider.Test, agent_pid: pid},
      tools: []
    ]
  end

  describe "start_link/1" do
    test "starts with no jobs" do
      assert {:ok, pid} = Scheduler.start_link(jobs: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts an external task_supervisor" do
      {:ok, sup} = Task.Supervisor.start_link()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          task_supervisor: sup,
          jobs: [
            %{
              name: :sup_job,
              every: :timer.minutes(60),
              prompt: "Block",
              agent_opts: [
                provider: {BlockingProvider, notify_pid: test_pid},
                tools: []
              ]
            }
          ]
        )

      # Trigger the job — blocks in provider
      :ok = Scheduler.trigger(pid, :sup_job)
      assert_receive {:provider_called, task_pid}, 1000

      # The external supervisor should have children (proves it was used)
      children = Task.Supervisor.children(sup)
      assert length(children) > 0

      # Clean up
      send(task_pid, :unblock)
      GenServer.stop(pid)

      # External supervisor survives scheduler shutdown
      assert Process.alive?(sup)
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

      # Use a blocking provider — the job runs until we say "unblock"
      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :slow_job,
              every: 30,
              prompt: "Slow tick",
              agent_opts: [
                provider: {BlockingProvider, notify_pid: test_pid},
                tools: []
              ]
            }
          ]
        )

      # First tick fires and calls the provider — job is now running
      assert_receive {:provider_called, task_pid}, 1000

      # Let many ticks fire while job is blocked (~200ms / 30ms = ~6 ticks)
      Process.sleep(200)

      # Provider should NOT have been called again (all ticks skipped)
      refute_receive {:provider_called, _}

      # Scheduler is still alive
      assert Process.alive?(pid)

      # Clean up
      send(task_pid, :unblock)
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

    test "replacing a running job discards stale task result" do
      test_pid = self()

      # Start a blocking job with callback A
      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :replaceable,
              every: :timer.minutes(60),
              prompt: "Old prompt",
              agent_opts: [
                provider: {BlockingProvider, notify_pid: test_pid},
                tools: []
              ],
              on_result: fn result -> send(test_pid, {:old_callback, result}) end
            }
          ]
        )

      # Trigger the job — it blocks in the provider
      :ok = Scheduler.trigger(pid, :replaceable)
      assert_receive {:provider_called, task_pid}, 1000

      # Replace the job while the old one is still running
      new_agent_opts = make_agent_opts([TestProvider.text_response("new response")])

      :ok =
        Scheduler.add_job(pid, %{
          name: :replaceable,
          every: :timer.minutes(60),
          prompt: "New prompt",
          agent_opts: new_agent_opts,
          on_result: fn result -> send(test_pid, {:new_callback, result}) end
        })

      # Unblock the old task — it completes with the old provider's result
      send(task_pid, :unblock)

      # Neither callback should be called — the result is stale
      refute_receive {:old_callback, _}, 200
      refute_receive {:new_callback, _}, 100

      GenServer.stop(pid)
    end

    test "replacing a job with same name cancels old timer" do
      test_pid = self()

      agent_opts =
        make_agent_opts([
          TestProvider.text_response("old response"),
          TestProvider.text_response("should not fire")
        ])

      # Start with a fast-ticking job
      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :alpha,
              every: 100,
              prompt: "Old prompt",
              agent_opts: agent_opts,
              on_result: fn result -> send(test_pid, {:alpha_result, result}) end
            }
          ]
        )

      # Replace with a very long interval — old timer should be cancelled
      new_agent_opts = make_agent_opts([TestProvider.text_response("new response")])

      :ok =
        Scheduler.add_job(pid, %{
          name: :alpha,
          every: :timer.minutes(60),
          prompt: "New prompt",
          agent_opts: new_agent_opts,
          on_result: fn result -> send(test_pid, {:alpha_result, result}) end
        })

      # Should only have 1 job registered
      assert length(Scheduler.list_jobs(pid)) == 1

      # If old timer was properly cancelled, no tick fires within 300ms
      # (old timer would fire at ~100ms if not cancelled)
      refute_receive {:alpha_result, _}, 300

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

    test "returns error when job is already running" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          jobs: [
            %{
              name: :blocking_job,
              every: :timer.minutes(60),
              prompt: "Block",
              agent_opts: [
                provider: {BlockingProvider, notify_pid: test_pid},
                tools: []
              ]
            }
          ]
        )

      # Trigger the job — provider blocks until we send :unblock
      :ok = Scheduler.trigger(pid, :blocking_job)

      # Wait for the provider to actually be called (job is now running)
      assert_receive {:provider_called, task_pid}, 1000

      # Second trigger should fail — job is still running
      assert {:error, :already_running} = Scheduler.trigger(pid, :blocking_job)

      # Clean up — unblock the provider so the task completes
      send(task_pid, :unblock)
      GenServer.stop(pid)
    end

    test "returns error for unknown job" do
      {:ok, pid} = Scheduler.start_link(jobs: [])
      assert {:error, :not_found} = Scheduler.trigger(pid, :nonexistent)
      GenServer.stop(pid)
    end
  end
end
