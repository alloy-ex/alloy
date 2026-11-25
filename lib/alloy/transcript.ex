defmodule Alloy.Transcript do
  @moduledoc """
  Explicit validation and repair of client tool-call/result pairing.

  Accepts normalized `Alloy.Message` structs. Block keys may be atoms or
  strings. Provider-owned server tools are left untouched. Call IDs must be
  unique within a round; reuse in a later round is allowed.

  `repair/1` supplies error results for missing outcomes before the next
  conversational message, or at the end. It preserves existing outcomes and
  never executes tools. Duplicate, orphaned, or malformed calls/results are
  ambiguous and cannot be repaired. Neither function runs automatically.
  """

  alias Alloy.Message

  @type issue :: %{kind: atom(), id: term()}

  @doc "Checks tool pairing, returning all detected issues."
  @spec validate([Message.t()]) :: :ok | {:error, [issue()]}
  def validate(messages) when is_list(messages) do
    case scan(messages).errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "Supplies explicitly interrupted outcomes for missing results only."
  @spec repair([Message.t()]) :: {:ok, [Message.t()]} | {:error, [issue()]}
  def repair(messages) when is_list(messages) do
    state = scan(messages)
    ambiguous = Enum.reject(state.errors, &(&1.kind == :missing_result))

    case ambiguous do
      [] -> {:ok, Enum.reverse(state.messages)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp scan(messages) do
    initial = %{messages: [], errors: [], pending: [], answered: MapSet.new()}
    messages |> Enum.reduce(initial, &visit/2) |> flush()
  end

  defp visit(%Message{role: :assistant} = message, state) do
    state = flush(state)
    calls = blocks(message, "tool_use")
    ids = Enum.map(calls, &field(&1, :id))
    errors = call_errors(ids) ++ role_errors(message, "tool_result")

    %{
      state
      | messages: [message | state.messages],
        pending: ids |> Enum.filter(&valid_id?/1) |> Enum.uniq(),
        answered: MapSet.new(),
        errors: Enum.reverse(errors) ++ state.errors
    }
  end

  defp visit(%Message{role: :user, content: content} = message, state) when is_list(content) do
    {results, other} = Enum.split_with(content, &(field(&1, :type) == "tool_result"))
    state = %{state | errors: Enum.reverse(role_errors(message, "tool_use")) ++ state.errors}
    user_results(message, results, other, state)
  end

  defp visit(%Message{} = message, state), do: state |> flush() |> append(message)

  defp user_results(message, [], _other, state), do: state |> flush() |> append(message)

  defp user_results(message, results, [], state) do
    results |> Enum.reduce(state, &consume/2) |> append(message)
  end

  defp user_results(message, results, other, state) do
    state = Enum.reduce(results, state, &consume/2)
    {missing, state} = missing_results(state)

    cond do
      message.content != results ++ other ->
        state |> issue(:misplaced_result, nil) |> append(message)

      missing == [] ->
        append(state, message)

      true ->
        append(state, %{message | content: results ++ missing ++ other})
    end
  end

  defp consume(result, state) do
    id = field(result, :tool_use_id)

    cond do
      not valid_id?(id) ->
        issue(state, :invalid_result, id)

      MapSet.member?(state.answered, id) ->
        issue(state, :duplicate_result, id)

      id not in state.pending ->
        issue(state, :orphan_result, id)

      true ->
        %{
          state
          | pending: List.delete(state.pending, id),
            answered: MapSet.put(state.answered, id)
        }
    end
  end

  defp call_errors(ids) do
    invalid = for id <- ids, not valid_id?(id), do: %{kind: :invalid_call, id: id}

    duplicate =
      for {id, count} <- Enum.frequencies(ids), count > 1, do: %{kind: :duplicate_call, id: id}

    invalid ++ duplicate
  end

  defp role_errors(message, type) do
    for block <- blocks(message, type),
        do: %{kind: :wrong_role, id: field(block, :id) || field(block, :tool_use_id)}
  end

  defp flush(state) do
    case missing_results(state) do
      {[], state} -> state
      {missing, state} -> append(state, Message.tool_results(missing))
    end
  end

  defp missing_results(state) do
    missing =
      Enum.map(
        state.pending,
        &Message.tool_result_block(
          &1,
          "Interrupted: no tool result was recorded; execution outcome is unknown.",
          true
        )
      )

    state = Enum.reduce(state.pending, state, &issue(&2, :missing_result, &1))
    {missing, %{state | pending: [], answered: MapSet.new()}}
  end

  defp append(state, message), do: %{state | messages: [message | state.messages]}
  defp issue(state, kind, id), do: %{state | errors: [%{kind: kind, id: id} | state.errors]}
  defp valid_id?(id), do: is_binary(id) and byte_size(id) > 0

  defp blocks(%Message{content: content}, type) when is_list(content),
    do: Enum.filter(content, &(field(&1, :type) == type))

  defp blocks(_message, _type), do: []

  defp field(block, key) when is_map(block),
    do: Map.get(block, key, Map.get(block, Atom.to_string(key)))

  defp field(_block, _key), do: nil
end
