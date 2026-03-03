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
    test "tool_calls returns both tool_use and server_tool_use blocks" do
      msg = Message.assistant_blocks([
        %{type: "text", text: "Running code..."},
        %{type: "tool_use", id: "toolu_01", name: "read", input: %{}},
        %{type: "server_tool_use", id: "srvtoolu_01", name: "write", input: %{"path" => "a.txt"}}
      ])

      calls = Message.tool_calls(msg)
      assert length(calls) == 2
      assert Enum.any?(calls, &(&1.type == "tool_use"))
      assert Enum.any?(calls, &(&1.type == "server_tool_use"))
    end

    test "tool_calls returns only server_tool_use when no regular tool_use" do
      msg = Message.assistant_blocks([
        %{type: "server_tool_use", id: "srvtoolu_01", name: "read", input: %{}}
      ])

      calls = Message.tool_calls(msg)
      assert length(calls) == 1
      assert hd(calls).type == "server_tool_use"
    end
  end

  describe "server_tool_result_block/3" do
    test "creates a server_tool_result block" do
      block = Message.server_tool_result_block("srvtoolu_01", "file contents here")
      assert block.type == "server_tool_result"
      assert block.tool_use_id == "srvtoolu_01"
      assert block.content == "file contents here"
      refute Map.has_key?(block, :is_error)
    end

    test "creates a server_tool_result error block" do
      block = Message.server_tool_result_block("srvtoolu_01", "something failed", true)
      assert block.type == "server_tool_result"
      assert block.tool_use_id == "srvtoolu_01"
      assert block.content == "something failed"
      assert block.is_error == true
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
end
