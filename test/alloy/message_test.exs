defmodule Alloy.MessageTest do
  use ExUnit.Case, async: true

  alias Alloy.Message

  describe "user/1 and assistant/1" do
    test "user/1 creates a user text message" do
      msg = Message.user("hello")
      assert msg.role == :user
      assert msg.content == "hello"
    end

    test "assistant/1 creates an assistant text message" do
      msg = Message.assistant("hi")
      assert msg.role == :assistant
      assert msg.content == "hi"
    end
  end

  describe "media block helpers" do
    test "image/2 creates an image content block" do
      block = Message.image("image/jpeg", "base64data")
      assert block == %{type: "image", mime_type: "image/jpeg", data: "base64data"}
    end

    test "audio/2 creates an audio content block" do
      block = Message.audio("audio/mp3", "base64audio")
      assert block == %{type: "audio", mime_type: "audio/mp3", data: "base64audio"}
    end

    test "video/2 creates a video content block" do
      block = Message.video("video/mp4", "base64video")
      assert block == %{type: "video", mime_type: "video/mp4", data: "base64video"}
    end

    test "document/2 creates a document content block with uri" do
      block = Message.document("application/pdf", "gs://bucket/report.pdf")

      assert block == %{
               type: "document",
               mime_type: "application/pdf",
               uri: "gs://bucket/report.pdf"
             }
    end
  end

  describe "composing media blocks into messages" do
    test "user message can hold mixed text and image blocks" do
      img = Message.image("image/jpeg", "data123")
      msg = %Message{role: :user, content: [%{type: "text", text: "What is this?"}, img]}

      assert msg.role == :user
      assert length(msg.content) == 2
      assert Enum.find(msg.content, &(&1.type == "image"))
    end
  end

  describe "tool_calls/1 with server_tool_use" do
    # The provider already executed server tools (code execution, web search,
    # tool search). Answering them client-side makes the API reject the turn.
    test "ignores server_tool_use blocks; only client tool_use blocks are calls" do
      msg =
        Message.assistant_blocks([
          %{type: "text", text: "Running code..."},
          %{type: "server_tool_use", id: "srvtoolu_01", name: "code_execution", input: %{}},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{}}
        ])

      assert [%{type: "tool_use", id: "toolu_01"}] = Message.tool_calls(msg)
    end

    test "returns no calls when the message only has server tool use" do
      msg =
        Message.assistant_blocks([
          %{type: "server_tool_use", id: "srvtoolu_01", name: "web_search", input: %{}}
        ])

      assert Message.tool_calls(msg) == []
    end
  end

  describe "text/1" do
    test "extracts text from a string-content message" do
      assert Message.text(Message.user("hello")) == "hello"
    end

    test "extracts text blocks from a block-content message, ignoring media" do
      msg = %Message{
        role: :user,
        content: [
          %{type: "text", text: "describe this"},
          Message.image("image/jpeg", "data")
        ]
      }

      assert Message.text(msg) == "describe this"
    end

    test "returns empty string when only media blocks are present" do
      msg = %Message{
        role: :user,
        content: [Message.image("image/jpeg", "data")]
      }

      assert Message.text(msg) == ""
    end

    test "returns empty string for empty block list" do
      msg = %Message{role: :user, content: []}
      assert Message.text(msg) == ""
    end
  end

  describe "thinking/1" do
    test "extracts and joins thinking blocks, ignoring text/tool blocks" do
      msg =
        Message.assistant_blocks([
          %{type: "thinking", thinking: "step one"},
          %{type: "text", text: "the answer"},
          %{type: "thinking", thinking: "step two"}
        ])

      assert Message.thinking(msg) == "step one\nstep two"
    end

    test "returns nil for a string-content message" do
      assert Message.thinking(Message.assistant("hi")) == nil
    end

    test "returns nil when no thinking blocks are present" do
      msg = Message.assistant_blocks([%{type: "text", text: "the answer"}])
      assert Message.thinking(msg) == nil
    end
  end

  describe "normalize_for/2" do
    @anthropic Alloy.Provider.Anthropic
    @openai Alloy.Provider.OpenAI

    defp from(provider, blocks),
      do: %{Message.assistant_blocks(blocks) | provider: provider, model: "m"}

    test "leaves the target provider's own, user-built and user messages alone" do
      own = from(@anthropic, [%{type: "thinking", thinking: "t", signature: "sig"}])

      hand_built =
        Message.assistant_blocks([%{type: "thinking", thinking: "t", signature: "sig"}])

      other_model = %{own | model: "another-claude"}

      messages = [Message.user("hi"), own, hand_built, other_model]
      assert Message.normalize_for(messages, @anthropic) == messages
    end

    test "turns another provider's thinking into text and drops what only it can read" do
      message =
        from(@anthropic, [
          %{type: "thinking", thinking: "I should read the file", signature: "sig"},
          %{type: "thinking", thinking: "   ", signature: "sig2"},
          %{type: "redacted_thinking", data: "opaque"},
          %{type: "server_tool_use", id: "srv_1", name: "web_search", input: %{}},
          %{type: "web_search_tool_result", tool_use_id: "srv_1", content: []},
          %{type: "text", text: "Reading it.", signature: "gemini-sig"}
        ])

      assert [%Message{content: content, provider: @anthropic}] =
               Message.normalize_for([message], @openai)

      assert content == [
               %{type: "text", text: "I should read the file"},
               %{type: "text", text: "Reading it."}
             ]
    end

    test "drops OpenAI raw items and a message left empty" do
      message = from(@openai, [%{type: "reasoning", raw: %{"type" => "reasoning"}}])

      assert Message.normalize_for([Message.user("hi"), message], @anthropic) == [
               Message.user("hi")
             ]
    end

    test "strips call signatures and rewrites ids the target would reject, with their results" do
      call = %{
        type: "tool_use",
        id: "functions.read:0",
        name: "read",
        input: %{},
        thought_signature: "sig"
      }

      result = Message.tool_results([Message.tool_result_block("functions.read:0", "ok")])
      unrelated = Message.tool_results([Message.tool_result_block("toolu_1", "ok")])

      assert [%Message{content: [new_call]}, %Message{content: [new_result]}, ^unrelated] =
               Message.normalize_for(
                 [from(Alloy.Provider.OpenAICompat, [call]), result, unrelated],
                 @anthropic
               )

      assert %{type: "tool_use", id: "functions_read_0_" <> hash, name: "read", input: %{}} =
               new_call

      assert byte_size(hash) == 8
      assert new_result.tool_use_id == new_call.id
    end

    test "rewritten ids are at most 64 characters, distinct and stable" do
      calls =
        for id <- ["a.b", "a:b", String.duplicate("x", 100), ""],
            do: %{type: "tool_use", id: id, name: "read", input: %{}}

      message = from(@openai, calls)
      [%Message{content: rewritten}] = Message.normalize_for([message], @anthropic)
      ids = Enum.map(rewritten, & &1.id)

      assert Enum.all?(ids, &Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, &1))
      assert ids == Enum.uniq(ids)
      assert [%Message{content: ^rewritten}] = Message.normalize_for([message], @anthropic)
    end
  end
end
