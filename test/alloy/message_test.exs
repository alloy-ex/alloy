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

    test "image_url/2, document_data/3, and document_file/3 build multimodal blocks" do
      assert Message.image_url("https://example.com/a.png") == %{
               type: "image",
               url: "https://example.com/a.png"
             }

      assert Message.image_url("https://example.com/a.png", mime_type: "image/png") == %{
               type: "image",
               url: "https://example.com/a.png",
               mime_type: "image/png"
             }

      assert Message.document_data("application/pdf", "JVBERi0=",
               filename: "spec.pdf",
               title: "Spec"
             ) == %{
               type: "document",
               mime_type: "application/pdf",
               data: "JVBERi0=",
               filename: "spec.pdf",
               title: "Spec"
             }

      assert Message.document_file("application/pdf", "file_123", title: "Invoice") == %{
               type: "document",
               mime_type: "application/pdf",
               file_id: "file_123",
               title: "Invoice"
             }
    end

    test "origin/2 never invokes function api_key, distinguishes captured accounts, and respects :origin_key" do
      make_auth = fn acct ->
        fn -> raise "should never be invoked: #{acct}" end
      end

      f_a = make_auth.("account-a")
      f_b = make_auth.("account-b")

      o_a = Message.origin(Alloy.Provider.Anthropic, %{api_key: f_a})
      o_b = Message.origin(Alloy.Provider.Anthropic, %{api_key: f_b})
      assert o_a == Message.origin(Alloy.Provider.Anthropic, %{api_key: f_a})
      refute o_a == o_b

      ok1 =
        Message.origin(Alloy.Provider.Anthropic, %{
          api_key: fn -> "tok1" end,
          origin_key: "acct-a"
        })

      ok2 =
        Message.origin(Alloy.Provider.Anthropic, %{
          api_key: fn -> "tok2" end,
          origin_key: "acct-a"
        })

      assert ok1 == ok2
    end

    test "normalize_for/3 drops cross-origin file_id documents on both user and assistant messages" do
      ant_origin = Message.origin(Alloy.Provider.Anthropic, %{api_key: "k1"})

      user_mixed = %Message{
        role: :user,
        content: [
          %{type: "text", text: "Check this PDF"},
          Message.document_file("application/pdf", "file_ant_1", origin: ant_origin),
          Message.document_data("application/pdf", "JVBERi0=")
        ]
      }

      user_only_file = %Message{
        role: :user,
        origin: ant_origin,
        content: [Message.document_file("application/pdf", "file_ant_2")]
      }

      assistant_msg = %Message{
        role: :assistant,
        origin: ant_origin,
        content: [
          %{type: "text", text: "See attached"},
          Message.document_file("application/pdf", "file_secret"),
          Message.document_data("application/pdf", "JVBERi0=")
        ]
      }

      # Same origin keeps user file_id attachments intact.
      [same_mixed, same_only, _] =
        Message.normalize_for(
          [user_mixed, user_only_file, assistant_msg],
          Alloy.Provider.Anthropic,
          %{api_key: "k1"}
        )

      assert Enum.any?(same_mixed.content, &match?(%{file_id: "file_ant_1"}, &1))
      assert Enum.any?(same_only.content, &match?(%{file_id: "file_ant_2"}, &1))

      # Different origin drops foreign file_id blocks on both user and assistant messages.
      [norm_mixed, norm_only, norm_asst] =
        Message.normalize_for(
          [user_mixed, user_only_file, assistant_msg],
          Alloy.Provider.OpenAI,
          %{api_key: "k2"}
        )

      assert norm_mixed.content == [
               %{type: "text", text: "Check this PDF"},
               %{type: "text", text: "[Omitted provider-specific file attachment]"},
               %{type: "document", mime_type: "application/pdf", data: "JVBERi0="}
             ]

      assert norm_only.content == [
               %{type: "text", text: "[Omitted provider-specific file attachment]"}
             ]

      assert norm_asst.content == [
               %{type: "text", text: "See attached"},
               %{type: "document", mime_type: "application/pdf", data: "JVBERi0="}
             ]

      # Gemini File API URIs passed via document/2 are also origin-scoped:
      # attributed to Gemini, preserved on the same Gemini origin, and replaced
      # with an omission notice on another provider or another Gemini account.
      gem_origin = Message.origin(Alloy.Provider.Gemini, %{api_key: "gem-k1"})
      gem_uri = "https://generativelanguage.googleapis.com/v1beta/files/abc123"

      gem_user = %Message{
        role: :user,
        content: [
          %{type: "text", text: "Read this"},
          Message.document("application/pdf", gem_uri)
        ]
      }

      [attributed_gem_user] = Message.attribute_file_blocks([gem_user], gem_origin)
      assert [_, %{uri: ^gem_uri, origin: ^gem_origin}] = attributed_gem_user.content

      [same_gem] =
        Message.normalize_for([attributed_gem_user], Alloy.Provider.Gemini, %{api_key: "gem-k1"})

      assert [_, %{uri: ^gem_uri}] = same_gem.content

      for {target_mod, target_cfg} <- [
            {Alloy.Provider.Anthropic, %{api_key: "k1"}},
            {Alloy.Provider.OpenAI, %{api_key: "k2"}},
            {Alloy.Provider.Gemini, %{api_key: "gem-k2"}}
          ] do
        [cross] = Message.normalize_for([attributed_gem_user], target_mod, target_cfg)

        assert cross.content == [
                 %{type: "text", text: "Read this"},
                 %{type: "text", text: "[Omitted provider-specific file attachment]"}
               ]
      end

      # Block-level foreign file_id on unattributed (origin: nil) and same-origin
      # assistant messages is also stripped, covering {mod, keyword} and {mod, map} origins.
      oai_origin = Message.origin(Alloy.Provider.OpenAI, %{api_key: "k2"})

      unattributed_asst =
        Message.assistant_blocks([
          Message.document_file("application/pdf", "file_a1",
            origin: {Alloy.Provider.Anthropic, [api_key: "k1"]}
          )
        ])

      conflicting_asst = %Message{
        role: :assistant,
        origin: oai_origin,
        content: [
          %{type: "text", text: "Kept"},
          Message.document_file("application/pdf", "file_a2",
            origin: {Alloy.Provider.Anthropic, %{api_key: "k1"}}
          )
        ]
      }

      assert [norm_conflicting] =
               Message.normalize_for(
                 [unattributed_asst, conflicting_asst],
                 Alloy.Provider.OpenAI,
                 %{api_key: "k2"}
               )

      assert norm_conflicting.content == [%{type: "text", text: "Kept"}]
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

  describe "normalize_for/3" do
    @anthropic Alloy.Provider.Anthropic
    @openai Alloy.Provider.OpenAI

    defp from(provider, blocks, config \\ %{}) do
      %{
        Message.assistant_blocks(blocks)
        | provider: provider,
          model: "m",
          origin: Message.origin(provider, config)
      }
    end

    test "leaves the same origin's, user-built and user messages alone" do
      own = from(@anthropic, [%{type: "thinking", thinking: "t", signature: "sig"}])

      hand_built =
        Message.assistant_blocks([%{type: "thinking", thinking: "t", signature: "sig"}])

      other_model = %{own | model: "another-claude"}

      messages = [Message.user("hi"), own, hand_built, other_model]
      assert Message.normalize_for(messages, @anthropic, %{}) == messages
    end

    # OpenAI ties encrypted reasoning to the organisation that issued it.
    test "another account or endpoint of the same provider is a different origin" do
      reasoning = %{type: "reasoning", raw: %{"type" => "reasoning", "encrypted_content" => "e"}}
      text = %{type: "text", text: "answer"}
      org_a = from(@openai, [reasoning, text], %{api_key: "key-a"})

      assert [%Message{content: [^reasoning, ^text]}] =
               Message.normalize_for([org_a], @openai, %{api_key: "key-a", model: "other"})

      for config <- [%{api_key: "key-b"}, %{api_key: "key-a", api_url: "https://proxy.example"}] do
        assert [%Message{content: [^text]}] = Message.normalize_for([org_a], @openai, config)
      end
    end

    test "the origin fingerprint never contains the key" do
      origin = Message.origin(@openai, %{api_key: "sk-secret-value"})
      assert byte_size(origin) == 16
      refute origin =~ "secret"
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
               Message.normalize_for([message], @openai, %{})

      assert content == [
               %{type: "text", text: "I should read the file"},
               %{type: "text", text: "Reading it."}
             ]
    end

    test "drops OpenAI raw items and a message left empty" do
      message = from(@openai, [%{type: "reasoning", raw: %{"type" => "reasoning"}}])

      assert Message.normalize_for([Message.user("hi"), message], @anthropic, %{}) == [
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
                 @anthropic,
                 %{}
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
      [%Message{content: rewritten}] = Message.normalize_for([message], @anthropic, %{})
      ids = Enum.map(rewritten, & &1.id)

      assert Enum.all?(ids, &Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, &1))
      assert ids == Enum.uniq(ids)
      assert [%Message{content: ^rewritten}] = Message.normalize_for([message], @anthropic, %{})
    end

    test "later same-origin reused call ID keeps its raw ID paired with its tool result" do
      provider = Alloy.Provider.OpenAICompat
      config = %{api_key: "target"}
      call = %{type: "tool_use", id: "functions.read:0", name: "read", input: %{}}

      foreign = %{
        Message.assistant_blocks([call])
        | origin: Message.origin(provider, %{api_key: "other"})
      }

      local = %{Message.assistant_blocks([call]) | origin: Message.origin(provider, config)}
      result = Message.tool_results([Message.tool_result_block(call.id, "ok")])

      [norm_foreign, norm_foreign_res, norm_local, norm_local_res] =
        Message.normalize_for([foreign, result, local, result], provider, config)

      assert hd(norm_foreign.content).id == hd(norm_foreign_res.content).tool_use_id
      assert hd(norm_foreign.content).id != call.id
      assert hd(norm_local.content).id == call.id
      assert hd(norm_local_res.content).tool_use_id == call.id
    end
  end
end
