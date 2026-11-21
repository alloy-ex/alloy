defmodule Alloy.OSProcess do
  @moduledoc false
  # Signals OS processes started through ports (the bash tool and the Codex
  # provider). Every port program is a session and process-group leader
  # (OTP's erl_child_setup calls setsid()), so signalling the negative pid
  # reaches the program and everything it started, background jobs included.
  # On Windows the port's program is cmd.exe (Codex), and its tree is killed.

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

  def signal_group(os_pid, signal) when is_integer(os_pid) and signal in ["TERM", "KILL"] do
    {command, args, opts} = signal_command(:os.type(), os_pid, signal)
    {_output, _status} = System.cmd(command, args, opts)
    :ok
  end

  @doc """
  The command that delivers `signal` to `os_pid`'s group on `os_type`.
  """
  @spec signal_command({:unix | :win32, atom()}, non_neg_integer(), String.t()) ::
          {String.t(), [String.t()], keyword()}
  # Windows has no signals or process groups: the port's program is cmd.exe,
  # and `taskkill /T /F` ends it and every process it started. There is no
  # graceful stop for a console program, so TERM is forceful too.
  def signal_command({:win32, _}, os_pid, _signal) do
    {"taskkill", ["/T", "/F", "/PID", Integer.to_string(os_pid)], stderr_to_stdout: true}
  end

  # `kill` is a shell builtin, so no kill binary is needed and the shell runs
  # with every inherited variable unset: nothing in the BEAM's environment
  # reaches it.
  def signal_command({:unix, _}, os_pid, signal) do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)
    args = ["-c", ~S(kill -s "$1" -- "-$2"), "alloy-kill", signal, Integer.to_string(os_pid)]
    {"/bin/sh", args, env: no_env, stderr_to_stdout: true}
  end
end
