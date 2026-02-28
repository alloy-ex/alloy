defmodule Alloy.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.OpenAI
  alias Alloy.Message

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-01",
              "object" => "chat.completion",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => "Hello!"
                  },
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{
                "prompt_tokens" => 10,
                "completion_tokens" => 5,
                "total_tokens" => 15
              }
            })
        })

      messages = [Message.user("Hi")]

      assert {:ok, result} = OpenAI.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with tool_calls response" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-02",
              "object" => "chat.completion",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => nil,
                    "tool_calls" => [
                      %{
                        "id" => "call_abc123",
                        "type" => "function",
                        "function" => %{
                          "name" => "read",
                          "arguments" => Jason.encode!(%{"file_path" => "mix.exs"})
                        }
                      }
                    ]
                  },
                  "finish_reason" => "tool_calls"
                }
              ],
              "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 15, "total_tokens" => 35}
            })
        })

      messages = [Message.user("Read mix.exs")]
      tool_defs = [%{name: "read", description: "Read a file", input_schema: %{}}]

      assert {:ok, result} = OpenAI.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "call_abc123"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end

    test "handles text + tool_calls in same response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-03",
              "object" => "chat.completion",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => "Let me read that file.",
                    "tool_calls" => [
                      %{
                        "id" => "call_def456",
                        "type" => "function",
                        "function" => %{
                          "name" => "read",
                          "arguments" => Jason.encode!(%{"file_path" => "mix.exs"})
                        }
                      }
                    ]
                  },
                  "finish_reason" => "tool_calls"
                }
              ],
              "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 15, "total_tokens" => 35}
            })
        })

      assert {:ok, result} = OpenAI.complete([Message.user("Read")], [], config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      text_block = Enum.find(blocks, &(&1.type == "text"))
      assert text_block.text == "Let me read that file."

      tool_block = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_block.name == "read"
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

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # OpenAI uses system prompt as first message, then user/assistant
      user_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "user"))
      assert length(user_msgs) == 2
    end

    test "includes system prompt as system message" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      system_msg = hd(decoded["messages"])
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
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

      OpenAI.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read"
      assert tool["function"]["description"] == "Read a file"
      assert tool["function"]["parameters"]["type"] == "object"
    end

    test "formats tool_result messages as role:tool" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read mix.exs"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "call_abc", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("call_abc", "file contents here")
        ])
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # The assistant message should have tool_calls
      assistant_msg = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
      assert assistant_msg["tool_calls"] != nil

      # The tool_result should become a role: "tool" message
      tool_msg = Enum.find(decoded["messages"], &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "call_abc"
      assert tool_msg["content"] == "file contents here"
    end
  end

  describe "complete/3 multimodal formatting" do
    test "image block in user message formats to image_url data URL" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [
            %{type: "text", text: "What is in this image?"},
            Message.image("image/jpeg", "base64img==")
          ]
        }
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])

      img_block = Enum.find(user_msg["content"], &(&1["type"] == "image_url"))
      assert img_block != nil
      assert img_block["image_url"]["url"] == "data:image/jpeg;base64,base64img=="
    end

    test "audio block in user message formats to input_audio" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.audio("audio/mp3", "base64audio==")]
        }
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])

      [audio_block] = user_msg["content"]
      assert audio_block["type"] == "input_audio"
      assert audio_block["input_audio"]["data"] == "base64audio=="
      assert audio_block["input_audio"]["format"] == "mp3"
    end

    test "wav audio mime maps to wav format string" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.audio("audio/wav", "wavdata==")]
        }
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      [audio_block] = user_msg["content"]
      assert audio_block["input_audio"]["format"] == "wav"
    end

    test "video block in user message formats to text notice instead of being dropped" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.video("video/mp4", "base64video==")]
        }
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      # Must NOT be nil/empty — the block should appear as a text notice
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert block["type"] == "text"
      assert String.contains?(block["text"], "Unsupported")
    end

    test "document block in user message formats to text notice instead of being dropped" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.document("application/pdf", "gs://bucket/file.pdf")]
        }
      ]

      OpenAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert block["type"] == "text"
      assert String.contains?(block["text"], "Unsupported")
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = OpenAI.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "error" => %{
                "type" => "invalid_request_error",
                "message" => "Invalid model specified"
              }
            })
        })

      assert {:error, reason} = OpenAI.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end

    test "returns error on rate limit" do
      config =
        config_with_response(%{
          status: 429,
          body:
            Jason.encode!(%{
              "error" => %{
                "type" => "rate_limit_error",
                "message" => "Rate limit exceeded"
              }
            })
        })

      assert {:error, reason} = OpenAI.complete([Message.user("Hi")], [], config)
      assert reason =~ "rate_limit"
    end
  end

  # ── stream/4 ──────────────────────────────────────────────────────────

  describe "stream/4" do
    test "emits text chunks and returns correct response" do
      config =
        config_with_sse_stream([
          sse_text_delta("Hello"),
          sse_text_delta(" world"),
          sse_finish("stop"),
          sse_usage(10, 5),
          "data: [DONE]\n\n"
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello world"

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "accumulates tool calls without emitting chunks" do
      config =
        config_with_sse_stream([
          sse_tool_call_start(0, "call_1", "read"),
          sse_tool_call_args(0, "{\"file_path\":\"mix.exs\"}"),
          sse_finish("tool_calls"),
          "data: [DONE]\n\n"
        ])

      chunks =
        collect_chunks(fn on_chunk ->
          OpenAI.stream([Message.user("Read mix.exs")], [], config, on_chunk)
        end)

      assert chunks == []
    end

    test "request body includes stream: true" do
      config =
        config_with_sse_stream_capturing_request([
          sse_text_delta("ok"),
          sse_finish("stop"),
          "data: [DONE]\n\n"
        ])

      OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "sk-test-key",
      model: "gpt-5.2",
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

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-test-key",
      model: "gpt-5.2",
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
            "id" => "chatcmpl-capture",
            "object" => "chat.completion",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          })
        )
      end)
    end)
  end

  # --- SSE Streaming Helpers ---

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-test-key",
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
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
      api_key: "sk-test-key",
      model: "gpt-5.2",
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

        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp sse_text_delta(text) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]})}\n\n"
  end

  defp sse_tool_call_start(index, id, name) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => index, "id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => ""}}]}, "finish_reason" => nil}]})}\n\n"
  end

  defp sse_tool_call_args(index, args) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => args}}]}, "finish_reason" => nil}]})}\n\n"
  end

  defp sse_finish(reason) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
  end

  defp sse_usage(prompt, completion) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [], "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => completion}})}\n\n"
  end

  defp collect_chunks(fun) do
    test_pid = self()
    on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

    fun.(on_chunk)

    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      {:chunk, chunk} -> collect_messages(acc ++ [chunk])
    after
      100 -> acc
    end
  end
end
