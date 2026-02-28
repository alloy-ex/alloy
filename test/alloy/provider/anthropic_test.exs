defmodule Alloy.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Anthropic
  alias Alloy.Message

  # We test by intercepting the HTTP call via a custom Req adapter
  # that returns canned responses.

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            })
        })

      messages = [Message.user("Hi")]

      assert {:ok, result} = Anthropic.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with tool_use response" do
    test "returns normalized tool_use response with tool calls" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_02",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read that file."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      messages = [Message.user("Read mix.exs")]
      tool_defs = [%{name: "read", description: "Read a file", input_schema: %{}}]

      assert {:ok, result} = Anthropic.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages
      assert length(blocks) == 2

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      # This will "fail" because our mock returns the request body, not a real response
      # But we can verify the request format
      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert length(decoded["messages"]) == 3
      assert hd(decoded["messages"])["role"] == "user"
      assert hd(decoded["messages"])["content"] == "Hello"
    end

    test "includes system prompt in request" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["system"] == "You are helpful."
    end

    test "includes tool definitions in request" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{
            type: "object",
            properties: %{file_path: %{type: "string"}},
            required: ["file_path"]
          }
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["name"] == "read"
      assert tool["description"] == "Read a file"
      assert tool["input_schema"]["type"] == "object"
    end

    test "formats tool_result messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read mix.exs"),
        Message.assistant_blocks([
          %{type: "text", text: "Reading..."},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("toolu_01", "file contents here")
        ])
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # tool_results become a user message with content blocks
      tool_result_msg = List.last(decoded["messages"])
      assert tool_result_msg["role"] == "user"
      assert is_list(tool_result_msg["content"])
      assert hd(tool_result_msg["content"])["type"] == "tool_result"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "type" => "invalid_request_error",
                "message" => "messages: at least one message is required"
              }
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end

    test "returns error on overloaded response" do
      config =
        config_with_response(%{
          status: 529,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "overloaded"
    end
  end

  describe "complete/3 with cache control" do
    test "includes cache usage in response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_03",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Cached!"}],
              "stop_reason" => "end_turn",
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 5,
                "cache_creation_input_tokens" => 100,
                "cache_read_input_tokens" => 50
              }
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.usage.cache_creation_input_tokens == 100
      assert result.usage.cache_read_input_tokens == 50
    end
  end

  describe "complete/3 multimodal formatting" do
    test "image block formats to Anthropic base64 source format" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [
            %{type: "text", text: "What is in this image?"},
            Message.image("image/jpeg", "base64data==")
          ]
        }
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = hd(decoded["messages"])
      assert user_msg["role"] == "user"

      image_block = Enum.find(user_msg["content"], &(&1["type"] == "image"))
      assert image_block != nil
      assert image_block["source"]["type"] == "base64"
      assert image_block["source"]["media_type"] == "image/jpeg"
      assert image_block["source"]["data"] == "base64data=="
    end

    test "audio block formats gracefully (text fallback) since Anthropic does not support it" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.audio("audio/mp3", "audiodata")]
        }
      ]

      # Should not raise — graceful handling
      result = Anthropic.complete(messages, [], config)
      assert match?({:ok, _}, result)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      user_msg = hd(decoded["messages"])

      # The audio block should have been converted to some sendable form
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert is_map(block)
    end
  end

  # ── stream/4 ──────────────────────────────────────────────────────────

  describe "stream/4" do
    test "emits text chunks and returns correct response" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " world"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
      refute_received {:chunk, _}
    end

    test "accumulates tool call input_json_delta without emitting chunks" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 20, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_01",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"file_path\""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ": \"mix.exs\"}"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 15}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, on_chunk)

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}

      # No text chunks emitted for tool calls
      refute_received {:chunk, _}
    end

    test "request body includes stream: true" do
      config =
        config_with_sse_stream_capturing_request([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "ok"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 1}
          }),
          ant_event("message_stop", %{})
        ])

      Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
    end

    test "handles mixed text and tool use in same stream" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 15, "output_tokens" => 0}}
          }),
          # Text block at index 0
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Let me read that."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          # Tool use block at index 1
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_02",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => "{\"file_path\": \"mix.exs\"}"
            }
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 20}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, on_chunk)

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      assert Enum.find(blocks, &(&1.type == "text"))
      assert Enum.find(blocks, &(&1.type == "tool_use"))

      assert_received {:chunk, "Let me read that."}
    end
  end

  # ── Extended Thinking ────────────────────────────────────────────────

  describe "complete/3 with thinking blocks" do
    test "returns thinking block in message content for round-trip" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_think_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "thinking",
                  "thinking" => "Let me reason through this...",
                  "signature" => "sig_abc123"
                },
                %{"type" => "text", "text" => "The answer is 42."}
              ],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hard question")], [], config)

      # text/1 returns only the text content
      assert Message.text(hd(result.messages)) == "The answer is 42."

      # thinking block is preserved in content for round-trip
      [thinking_block, _text_block] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "Let me reason through this..."
      assert thinking_block.signature == "sig_abc123"
    end

    test "includes thinking in request body when extended_thinking opt set" do
      config =
        config_that_captures_request()
        |> Map.put(:extended_thinking, budget_tokens: 5_000)

      Anthropic.complete([Message.user("Think hard")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert %{"type" => "enabled", "budget_tokens" => 5_000} = decoded["thinking"]
    end

    test "raises ArgumentError when extended_thinking is set without budget_tokens" do
      config =
        config_that_captures_request()
        |> Map.put(:extended_thinking, [])

      assert_raise ArgumentError, ~r/budget_tokens/, fn ->
        Anthropic.complete([Message.user("Think hard")], [], config)
      end
    end

    test "no thinking key in request body when extended_thinking not set" do
      config = config_that_captures_request()

      Anthropic.complete([Message.user("Simple question")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "thinking")
    end

    test "thinking block round-trips correctly through format_content_block" do
      # A message with a thinking block should be serialisable back to Anthropic's
      # wire format so subsequent turns include the thinking block verbatim.
      config = config_that_captures_request()

      thinking_block = %{type: "thinking", thinking: "My reasoning...", signature: "sig_xyz"}
      text_block = %{type: "text", text: "My answer."}

      messages = [
        Message.user("Question"),
        %Message{role: :assistant, content: [thinking_block, text_block]}
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assistant_msg = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
      thinking_wire = Enum.find(assistant_msg["content"], &(&1["type"] == "thinking"))

      assert thinking_wire["thinking"] == "My reasoning..."
      assert thinking_wire["signature"] == "sig_xyz"
    end
  end

  describe "stream/4 with thinking blocks" do
    test "emits thinking deltas via on_event, not on_chunk" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          # Thinking block at index 0
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => " Step 2."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          # Text block at index 1
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Answer."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 20}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      on_event = fn event -> send(test_pid, {:event, event}) end
      config = Map.put(config, :on_event, on_event)

      assert {:ok, result} = Anthropic.stream([Message.user("Think")], [], config, on_chunk)

      # on_chunk receives only text deltas
      assert_received {:chunk, "Answer."}
      refute_received {:chunk, _}

      # on_event receives thinking deltas from the provider.
      # :text_delta is emitted by Turn.wrapped_chunk, not by the provider directly.
      assert_received {:event, {:thinking_delta, "Let me think..."}}
      assert_received {:event, {:thinking_delta, " Step 2."}}
      refute_received {:event, {:text_delta, _}}

      # Result text is text-only
      assert Message.text(hd(result.messages)) == "Answer."

      # Thinking block is in content for round-trip
      [thinking_block | _] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "Let me think... Step 2."
    end

    test "provider does not emit :text_delta directly (Turn.wrapped_chunk handles it)" do
      # :text_delta is emitted by Turn.wrapped_chunk for all providers universally.
      # The Anthropic provider itself only emits :thinking_delta via on_event.
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 3}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end
      config = Map.put(config, :on_event, on_event)

      Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      # Provider does NOT emit :text_delta — Turn.wrapped_chunk does
      refute_received {:event, {:text_delta, _}}
    end

    test "signature_delta is captured in streamed thinking block" do
      # Anthropic streams thinking in three delta phases:
      # thinking_delta (text), signature_delta (signature), then content_block_stop.
      # The signature must survive into the parsed thinking block for round-trip.
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "My reasoning."}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_streamed123"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Done."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Think")], [], config, fn _ -> :ok end)

      [thinking_block | _] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "My reasoning."
      assert thinking_block.signature == "sig_streamed123"
    end

    test "works normally when on_event is not set" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "thinking..."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Done."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 10}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      # No on_event in config — should work fine, no crash
      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert Message.text(hd(result.messages)) == "Done."
      assert_received {:chunk, "Done."}
    end
  end

  describe "complete/3 retry behavior" do
    test "returns error on 429 (retry is handled by Turn, not the provider)" do
      # Req retry is disabled — providers return errors immediately for Turn to retry.
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, "Too Many Requests")
      end)

      config = %{
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-6-20250514",
        max_tokens: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      }

      assert {:error, "HTTP 429: Too Many Requests"} =
               Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "req_options cannot re-enable Req retry (retry: false is enforced)" do
      # A caller might pass retry: :transient in req_options. This must NOT
      # re-enable Req's built-in retry, because Turn handles all retry logic.
      calls = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.send_resp(conn, 429, "Too Many Requests")
      end)

      config = %{
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-6-20250514",
        max_tokens: 4096,
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry: :transient,
          retry_delay: 1
        ]
      }

      assert {:error, "HTTP 429: Too Many Requests"} =
               Anthropic.complete([Message.user("Hi")], [], config)

      # Must have been called exactly once — no Req retry
      assert :counters.get(calls, 1) == 1,
             "Expected 1 call but got #{:counters.get(calls, 1)} — Req retry was not disabled"
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6-20250514",
      max_tokens: 4096,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  # --- SSE Streaming Helpers ---

  # Build an Anthropic-format SSE event string: "event: <type>\ndata: <json>\n\n"
  defp ant_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6-20250514",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp config_with_sse_stream_capturing_request(chunks) do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6-20250514",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6-20250514",
      max_tokens: 4096,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "msg_capture",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)
    end)
  end
end
