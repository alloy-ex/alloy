defmodule Alloy.Provider.XAITest do
  use ExUnit.Case, async: true

  import Alloy.StreamTestHelpers

  alias Alloy.Provider.XAI
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
                    "content" => "Hello from Grok!"
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

      assert {:ok, result} = XAI.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello from Grok!"
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
                        "id" => "call_grok_123",
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

      assert {:ok, result} = XAI.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "call_grok_123"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "sends authorization header with api key" do
      config = config_that_captures_request()

      XAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_headers, headers}
      auth = Enum.find(headers, fn {k, _v} -> k == "authorization" end)
      assert {"authorization", "Bearer xai-test-key"} = auth
    end

    test "uses correct xAI API URL" do
      config = config_that_captures_request()

      XAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_url, url}
      assert url =~ "/v1/chat/completions"
    end

    test "includes system prompt as system message" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are Grok.")

      XAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      system_msg = hd(decoded["messages"])
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are Grok."
    end

    test "includes tool definitions in request" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "bash",
          description: "Run a command",
          input_schema: %{
            type: "object",
            properties: %{command: %{type: "string"}},
            required: ["command"]
          }
        }
      ]

      XAI.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "bash"
    end

    test "formats tool_result messages as role:tool" do
      config = config_that_captures_request()

      messages = [
        Message.user("Run ls"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "call_1", name: "bash", input: %{"command" => "ls"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("call_1", "file1.ex\nfile2.ex")
        ])
      ]

      XAI.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      tool_msg = Enum.find(decoded["messages"], &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "call_1"
      assert tool_msg["content"] == "file1.ex\nfile2.ex"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})
      assert {:error, _reason} = XAI.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 401,
          body:
            Jason.encode!(%{
              "error" => %{
                "type" => "auth_error",
                "message" => "Invalid API key"
              }
            })
        })

      assert {:error, reason} = XAI.complete([Message.user("Hi")], [], config)
      assert reason =~ "auth_error"
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

      assert {:ok, result} = XAI.stream([Message.user("Hi")], [], config, on_chunk)
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
          XAI.stream([Message.user("Read mix.exs")], [], config, on_chunk)
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

      XAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "xai-test-key",
      model: "grok-3",
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
      api_key: "xai-test-key",
      model: "grok-3",
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_url, "#{conn.scheme}://#{conn.host}#{conn.request_path}"})

        headers = Enum.map(conn.req_headers, fn {k, v} -> {k, v} end)
        send(test_pid, {:request_headers, headers})

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
    %{api_key: "xai-test-key", model: "grok-3", req_options: [plug: {Req.Test, __MODULE__}, retry: false]}
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_chunks_plug(chunks)) end)
  end

  defp config_with_sse_stream_capturing_request(chunks) do
    %{api_key: "xai-test-key", model: "grok-3", req_options: [plug: {Req.Test, __MODULE__}, retry: false]}
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_chunks_capturing_plug(self(), chunks)) end)
  end
end
