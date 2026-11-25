defmodule Alloy.TranscriptTest do
  use ExUnit.Case, async: true

  alias Alloy.{Message, Transcript}

  defp calls(ids),
    do:
      Message.assistant_blocks(
        Enum.map(ids, &%{type: "tool_use", id: &1, name: "read", input: %{}})
      )

  defp results(ids), do: Message.tool_results(Enum.map(ids, &Message.tool_result_block(&1, "ok")))

  test "empty and ordinary transcripts are unchanged" do
    for messages <- [[], [Message.user("hello"), Message.assistant("hi")]] do
      assert :ok = Transcript.validate(messages)
      assert {:ok, ^messages} = Transcript.repair(messages)
    end
  end

  test "partial batches retain existing results and repair at end" do
    first = results(["a"])
    assert {:ok, [_, ^first, repaired]} = Transcript.repair([calls(["a", "b"]), first])
    assert [%{tool_use_id: "b", is_error: true, content: content}] = repaired.content
    assert content =~ "unknown"
  end

  test "results can arrive in separate messages and out of call order" do
    messages = [calls(["a", "b"]), results(["b"]), results(["a"])]
    assert :ok = Transcript.validate(messages)
    assert {:ok, ^messages} = Transcript.repair(messages)
  end

  test "missing outcomes precede subsequent messages and repair is idempotent" do
    assistant = calls(["a"])

    for next <- [Message.assistant("next"), Message.user("continue")] do
      messages = [assistant, next]
      assert {:error, [%{kind: :missing_result, id: "a"}]} = Transcript.validate(messages)
      assert {:ok, [^assistant, results, ^next] = repaired} = Transcript.repair(messages)
      assert %Message{role: :user, content: [%{tool_use_id: "a", is_error: true}]} = results
      assert :ok = Transcript.validate(repaired)
      assert {:ok, ^repaired} = Transcript.repair(repaired)
    end
  end

  test "mixed result and user content places missing outcomes before user text" do
    message =
      Message.tool_results([
        Message.tool_result_block("a", "ok"),
        %{type: "text", text: "continue"}
      ])

    assert {:ok, [_, repaired]} = Transcript.repair([calls(["a", "b"]), message])

    assert [%{tool_use_id: "a"}, %{tool_use_id: "b", is_error: true}, %{text: "continue"}] =
             repaired.content

    assert :ok = Transcript.validate([calls(["a", "b"]), repaired])
  end

  test "ambiguous outcomes are rejected rather than dropped or reassigned" do
    for {messages, kind} <- [
          {[results(["a"])], :orphan_result},
          {[calls(["a", "a"]), results(["a"])], :duplicate_call},
          {[calls(["a"]), results(["a", "a"])], :duplicate_result},
          {[calls([nil])], :invalid_call},
          {[results([nil])], :invalid_result},
          {[Message.assistant_blocks(results(["a"]).content)], :wrong_role},
          {[Message.tool_results(calls(["a"]).content)], :wrong_role}
        ] do
      assert {:error, issues} = Transcript.repair(messages)
      assert Enum.any?(issues, &(&1.kind == kind))
    end
  end

  test "mixed messages preserve order and reject results placed after user text" do
    valid =
      Message.tool_results([Message.tool_result_block("a", "ok"), %{type: "text", text: "next"}])

    messages = [calls(["a"]), valid]
    assert {:ok, ^messages} = Transcript.repair(messages)
    misplaced = %{valid | content: Enum.reverse(valid.content)}
    assert {:error, [%{kind: :misplaced_result}]} = Transcript.repair([calls(["a"]), misplaced])
  end

  test "call IDs may be reused in later rounds without cross-round matching" do
    messages = [calls(["a"]), results(["a"]), calls(["a"])]
    assert {:error, [%{kind: :missing_result, id: "a"}]} = Transcript.validate(messages)
    assert {:ok, repaired} = Transcript.repair(messages)
    assert :ok = Transcript.validate(repaired)
  end

  test "string-keyed restored blocks are paired and server tools remain untouched" do
    messages = [
      Message.assistant_blocks([
        %{"type" => "tool_use", "id" => "a", "name" => "read"},
        %{type: "server_tool_use", id: "server", name: "search"},
        %{type: "text", text: "looking"}
      ]),
      Message.tool_results([%{"type" => "tool_result", "tool_use_id" => "a", "content" => "ok"}])
    ]

    assert :ok = Transcript.validate(messages)
    assert {:ok, ^messages} = Transcript.repair(messages)
  end

  test "validate does not emit spurious :missing_result for invalid call IDs" do
    messages = [
      Message.assistant_blocks([%{type: "tool_use", id: "", name: "read", input: %{}}])
    ]

    assert {:error, [%{kind: :invalid_call, id: ""}]} = Transcript.validate(messages)
  end
end
