defmodule Alloy.Provider.CliSession do
  @moduledoc false

  # Session continuation for the CLI-backed providers (`ClaudeCode`, `Codex`).
  #
  # Both CLIs keep their own conversation history and can resume it by id, which
  # is what buys a prompt-cache hit instead of re-sending the whole transcript
  # every turn. Each successful turn returns `provider_state: %{session_id:,
  # sent_upto:, prefix_hash:}`; `Alloy.Agent.Turn` merges it into `config` for
  # the next call.
  #
  # The hash is the safety check: if a middleware (compaction, most likely)
  # rewrote earlier history since the last call, the prefix no longer matches
  # and the turn goes out `:fresh` with the full transcript rather than resuming
  # a session built on a transcript that no longer exists.

  alias Alloy.Message

  @type plan :: {:resume, String.t(), [Message.t()]} | :fresh

  @spec plan(map(), [Message.t()]) :: plan()
  def plan(config, messages) do
    with %{session_id: id, sent_upto: n, prefix_hash: hash} <-
           Map.get(config, :provider_state),
         true <- is_binary(id) and id != "",
         true <- is_integer(n) and n >= 0,
         true <- length(messages) > n,
         true <- :erlang.phash2(Enum.take(messages, n)) == hash do
      {:resume, id, Enum.drop(messages, n)}
    else
      _ -> :fresh
    end
  end

  # What the next call needs to resume: the id, how many messages (as Alloy will
  # see them — this reply included, since the CLI's session already recorded its
  # version of this turn) it reflects, and a hash of that exact prefix.
  @spec next_state([Message.t()], Message.t(), String.t() | nil) :: map()
  def next_state(messages_before_reply, reply, session_id)
      when is_binary(session_id) and session_id != "" do
    prefix = messages_before_reply ++ [reply]

    %{session_id: session_id, sent_upto: length(prefix), prefix_hash: :erlang.phash2(prefix)}
  end

  # Not `%{}`: `Alloy.Agent.Turn` merges provider state, so an empty map keeps
  # the previous session, and the next turn would resume it one turn short.
  def next_state(_messages, _reply, _session_id), do: reset()

  @doc false
  # Provider state that makes the next turn go out fresh. Explicit nils rather
  # than an empty map, for the merge reason above.
  @spec reset() :: map()
  def reset, do: %{session_id: nil, sent_upto: nil, prefix_hash: nil}
end
