defmodule Alloy.OSProcess do
  @moduledoc false
  # Signals OS processes started through ports (the bash tool and the Codex
  # provider). Every port program is a session and process-group leader
  # (OTP's erl_child_setup calls setsid()), so signalling the negative pid
  # reaches the program and everything it started, background jobs included.

  @doc """
  Sends `signal` to the process group led by `os_pid`. A group that has
  already exited is not an error.
  """
  @spec signal_group(non_neg_integer() | nil, String.t()) :: :ok
  def signal_group(nil, _signal), do: :ok

  # `kill` is a shell builtin, so no kill binary is needed and the shell runs
  # with every inherited variable unset: nothing in the BEAM's environment
  # reaches it.
  def signal_group(os_pid, signal) when is_integer(os_pid) and signal in ["TERM", "KILL"] do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)
    args = ["-c", ~S(kill -s "$1" -- "-$2"), "alloy-kill", signal, Integer.to_string(os_pid)]
    {_output, _status} = System.cmd("/bin/sh", args, env: no_env, stderr_to_stdout: true)
    :ok
  end
end
