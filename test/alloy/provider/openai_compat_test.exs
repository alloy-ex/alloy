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

    test "non-streaming accepts empty-string tool arguments, trims trailing api_url slash, and classifies malformed JSON" do
      Req.Test.stub(:openai_compat_empty_args, fn conn ->
        assert conn.request_path == "/v1/chat/completions"

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "tool_calls",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "ping", "arguments" => ""}
                  }
                ]
              }
            }
          ],
          "usage" => %{}
        })
      end)

      config = %{
        api_url: "http://localhost/",
        model: "m",
        req_options: [plug: {Req.Test, :openai_compat_empty_args}]
      }

      assert {:ok,
              %{messages: [%Message{content: [%{type: "tool_use", name: "ping", input: %{}}]}]}} =
               OpenAICompat.complete([Message.user("hi")], [], config)

      Req.Test.stub(:openai_compat_bad_args, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "tool_calls",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "ping", "arguments" => "{bad"}
                  }
                ]
              }
            }
          ]
        })
      end)

      assert {:error, %Alloy.Provider.Error{kind: :malformed_reply}} =
               OpenAICompat.complete([Message.user("hi")], [], %{
                 config
                 | req_options: [plug: {Req.Test, :openai_compat_bad_args}]
               })
    end

    test "rejects null, false, and non-object tool arguments and never executes tools under required or schema validation" do
      test_pid = self()

      tool =
        Alloy.Tool.inline(
          name: "delete_item",
          description: "Deletes an optional target",
          input_schema: %{type: "object", properties: %{target: %{type: "string"}}},
          execute: fn input, _ctx ->
            send(test_pid, {:tool_executed, input})
            {:ok, "deleted"}
          end
        )

      modes =
        if Code.ensure_loaded?(ExJsonSchema.Schema), do: [:required, :schema], else: [:required]

      for validation <- modes,
          {stub_name, raw_args} <- [
            {:openai_compat_nil_args, nil},
            {:openai_compat_null_json_args, "null"},
            {:openai_compat_false_json_args, "false"},
            {:openai_compat_array_json_args, "[]"}
          ] do
        Req.Test.stub(stub_name, fn conn ->
          Req.Test.json(conn, %{
            "choices" => [
              %{
                "finish_reason" => "tool_calls",
                "message" => %{
                  "role" => "assistant",
                  "tool_calls" => [
                    %{
                      "id" => "c1",
                      "type" => "function",
                      "function" => %{"name" => "delete_item", "arguments" => raw_args}
                    }
                  ]
                }
              }
            ],
            "usage" => %{}
          })
        end)

        assert {:error, %{status: :error}} =
                 Alloy.run("delete it",
                   provider:
                     {OpenAICompat,
                      api_url: "http://localhost",
                      model: "m",
                      req_options: [plug: {Req.Test, stub_name}]},
                   tools: [tool],
                   tool_validation: validation,
                   max_retries: 0
                 )

        refute_received {:tool_executed, _}
      end
    end

    test "rejects missing/empty tool call id, invalid name, non-map calls, and malformed extra_content without crashing or executing tools" do
      test_pid = self()

      tool =
        Alloy.Tool.inline(
          name: "delete_item",
          description: "Deletes an optional target",
          input_schema: %{type: "object", properties: %{target: %{type: "string"}}},
          execute: fn input, _ctx ->
            send(test_pid, {:tool_executed, input})
            {:ok, "deleted"}
          end
        )

      bad_tool_calls_cases = [
        {:oc_missing_id,
         [%{"type" => "function", "function" => %{"name" => "delete_item", "arguments" => "{}"}}]},
        {:oc_nil_id,
         [
           %{
             "id" => nil,
             "type" => "function",
             "function" => %{"name" => "delete_item", "arguments" => "{}"}
           }
         ]},
        {:oc_empty_id,
         [
           %{
             "id" => "",
             "type" => "function",
             "function" => %{"name" => "delete_item", "arguments" => "{}"}
           }
         ]},
        {:oc_empty_name,
         [
           %{
             "id" => "c1",
             "type" => "function",
             "function" => %{"name" => "", "arguments" => "{}"}
           }
         ]},
        {:oc_non_map_tc, ["not-a-map"]},
        {:oc_non_list_tool_calls, "not-a-list"},
        {:oc_bad_extra_content,
         [
           %{
             "id" => "c1",
             "type" => "function",
             "extra_content" => false,
             "function" => %{"name" => "delete_item", "arguments" => "{}"}
           }
         ]},
        {:oc_bad_google_extra,
         [
           %{
             "id" => "c1",
             "type" => "function",
             "extra_content" => %{"google" => "bad"},
             "function" => %{"name" => "delete_item", "arguments" => "{}"}
           }
         ]}
      ]

      for {stub_name, tool_calls} <- bad_tool_calls_cases do
        Req.Test.stub(stub_name, fn conn ->
          Req.Test.json(conn, %{
            "choices" => [
              %{
                "finish_reason" => "tool_calls",
                "message" => %{"role" => "assistant", "tool_calls" => tool_calls}
              }
            ],
            "usage" => %{}
          })
        end)

        assert {:error, %Error{kind: :protocol_error}} =
                 OpenAICompat.complete([Message.user("delete it")], [], %{
                   api_url: "http://localhost",
                   model: "m",
                   req_options: [plug: {Req.Test, stub_name}]
                 })

        assert {:error, %{status: :error}} =
                 Alloy.run("delete it",
                   provider:
                     {OpenAICompat,
                      api_url: "http://localhost",
                      model: "m",
                      req_options: [plug: {Req.Test, stub_name}]},
                   tools: [tool],
                   stop_after_tool: "delete_item",
                   max_retries: 0
                 )

        refute_received {:tool_executed, _}
      end
    end

    test "returns :protocol_error for missing/null/non-map message or non-map choice and tolerates malformed usage" do
      bad_payloads = [
        {:oc_missing_msg, %{"choices" => [%{"finish_reason" => "stop"}]}},
        {:oc_null_msg, %{"choices" => [%{"message" => nil, "finish_reason" => "stop"}]}},
        {:oc_str_msg, %{"choices" => [%{"message" => "bad", "finish_reason" => "stop"}]}},
        {:oc_bad_choice, %{"choices" => ["not-a-map"]}},
        {:oc_bad_content,
         %{
           "choices" => [
             %{"message" => %{"content" => %{"text" => "lost"}}, "finish_reason" => "stop"}
           ]
         }},
        {:oc_bad_reasoning,
         %{
           "choices" => [
             %{
               "message" => %{"content" => "ok", "reasoning_content" => 123},
               "finish_reason" => "stop"
             }
           ]
         }}
      ]

      for {stub_name, payload} <- bad_payloads do
        Req.Test.stub(stub_name, fn conn -> Req.Test.json(conn, payload) end)

        assert {:error, %Error{kind: :protocol_error}} =
                 OpenAICompat.complete([Message.user("Hi")], [], %{
                   api_url: "http://localhost",
                   model: "m",
                   req_options: [plug: {Req.Test, stub_name}]
                 })
      end

      Req.Test.stub(:oc_numeric_in_band_error, fn conn ->
        Req.Test.json(conn, %{"error" => %{"code" => 429, "message" => "Rate limited"}})
      end)

      assert {:error, %Error{kind: :rate_limited, status: 429, message: "Rate limited"}} =
               OpenAICompat.complete([Message.user("Hi")], [], %{
                 api_url: "http://localhost",
                 model: "m",
                 req_options: [plug: {Req.Test, :oc_numeric_in_band_error}]
               })

      Req.Test.stub(:oc_bad_usage, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
          ],
          "usage" => %{
            "prompt_tokens" => "bad",
            "completion_tokens" => -5,
            "prompt_tokens_details" => "not-a-map"
          }
        })
      end)

      assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0}}} =
               OpenAICompat.complete([Message.user("Hi")], [], %{
                 api_url: "http://localhost",
                 model: "m",
                 req_options: [plug: {Req.Test, :oc_bad_usage}]
               })
    end

    test "supports array-of-parts content (skipping unknown part types), omitted tool arguments, finish_reason stop with tool calls, and omits reasoning_content echo on turn 2" do
      Req.Test.stub(:oc_array_and_stop_tools, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "message" => %{
                "role" => "assistant",
                "content" => [
                  %{
                    "type" => "thinking",
                    "thinking" => [
                      %{"type" => "text", "text" => "step 1"},
                      %{"type" => "reference", "reference_ids" => [1]}
                    ]
                  },
                  %{"type" => "reference", "reference_ids" => [2]},
                  %{"type" => "text", "text" => "calling ping"}
                ],
                "tool_calls" => [
                  %{"id" => "c1", "type" => "function", "function" => %{"name" => "ping"}}
                ]
              }
            }
          ]
        })
      end)

      assert {:ok,
              %{
                stop_reason: :tool_use,
                messages: [
                  %Message{
                    content: [
                      %{type: "thinking", thinking: "step 1", source: "content_part"},
                      %{type: "text", text: "calling ping"},
                      %{type: "tool_use", id: "c1", name: "ping", input: %{}}
                    ]
                  } = assistant_msg
                ]
              }} =
               OpenAICompat.complete([Message.user("Hi")], [], %{
                 api_url: "http://localhost",
                 model: "m",
                 req_options: [plug: {Req.Test, :oc_array_and_stop_tools}]
               })

      assert Message.thinking(assistant_msg) == "step 1"

      # Multi-turn check: content-part-sourced thinking must not inject a
      # DeepSeek-style "reasoning_content" key on the outgoing assistant message.
      tool_result_msg = Message.tool_results([Message.tool_result_block("c1", "pong")])

      assert {:ok, _} =
               OpenAICompat.complete(
                 [Message.user("Hi"), assistant_msg, tool_result_msg],
                 [],
                 config_that_captures_request()
               )

      assert_received {:request_body, body}
      outgoing = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(outgoing, "reasoning_content")
    end

    test "handles truncated tool-call arguments under length and content_filter without retrying" do
      test_pid = self()

      tool =
        Alloy.Tool.inline(
          name: "read",
          description: "Read file",
          input_schema: %{type: "object", properties: %{path: %{type: "string"}}},
          execute: fn _input, _ctx ->
            send(test_pid, :tool_should_not_run)
            {:ok, "ok"}
          end
        )

      Req.Test.stub(:oc_truncated_length, fn conn ->
        send(test_pid, :length_request_hit)

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "length",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "read", "arguments" => ~s({"path": "/tm)}
                  }
                ]
              }
            }
          ]
        })
      end)

      assert {:error, %{status: :error, error: err_msg}} =
               Alloy.run("read file",
                 provider:
                   {OpenAICompat,
                    api_url: "http://localhost",
                    model: "m",
                    req_options: [plug: {Req.Test, :oc_truncated_length}]},
                 tools: [tool],
                 max_retries: 2,
                 retry_backoff_ms: 0
               )

      assert err_msg =~ "max_tokens"
      assert_received :length_request_hit
      refute_received :length_request_hit
      refute_received :tool_should_not_run

      Req.Test.stub(:oc_truncated_filter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "content_filter",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "read", "arguments" => ~s({"path": "/tm)}
                  }
                ]
              }
            }
          ]
        })
      end)

      assert {:ok, %{stop_reason: :refusal, messages: [%Message{content: []}]}} =
               OpenAICompat.complete([Message.user("Hi")], [], %{
                 api_url: "http://localhost",
                 model: "m",
                 req_options: [plug: {Req.Test, :oc_truncated_filter}]
               })

      Req.Test.stub(:oc_truncated_placeholder, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "length",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [%{"function" => %{}}]
              }
            }
          ]
        })
      end)

      assert {:ok,
              %{
                stop_reason: :max_tokens,
                messages: [
                  %Message{
                    content: [
                      %{type: "tool_use", id: "truncated_0_" <> _, name: "truncated", input: %{}}
                    ]
                  }
                ]
              }} =
               OpenAICompat.complete([Message.user("Hi")], [], %{
                 api_url: "http://localhost",
                 model: "m",
                 req_options: [plug: {Req.Test, :oc_truncated_placeholder}]
               })

      # Under finish_reason: "length", structurally invalid tool_calls entries
      # (non-map entry, non-map function, non-string name) still fail with :protocol_error.
      for {stub, bad_calls} <- [
            {:oc_length_non_map_tc, ["not-a-map"]},
            {:oc_length_bad_func, [%{"id" => "c1", "function" => "bad"}]},
            {:oc_length_bad_name, [%{"id" => "c1", "function" => %{"name" => 123}}]}
          ] do
        Req.Test.stub(stub, fn conn ->
          Req.Test.json(conn, %{
            "choices" => [
              %{
                "finish_reason" => "length",
                "message" => %{"role" => "assistant", "tool_calls" => bad_calls}
              }
            ]
          })
        end)

        assert {:error, %Error{kind: :protocol_error}} =
                 OpenAICompat.complete([Message.user("Hi")], [], %{
                   api_url: "http://localhost",
                   model: "m",
                   req_options: [plug: {Req.Test, stub}]
                 })
      end

      # Defensive format_message/1: tolerates non-map blocks, thinking blocks
      # missing :thinking, and atom :content_part source without crashing.
      weird_assistant = %Message{
        role: :assistant,
        content: [
          "stray-binary",
          %{type: "thinking"},
          %{type: "thinking", thinking: "ignored", source: :content_part},
          %{type: "text", text: "kept"}
        ]
      }

      assert {:ok, _} =
               OpenAICompat.complete(
                 [Message.user("Hi"), weird_assistant],
                 [],
                 config_that_captures_request()
               )

      assert_received {:request_body, body}
      outgoing = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))
      assert outgoing["content"] == "kept"
      refute Map.has_key?(outgoing, "reasoning_content")
    end

    test "formats URL images and resolves dynamic optional api_key callbacks" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ]
          })
        )
      end

      config = %{
        api_url: "http://localhost:11434",
        model: "llama4",
        api_key: fn -> {:ok, "dyn-compat-key"} end,
        req_options: [plug: plug]
      }

      messages = [
        %Message{
          role: :user,
          content: [
            %{type: "text", text: "Describe"},
            Message.image_url("https://example.com/photo.jpg"),
            Message.image_url("gs://ignored/not-http.jpg")
          ]
        }
      ]

      assert {:ok, _} = OpenAICompat.complete(messages, [], config)
      assert_received {:request_body, body}
      assert_received {:request_headers, headers}

      assert {"authorization", "Bearer dyn-compat-key"} in headers
      [%{"role" => "user", "content" => parts}] = Jason.decode!(body)["messages"]

      assert parts == [
               %{"type" => "text", "text" => "Describe"},
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.com/photo.jpg"}
               },
               %{
                 "type" => "text",
                 "text" => "[Unsupported image URL scheme for OpenAICompat provider]"
               }
             ]

      # Stream path also resolves dynamic :api_key callback.
      stream_plug = fn conn ->
        send(test_pid, {:stream_headers, conn.req_headers})

        sse =
          "data: " <>
            Jason.encode!(%{
              "choices" => [%{"delta" => %{"content" => "hi"}, "finish_reason" => "stop"}]
            }) <> "\n\ndata: [DONE]\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, _} =
               OpenAICompat.stream(
                 [Message.user("Hi")],
                 [],
                 %{config | req_options: [plug: stream_plug]},
                 fn _ -> :ok end
               )

      assert_received {:stream_headers, sh}
      assert {"authorization", "Bearer dyn-compat-key"} in sh
    end
  end
end
