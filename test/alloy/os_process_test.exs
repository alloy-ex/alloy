defmodule Alloy.OSProcessTest do
  use ExUnit.Case, async: true

  alias Alloy.OSProcess

  test "signal_group ignores nil and terminates live process groups cleanly" do
    assert :ok = OSProcess.signal_group(nil, "KILL")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", "sleep 5"]])

    os_pid = OSProcess.os_pid(port)
    assert is_integer(os_pid)
    assert :ok = OSProcess.signal_group(os_pid, "KILL")
    assert_receive {^port, {:exit_status, _}}, 1_000
    assert OSProcess.os_pid(port) == nil
  end

  test "find_sh and signal_command prefer sh, fall back to kill lazily, and return nil if neither exists" do
    assert is_binary(OSProcess.find_sh())

    assert {"/bin/sh", ["-c", _, "alloy-kill", "TERM", "123"]} =
             OSProcess.signal_command(123, "TERM", "/bin/sh", fn ->
               flunk("kill lookup must not run when sh is available")
             end)

    assert {"/usr/bin/kill", ["-s", "KILL", "--", "-123"]} =
             OSProcess.signal_command(123, "KILL", nil, fn -> "/usr/bin/kill" end)

    assert nil == OSProcess.signal_command(123, "KILL", nil, fn -> nil end)
  end
end
