defmodule Alloy.Provider.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Error
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
    test "sends max_tokens only when :max_tokens is set" do
      config = Map.delete(config_that_captures_request(), :max_tokens)
      OpenAICompat.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      refute Map.has_key?(Jason.decode!(body), "max_tokens")

      OpenAICompat.complete([Message.user("Hi")], [], Map.put(config, :max_tokens, 2048))
      assert_received {:request_body, body}
      assert Jason.decode!(body)["max_tokens"] == 2048
    end

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

  describe "stream options" do
    test "provider config can omit stream_options for endpoints that reject it" do
      config = Map.put(config_that_captures_stream(), :stream_options, false)
      assert {:ok, _} = OpenAICompat.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
      refute Map.has_key?(decoded, "stream_options")
    end

    test "extra_body false omits stream_options instead of sending a boolean" do
      config = Map.put(config_that_captures_stream(), :extra_body, %{"stream_options" => false})
      assert {:ok, _} = OpenAICompat.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert_received {:request_body, body}
      refute Map.has_key?(Jason.decode!(body), "stream_options")
    end

    test "preserves caller-provided stream options" do
      options = %{"include_usage" => false, "custom_flag" => true}
      config = Map.put(config_that_captures_stream(), :extra_body, %{"stream_options" => options})
      assert {:ok, _} = OpenAICompat.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert_received {:request_body, body}
      assert Jason.decode!(body)["stream_options"] == options
    end

    test "a streaming opt-out does not add fields to non-streaming requests" do
      config = Map.put(config_that_captures_request(), :stream_options, false)
      assert {:ok, _} = OpenAICompat.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      refute Map.has_key?(Jason.decode!(body), "stream_options")
    end
  end

  defp config_that_captures_stream do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, body})
      event = %{"choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]}
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(event)}\n\ndata: [DONE]\n\n")
      conn
    end)

    %{
      api_url: "http://localhost",
      model: "test-model",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  # ── Gemini 3.x thought signatures (PR #24) ───────────────────────────

  describe "Gemini 3.x thought signatures" do
    test "streamed parallel tool signatures survive later deltas and round-trip unchanged" do
      signatures = ["opaque+/= signature", "late-signature"]

      calls = [
        %{
          "index" => 0,
          "id" => "call_1",
          "function" => %{"name" => "read", "arguments" => ""},
          "extra_content" => %{"google" => %{"thought_signature" => hd(signatures)}}
        },
        %{
          "index" => 1,
          "id" => "call_2",
          "function" => %{"name" => "write", "arguments" => ""}
        },
        %{
          "index" => 0,
          "function" => %{"arguments" => "{}"},
          "extra_content" => %{"google" => %{"thought_signature" => nil}}
        },
        %{
          "index" => 1,
          "function" => %{"arguments" => "{}"},
          "extra_content" => %{"google" => %{"thought_signature" => List.last(signatures)}}
        }
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        conn =
          Enum.reduce(calls, conn, fn call, conn ->
            chunk = %{"choices" => [%{"delta" => %{"tool_calls" => [call]}}]}
            {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(chunk)}\n\n")
            conn
          end)

        finish = %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(finish)}\n\ndata: [DONE]\n\n")
        conn
      end)

      config = %{
        api_url: "http://localhost",
        model: "gemini-3.8-flash",
        req_options: [plug: {Req.Test, __MODULE__}]
      }

      assert {:ok, response} =
               OpenAICompat.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert response.stop_reason == :tool_use
      [assistant] = response.messages
      assert Enum.map(assistant.content, & &1[:thought_signature]) == signatures
      assert Enum.map(assistant.content, & &1.id) == ["call_1", "call_2"]

      results = %Message{
        role: :user,
        content: [
          %{type: "tool_result", tool_use_id: "call_1", content: "read done"},
          %{type: "tool_result", tool_use_id: "call_2", content: "write done"}
        ]
      }

      assert {:ok, _} =
               OpenAICompat.complete(
                 [Message.user("Hi"), assistant, results],
                 [],
                 config_that_captures_request()
               )

      assert_received {:request_body, body}
      outgoing = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))

      assert Enum.map(
               outgoing["tool_calls"],
               &get_in(&1, ["extra_content", "google", "thought_signature"])
             ) ==
               signatures
    end

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

      assert {:error, %Error{kind: :invalid_request} = error} =
               OpenAICompat.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) =~ "missing thought_signature"
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

    test "reasoning_content is echoed back on the assistant message of a tool loop" do
      # DeepSeek thinking mode rejects the next request (HTTP 400) when the
      # reasoning_content of a tool-calling turn is missing.
      response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "reasoning_content" => "I should read the file.",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      config = config_with_response(%{status: 200, body: Jason.encode!(response)})

      assert {:ok, %{messages: [assistant]}} =
               OpenAICompat.complete([Message.user("Hi")], [], config)

      results = Message.tool_results([Message.tool_result_block("call_1", "contents")])

      OpenAICompat.complete(
        [Message.user("Hi"), assistant, results],
        [],
        config_that_captures_request()
      )

      assert_received {:request_body, body}
      outgoing = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))

      assert outgoing["reasoning_content"] == "I should read the file."
      assert [%{"id" => "call_1"}] = outgoing["tool_calls"]
    end

    test "assistant messages without thinking carry no reasoning_content" do
      assistant = Message.assistant_blocks([%{type: "text", text: "Hello"}])
      OpenAICompat.complete([Message.user("Hi"), assistant], [], config_that_captures_request())

      assert_received {:request_body, body}
      outgoing = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(outgoing, "reasoning_content")
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

  describe "complete/3 finish reasons" do
    test "map onto Alloy stop reasons the same way streaming does" do
      for {finish_reason, stop_reason} <- [
            {"stop", :end_turn},
            {"length", :max_tokens},
            {"content_filter", :refusal},
            {"tool_calls", :tool_use},
            {"function_call", :tool_use}
          ] do
        body = %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "x"},
              "finish_reason" => finish_reason
            }
          ]
        }

        config = config_with_response(%{status: 200, body: Jason.encode!(body)})

        assert {:ok, %{stop_reason: ^stop_reason}} =
                 OpenAICompat.complete([Message.user("Hi")], [], config)
      end
    end
  end

  describe "complete/3 failures inside a 200 response" do
    test "an error body is an error classified by its code" do
      body = %{"error" => %{"code" => "rate_limit_exceeded", "message" => "Slow down"}}
      config = config_with_response(%{status: 200, body: Jason.encode!(body)})

      assert {:error, %Error{kind: :rate_limited, message: "Slow down"}} =
               OpenAICompat.complete([Message.user("Hi")], [], config)
    end

    test "a body without choices is an error, not a crash" do
      config = config_with_response(%{status: 200, body: Jason.encode!(%{"choices" => []})})

      assert {:error, %Error{} = error} = OpenAICompat.complete([Message.user("Hi")], [], config)
      assert Exception.message(error) =~ "Unexpected"
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

    test "atom keys in extra_body override defaults instead of duplicating them" do
      config =
        config_that_captures_request()
        |> Map.put(:extra_body, %{max_tokens: 100, temperature: 0.2})

      OpenAICompat.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      assert length(String.split(body, ~s("max_tokens"))) == 2
      assert %{"max_tokens" => 100, "temperature" => 0.2} = Jason.decode!(body)
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
