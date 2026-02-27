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

    test "returns nil when only media blocks are present" do
      msg = %Message{
        role: :user,
        content: [Message.image("image/jpeg", "data")]
      }

      assert Message.text(msg) == nil
    end
  end
end
