defmodule Alloy.Provider.OpenAITest do
  use ExUnit.Case, async: true

  import Alloy.StreamTestHelpers

  alias Alloy.Message
  alias Alloy.Provider.OpenAI

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload(
                [assistant_text_item("Hello!")],
                %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
              )
            )
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

  describe "complete/3 with tool calls response" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload(
                [
                  function_call_item(
                    "call_abc123",
                    "read",
                    Jason.encode!(%{"file_path" => "mix.exs"})
                  )
                ],
                %{"input_tokens" => 20, "output_tokens" => 15, "total_tokens" => 35}
              )
            )
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

    test "handles text + tool calls in same response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload(
                [
                  assistant_text_item("Let me read that file."),
                  function_call_item(
                    "call_def456",
                    "read",
                    Jason.encode!(%{"file_path" => "mix.exs"})
                  )
                ],
                %{"input_tokens" => 20, "output_tokens" => 15, "total_tokens" => 35}
              )
            )
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

  describe "complete/3 request formatting" do
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

      user_msgs = Enum.filter(decoded["input"], &(&1["role"] == "user"))
      assert length(user_msgs) == 2
    end

    test "includes system prompt as system input item" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      system_msg = hd(decoded["input"])
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
    end

    test "includes tool definitions in Responses format" do
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
      assert tool["name"] == "read"
      assert tool["description"] == "Read a file"
      assert tool["parameters"]["type"] == "object"
    end

    test "formats tool flow as function_call + function_call_output input items" do
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

      function_call = Enum.find(decoded["input"], &(&1["type"] == "function_call"))
      assert function_call["call_id"] == "call_abc"
      assert function_call["name"] == "read"

      function_output = Enum.find(decoded["input"], &(&1["type"] == "function_call_output"))
      assert function_output["call_id"] == "call_abc"
      assert function_output["output"] == "file contents here"
    end
  end

  describe "complete/3 multimodal formatting" do
    test "image block in user message formats to input_image data URL" do
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

      user_msg = Enum.find(decoded["input"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])

      img_block = Enum.find(user_msg["content"], &(&1["type"] == "input_image"))
      assert img_block != nil
      assert img_block["image_url"] == "data:image/jpeg;base64,base64img=="
    end

    test "audio block falls back to input_text notice" do
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

      user_msg = Enum.find(decoded["input"], &(&1["role"] == "user"))
      [audio_block] = user_msg["content"]
      assert audio_block["type"] == "input_text"
      assert String.contains?(audio_block["text"], "Unsupported")
    end

    test "video block in user message formats to input_text notice instead of being dropped" do
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

      user_msg = Enum.find(decoded["input"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert block["type"] == "input_text"
      assert String.contains?(block["text"], "Unsupported")
    end

    test "document block in user message formats to input_text notice instead of being dropped" do
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

      user_msg = Enum.find(decoded["input"], &(&1["role"] == "user"))
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert block["type"] == "input_text"
      assert String.contains?(block["text"], "Unsupported")
    end
  end

  describe "complete/3 with malformed tool call arguments" do
    test "returns error instead of crashing on invalid JSON arguments" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload([
                function_call_item("call_bad", "read", "{invalid json")
              ])
            )
        })

      assert {:error, reason} = OpenAI.complete([Message.user("Hi")], [], config)
      assert reason =~ "Invalid JSON"
    end
  end

  describe "complete/3 with missing usage field" do
    test "returns zero counts when usage is absent from response" do
      config =
        config_with_response(%{
          status: 200,
          body: Jason.encode!(response_payload([assistant_text_item("Hello!")]))
        })

      assert {:ok, result} = OpenAI.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert result.usage.input_tokens == 0
      assert result.usage.output_tokens == 0
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
          sse_response_output_text_delta("Hello"),
          sse_response_output_text_delta(" world"),
          sse_response_completed(
            [assistant_text_item("Hello world")],
            %{"input_tokens" => 10, "output_tokens" => 5}
          ),
          "data: [DONE]\n\n"
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "accumulates tool calls without emitting chunks" do
      config =
        config_with_sse_stream([
          sse_response_completed([
            function_call_item("call_1", "read", Jason.encode!(%{"file_path" => "mix.exs"}))
          ]),
          "data: [DONE]\n\n"
        ])

      chunks =
        collect_chunks(fn on_chunk ->
          OpenAI.stream([Message.user("Read mix.exs")], [], config, on_chunk)
        end)

      assert chunks == []
    end

    test "returns parsed error when stream response is non-200" do
      error_body =
        Jason.encode!(%{
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "Unsupported parameter: 'max_output_tokens'"
          }
        })

      config = config_with_sse_error_stream(400, error_body)

      assert {:error, reason} =
               OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert reason =~ "invalid_request_error"
      assert reason =~ "max_output_tokens"
    end

    test "returns raw body when stream error response is not JSON" do
      config = config_with_sse_error_stream(503, "Service Unavailable")

      assert {:error, reason} =
               OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert reason =~ "503"
      assert reason =~ "Service Unavailable"
    end

    test "request body includes stream: true" do
      config =
        config_with_sse_stream_capturing_request([
          sse_response_output_text_delta("ok"),
          sse_response_completed([assistant_text_item("ok")]),
          "data: [DONE]\n\n"
        ])

      OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
      assert is_list(decoded["input"])
    end
  end

  # --- Test Helpers ---

  defp response_payload(output, usage \\ %{}) do
    base = %{
      "id" => "resp_test",
      "object" => "response",
      "status" => "completed",
      "output" => output
    }

    if usage == %{}, do: base, else: Map.put(base, "usage", usage)
  end

  defp assistant_text_item(text) do
    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  defp function_call_item(call_id, name, arguments) do
    %{
      "id" => "fc_test",
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => arguments
    }
  end

  defp sse_response_output_text_delta(text) do
    sse_response_event("response.output_text.delta", %{
      "type" => "response.output_text.delta",
      "delta" => text
    })
  end

  defp sse_response_completed(output_items, usage \\ %{}) do
    sse_response_event("response.completed", %{
      "type" => "response.completed",
      "response" => response_payload(output_items, usage)
    })
  end

  defp sse_response_event(event, payload) do
    "event: #{event}\ndata: #{Jason.encode!(payload)}\n\n"
  end

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
          Jason.encode!(
            response_payload([assistant_text_item("ok")], %{
              "input_tokens" => 1,
              "output_tokens" => 1
            })
          )
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
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_chunks_plug(chunks)) end)
  end

  defp config_with_sse_error_stream(status, body) do
    %{
      api_key: "sk-test-key",
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_error_plug(status, body)) end)
  end

  defp config_with_sse_stream_capturing_request(chunks) do
    %{
      api_key: "sk-test-key",
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_chunks_capturing_plug(self(), chunks)) end)
  end
end
