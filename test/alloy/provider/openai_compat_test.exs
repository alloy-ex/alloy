defmodule Alloy.Provider.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.OpenAICompat

  # ── Helpers ──────────────────────────────────────────────────────────

  defp config_with_response(response) do
    %{
      api_url: "http://localhost",
      model: "test-model",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
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
      api_url: "http://localhost",
      model: "test-model",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "chatcmpl-test",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
          })
        )
      end)
    end)
  end

  describe "request formatting" do
    test "includes strict true inside function tool definitions" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "search",
          description: "Search",
          strict: true,
          input_schema: %{
            type: "object",
            properties: %{query: %{type: "string"}},
            required: ["query"],
            additionalProperties: false
          }
        }
      ]

      OpenAICompat.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [%{"type" => "function", "function" => function}] = decoded["tools"]
      assert function["strict"] == true
    end
  end

  # ── Gemini 3.x thought signatures (PR #24) ───────────────────────────

  describe "Gemini 3.x thought signatures" do
    test "thought_signature in a tool call response is preserved on the block" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-test",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => nil,
                    "tool_calls" => [
                      %{
                        "id" => "call_1",
                        "type" => "function",
                        "function" => %{"name" => "read", "arguments" => "{}"},
                        "extra_content" => %{
                          "google" => %{"thought_signature" => "sig-abc"}
                        }
                      }
                    ]
                  },
                  "finish_reason" => "tool_calls"
                }
              ],
              "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
            })
        })

      {:ok, response} = OpenAICompat.complete([Message.user("Hi")], [], config)

      [%Message{content: blocks}] = response.messages
      tool_block = Enum.find(blocks, &(&1[:type] == "tool_use"))
      assert tool_block.thought_signature == "sig-abc"
    end

    test "thought_signature on an assistant tool_use block is echoed back in the request" do
      config = config_that_captures_request()

      assistant_msg = %Message{
        role: :assistant,
        content: [
          %{
            type: "tool_use",
            id: "call_1",
            name: "read",
            input: %{},
            thought_signature: "sig-abc"
          }
        ]
      }

      tool_result_msg = %Message{
        role: :user,
        content: [%{type: "tool_result", tool_use_id: "call_1", content: "done"}]
      }

      OpenAICompat.complete([Message.user("Hi"), assistant_msg, tool_result_msg], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assistant = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
      [tc] = assistant["tool_calls"]
      assert tc["extra_content"] == %{"google" => %{"thought_signature" => "sig-abc"}}
    end

    test "tool calls without thought signatures are unchanged (no-op path)" do
      config = config_that_captures_request()

      assistant_msg = %Message{
        role: :assistant,
        content: [%{type: "tool_use", id: "call_1", name: "read", input: %{}}]
      }

      tool_result_msg = %Message{
        role: :user,
        content: [%{type: "tool_result", tool_use_id: "call_1", content: "done"}]
      }

      OpenAICompat.complete([Message.user("Hi"), assistant_msg, tool_result_msg], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assistant = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
      [tc] = assistant["tool_calls"]
      refute Map.has_key?(tc, "extra_content")
    end

    test "list-shaped error bodies do not crash parse_error" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!([
              %{"error" => %{"message" => "missing thought_signature", "type" => "invalid"}}
            ])
        })

      assert {:error, message} = OpenAICompat.complete([Message.user("Hi")], [], config)
      assert message =~ "missing thought_signature"
    end
  end

  # ── Step 2: Reasoning Block Parsing ──────────────────────────────────

  describe "complete/3 reasoning_content parsing" do
    test "response with reasoning_content produces thinking block" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-reason",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => "The answer is 42.",
                    "reasoning_content" => "Let me think step by step..."
                  },
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}
            })
        })

      assert {:ok, result} = OpenAICompat.complete([Message.user("Hard question")], [], config)

      [%Message{role: :assistant, content: blocks}] = result.messages

      # Should have a thinking block BEFORE the text block
      thinking = Enum.find(blocks, &(&1.type == "thinking"))
      assert thinking != nil
      assert thinking.thinking == "Let me think step by step..."

      text = Enum.find(blocks, &(&1.type == "text"))
      assert text != nil
      assert text.text == "The answer is 42."
    end

    test "response without reasoning_content has no thinking block" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-plain",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{"role" => "assistant", "content" => "Hello"},
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3}
            })
        })

      assert {:ok, result} = OpenAICompat.complete([Message.user("Hi")], [], config)

      [%Message{role: :assistant, content: blocks}] = result.messages
      refute Enum.any?(blocks, &(&1.type == "thinking"))
    end

    test "empty reasoning_content is ignored" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "chatcmpl-empty-reason",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => "Hello",
                    "reasoning_content" => ""
                  },
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3}
            })
        })

      assert {:ok, result} = OpenAICompat.complete([Message.user("Hi")], [], config)

      [%Message{role: :assistant, content: blocks}] = result.messages
      refute Enum.any?(blocks, &(&1.type == "thinking"))
    end
  end

  # ── Step 3: extra_body merge ─────────────────────────────────────────

  describe "extra_body in request" do
    test "extra_body params appear in request body" do
      config =
        config_that_captures_request()
        |> Map.put(:extra_body, %{
          "response_format" => %{"type" => "json_object"},
          "temperature" => 0.7
        })

      OpenAICompat.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["response_format"] == %{"type" => "json_object"}
      assert decoded["temperature"] == 0.7
    end

    test "extra_body can override default fields" do
      config =
        config_that_captures_request()
        |> Map.put(:extra_body, %{"max_tokens" => 8192})

      OpenAICompat.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # extra_body merges LAST, so it should override the default
      assert decoded["max_tokens"] == 8192
    end

    test "no extra_body means no extra fields" do
      config = config_that_captures_request()

      OpenAICompat.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "response_format")
      refute Map.has_key?(decoded, "temperature")
    end
  end
end
