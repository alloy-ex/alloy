defmodule Alloy.OSProcess do
  @moduledoc false
  # Signals OS processes started through ports (the bash tool and the Codex
  # provider). Every port program is a session and process-group leader
  # (OTP's erl_child_setup calls setsid()), so signalling the negative pid
  # reaches the program and everything it started, background jobs included.

  require Logger

  @doc """
  The OS pid of a port's program, or `nil` when it already exited — its
  output and exit-status messages are still in the mailbox, so callers
  collect them as usual; there is just no process left to signal.
  """
  @spec os_pid(port()) :: non_neg_integer() | nil
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      nil -> nil
    end
  end

  @doc """
  Sends `signal` to the process group led by `os_pid`. A group that has
  already exited is not an error.
  """
  @spec signal_group(non_neg_integer() | nil, String.t()) :: :ok
  def signal_group(nil, _signal), do: :ok

  # Prefer `sh`'s builtin `kill`, falling back to a `kill` executable when
  # `/bin/sh` is unavailable (e.g. minimal/distroless containers). Every
  # inherited variable is unset so nothing in the BEAM's environment leaks.
  def signal_group(os_pid, signal) when is_integer(os_pid) and signal in ["TERM", "KILL"] do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    case find_signal_command(os_pid, signal) do
      {cmd, args} ->
        {_output, _status} = System.cmd(cmd, args, env: no_env, stderr_to_stdout: true)
        :ok

      nil ->
        Logger.warning(
          "[Alloy.OSProcess] Unable to send SIG#{signal} to process group -#{os_pid}: " <>
            "neither sh nor kill executable found"
        )

        :ok
    end
  end

  @doc """
  Locate a POSIX `sh` executable, preferring `/bin/sh` before scanning `PATH`.
  """
  @spec find_sh() :: String.t() | nil
  def find_sh do
    if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
  end

  @doc false
  @spec signal_command(non_neg_integer(), String.t(), String.t() | nil, (-> String.t() | nil)) ::
          {String.t(), [String.t()]} | nil
  def signal_command(os_pid, signal, sh, find_kill) do
    case sh do
      sh when is_binary(sh) ->
        {sh, ["-c", ~S(kill -s "$1" -- "-$2"), "alloy-kill", signal, Integer.to_string(os_pid)]}

      nil ->
        case find_kill.() do
          kill when is_binary(kill) -> {kill, ["-s", signal, "--", "-#{os_pid}"]}
          nil -> nil
        end
    end
  end

  defp find_signal_command(os_pid, signal) do
    signal_command(os_pid, signal, find_sh(), fn -> System.find_executable("kill") end)
  end
end
