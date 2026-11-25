defmodule Alloy.Provider.OpenAIStreamTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.{Error, OpenAICompat, OpenAIStream}

  # ── Helper: build SSE chunks ─────────────────────────────────────────

  defp sse_chunk(data) when is_map(data) do
    "data: #{Jason.encode!(data)}\n\n"
  end

  defp sse_done, do: "data: [DONE]\n\n"

  defp text_delta(text) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
    }
  end

  defp tool_call_start(index, id, name) do
    %{
      "id" => "chatcmpl-test",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => index,
                "id" => id,
                "type" => "function",
                "function" => %{"name" => name, "arguments" => ""}
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end

  defp tool_call_args(index, partial_json) do
    %{
      "id" => "chatcmpl-test",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{"index" => index, "function" => %{"arguments" => partial_json}}
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end

  defp finish_chunk(reason) do
    %{
      "id" => "chatcmpl-test",
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]
    }
  end

  defp usage_chunk(prompt, completion) do
    %{
      "id" => "chatcmpl-test",
      "choices" => [],
      "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => completion}
    }
  end

  # ── Helper: stub Req with chunked SSE response ──────────────────────

  defp stream_with_sse_chunks(chunks, on_chunk, opts) do
    test_name = opts[:test_name] || :openai_stream_test
    test_pid = self()

    Req.Test.stub(test_name, fn conn ->
      if opts[:capture_request] do
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
      end

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk_data, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk_data)
        conn
      end)
    end)

    url = "http://localhost/v1/chat/completions"
    headers = [{"authorization", "Bearer sk-test"}, {"content-type", "application/json"}]
    body = %{"model" => "gpt-test", "messages" => [%{"role" => "user", "content" => "Hi"}]}
    req_options = [plug: {Req.Test, test_name}]

    OpenAIStream.stream(url, headers, body, on_chunk, req_options)
  end

  # ── Tests ────────────────────────────────────────────────────────────

  describe "stream/5 text streaming" do
    test "emits text chunks via on_chunk and returns correct response" do
      chunks = [
        sse_chunk(text_delta("Hello")),
        sse_chunk(text_delta(" world")),
        sse_chunk(finish_chunk("stop")),
        sse_chunk(usage_chunk(10, 5)),
        sse_done()
      ]

      {collected, result} = collect_stream(chunks, test_name: :text_basic)

      assert collected == ["Hello", " world"]
      assert {:ok, response} = result
      assert response.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = response.messages
      assert Message.text(hd(response.messages)) == "Hello world"
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 5
    end

    test "handles empty content deltas without crashing" do
      chunks = [
        sse_chunk(%{
          "id" => "test",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => nil}]
        }),
        sse_chunk(text_delta("ok")),
        sse_chunk(finish_chunk("stop")),
        sse_done()
      ]

      {collected, result} = collect_stream(chunks, test_name: :text_empty_delta)

      assert collected == ["ok"]
      assert {:ok, _} = result
    end
  end

  describe "stream/5 tool call streaming" do
    test "accumulates tool call arguments and returns tool_use blocks" do
      chunks = [
        sse_chunk(tool_call_start(0, "call_abc", "read")),
        sse_chunk(tool_call_args(0, "{\"file")),
        sse_chunk(tool_call_args(0, "_path\":\"")),
        sse_chunk(tool_call_args(0, "mix.exs\"}")),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {collected, result} = collect_stream(chunks, test_name: :tool_basic)

      # No text chunks for tool calls
      assert collected == []
      assert {:ok, response} = result
      assert response.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = response.messages
      tool = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool.id == "call_abc"
      assert tool.name == "read"
      assert tool.input == %{"file_path" => "mix.exs"}
    end

    test "keeps the id when later chunks repeat it as null (DeepInfra)" do
      args = fn text ->
        %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "content" => "",
                "tool_calls" => [
                  %{"index" => 0, "id" => nil, "function" => %{"arguments" => text}}
                ]
              },
              "finish_reason" => nil
            }
          ]
        }
      end

      null_tool_calls = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"content" => "", "tool_calls" => nil},
            "finish_reason" => nil
          }
        ]
      }

      chunks = [
        sse_chunk(null_tool_calls),
        sse_chunk(tool_call_start(0, "chatcmpl-tool-abc", "read")),
        sse_chunk(args.("{\"file_path\":")),
        sse_chunk(args.("\"mix.exs\"}")),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :tool_null_id)

      assert {:ok, response} = result
      assert [%Message{content: blocks}] = response.messages
      tool = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool.id == "chatcmpl-tool-abc"
      assert tool.input == %{"file_path" => "mix.exs"}
    end

    test "keeps text and finish_reason when chunks carry tool_calls: null (DeepInfra)" do
      chunk = fn content, finish ->
        %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => content, "tool_calls" => nil},
              "finish_reason" => finish
            }
          ]
        }
      end

      chunks = [
        sse_chunk(chunk.("Hello", nil)),
        sse_chunk(chunk.(" world", nil)),
        sse_chunk(chunk.("", "stop")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :text_null_tool_calls)

      assert {:ok, response} = result
      assert response.stop_reason == :end_turn
      assert [%Message{content: [%{type: "text", text: "Hello world"}]}] = response.messages
    end

    test "handles multiple tool calls in same stream" do
      chunks = [
        sse_chunk(tool_call_start(0, "call_1", "read")),
        sse_chunk(tool_call_args(0, "{\"path\":\"a.ex\"}")),
        sse_chunk(tool_call_start(1, "call_2", "write")),
        sse_chunk(tool_call_args(1, "{\"path\":\"b.ex\"}")),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :tool_multi)

      assert {:ok, response} = result
      tool_blocks = Enum.filter(hd(response.messages).content, &(&1.type == "tool_use"))
      assert length(tool_blocks) == 2
      assert Enum.map(tool_blocks, & &1.name) == ["read", "write"]
    end
  end

  describe "stream/5 mixed text + tool calls" do
    test "emits text chunks and accumulates tool args" do
      chunks = [
        sse_chunk(text_delta("Let me read that.")),
        sse_chunk(tool_call_start(0, "call_x", "read")),
        sse_chunk(tool_call_args(0, "{\"path\":\"mix.exs\"}")),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {collected, result} = collect_stream(chunks, test_name: :mixed)

      assert collected == ["Let me read that."]
      assert {:ok, response} = result
      blocks = hd(response.messages).content
      assert Enum.any?(blocks, &(&1.type == "text"))
      assert Enum.any?(blocks, &(&1.type == "tool_use"))
    end
  end

  describe "stream/5 finish reasons" do
    test "stop maps to :end_turn" do
      chunks = [sse_chunk(text_delta("hi")), sse_chunk(finish_chunk("stop")), sse_done()]
      {_, result} = collect_stream(chunks, test_name: :finish_stop)
      assert {:ok, %{stop_reason: :end_turn}} = result
    end

    test "tool_calls maps to :tool_use" do
      chunks = [
        sse_chunk(tool_call_start(0, "c1", "read")),
        sse_chunk(tool_call_args(0, "{}")),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_, result} = collect_stream(chunks, test_name: :finish_tool)
      assert {:ok, %{stop_reason: :tool_use}} = result
    end

    test "length maps to :max_tokens" do
      chunks = [sse_chunk(text_delta("hi")), sse_chunk(finish_chunk("length")), sse_done()]
      {_, result} = collect_stream(chunks, test_name: :finish_length)
      assert {:ok, %{stop_reason: :max_tokens}} = result
    end

    test "content_filter maps to :refusal with the details" do
      chunks = [
        sse_chunk(text_delta("hi")),
        sse_chunk(finish_chunk("content_filter")),
        sse_done()
      ]

      {_, result} = collect_stream(chunks, test_name: :finish_filter)

      assert {:ok, %{stop_reason: :refusal} = response} = result
      assert response.response_metadata.stop_details == %{"finish_reason" => "content_filter"}
    end

    test "the deprecated function_call maps to :tool_use" do
      chunks = [
        sse_chunk(tool_call_start(0, "c1", "read")),
        sse_chunk(finish_chunk("function_call")),
        sse_done()
      ]

      {_, result} = collect_stream(chunks, test_name: :finish_function_call)
      assert {:ok, %{stop_reason: :tool_use}} = result
    end
  end

  describe "stream/5 request body" do
    test "includes stream: true and stream_options in request" do
      chunks = [sse_chunk(text_delta("ok")), sse_chunk(finish_chunk("stop")), sse_done()]

      {_, _result} =
        collect_stream(chunks, test_name: :req_body, capture_request: true)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
      assert decoded["stream_options"] == %{"include_usage" => true}
    end
  end

  describe "stream/5 tool call edge cases" do
    test "returns ok when tool call has empty arguments (no-arg tool)" do
      # A tool with no arguments sends arguments: "" — Jason.decode!("") would crash.
      chunks = [
        sse_chunk(tool_call_start(0, "call_noarg", "ping")),
        # No args delta — arguments_buffer stays ""
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :tool_empty_args)

      assert {:ok, response} = result
      tool = Enum.find(hd(response.messages).content, &(&1.type == "tool_use"))
      assert tool.name == "ping"
      # Empty args buffer should decode to empty map, not crash
      assert tool.input == %{}
    end

    test "returns :malformed_reply error when tool call has malformed JSON arguments (network truncation)" do
      chunks = [
        sse_chunk(tool_call_start(0, "call_bad", "read")),
        sse_chunk(tool_call_args(0, "{\"file_path\": \"mix")),
        # Truncated — no closing brace
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :tool_malformed_args)

      # Should return a typed malformed_reply error, NOT raise an exception
      assert {:error, %Error{kind: :malformed_reply}} = result
    end

    test "rejects raw non-string argument deltas, non-object decoded arguments, and malformed SSE JSON without executing tools" do
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

      raw_arg_delta = fn raw_value ->
        sse_chunk(%{
          "id" => "chatcmpl-bad",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => raw_value}}]
              },
              "finish_reason" => nil
            }
          ]
        })
      end

      extra_content_delta = fn extra, args ->
        sse_chunk(%{
          "id" => "chatcmpl-bad",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "extra_content" => extra,
                    "function" => %{"arguments" => args}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })
      end

      nil_choice_delta =
        sse_chunk(%{
          "id" => "chatcmpl-bad",
          "object" => "chat.completion.chunk",
          "choices" => [%{"index" => 0, "delta" => nil, "finish_reason" => nil}]
        })

      cases = [
        {:stream_raw_nil_arg, [raw_arg_delta.(nil)], "Invalid tool call arguments delta"},
        {:stream_raw_false_arg, [raw_arg_delta.(false)], "Invalid tool call arguments delta"},
        {:stream_raw_list_arg, [raw_arg_delta.([])], "Invalid tool call arguments delta"},
        {:stream_bad_extra_content, [extra_content_delta.(false, "false")],
         "Invalid extra_content"},
        {:stream_bad_google_extra, [extra_content_delta.(%{"google" => false}, "{}")],
         "Invalid extra_content.google"},
        {:stream_nil_choice_delta, [nil_choice_delta], "Invalid choice delta"},
        {:stream_encoded_null_arg, [sse_chunk(tool_call_args(0, "null"))],
         "must be a JSON object"},
        {:stream_encoded_false_arg, [sse_chunk(tool_call_args(0, "false"))],
         "must be a JSON object"},
        {:stream_encoded_array_arg, [sse_chunk(tool_call_args(0, "[]"))],
         "must be a JSON object"},
        {:stream_bad_sse_json, ["data: {broken\n\n"], "Malformed JSON"}
      ]

      for validation <- modes, {stub_name, bad_chunks, expected_msg} <- cases do
        body =
          ([sse_chunk(tool_call_start(0, "call_1", "delete_item"))] ++
             bad_chunks ++
             [sse_chunk(finish_chunk("tool_calls")), sse_done()])
          |> Enum.join()

        Req.Test.stub(stub_name, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
        end)

        assert {:error, %Error{kind: :malformed_reply, message: provider_msg}} =
                 OpenAICompat.stream(
                   [Message.user("delete it")],
                   [],
                   %{
                     api_url: "http://localhost",
                     model: "m",
                     req_options: [plug: {Req.Test, stub_name}]
                   },
                   fn _ -> :ok end
                 )

        assert provider_msg =~ expected_msg

        assert {:error, %{status: :error, error: error_msg}} =
                 Alloy.stream("delete it", fn _ -> :ok end,
                   provider:
                     {OpenAICompat,
                      api_url: "http://localhost",
                      model: "m",
                      req_options: [plug: {Req.Test, stub_name}]},
                   tools: [tool],
                   tool_validation: validation,
                   max_retries: 0
                 )

        assert error_msg =~ expected_msg
        refute_received {:tool_executed, _}
      end

      # Streamed tool call missing id or function name is also rejected with :malformed_reply.
      missing_meta_chunks = [
        sse_chunk(%{
          "id" => "chatcmpl-bad",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{}"}}]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, missing_result} =
        collect_stream(missing_meta_chunks, test_name: :tool_missing_id_or_name)

      assert {:error, %Error{kind: :malformed_reply, message: msg}} = missing_result
      assert msg =~ "missing id or function name"
    end

    test "supports omitted tool call index (Gemini OpenAI-compat) while rejecting non-integer index" do
      no_index_chunks = [
        sse_chunk(%{
          "id" => "chatcmpl-gem",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_gem_1",
                    "function" => %{"name" => "read", "arguments" => "{\"path\":"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse_chunk(%{
          "id" => "chatcmpl-gem",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [%{"function" => %{"arguments" => "\"mix.exs\"}"}}]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, {:ok, response}} =
        collect_stream(no_index_chunks, test_name: :tool_omitted_index)

      assert [
               %Message{
                 content: [
                   %{
                     type: "tool_use",
                     id: "call_gem_1",
                     name: "read",
                     input: %{"path" => "mix.exs"}
                   }
                 ]
               }
             ] =
               response.messages

      bad_index_chunks = [
        sse_chunk(%{
          "id" => "chatcmpl-bad-idx",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => "zero",
                    "id" => "c1",
                    "function" => %{"name" => "read", "arguments" => "{}"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, {:error, %Error{kind: :malformed_reply, message: bad_idx_msg}}} =
        collect_stream(bad_index_chunks, test_name: :tool_bad_index)

      assert bad_idx_msg =~ "Invalid tool call index"
    end

    test "cached prompt tokens are reported apart from uncached input" do
      usage = %{
        "id" => "chatcmpl-test",
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 10,
          "prompt_tokens_details" => %{"cached_tokens" => 8, "cache_write_tokens" => 2}
        }
      }

      chunks = [
        sse_chunk(text_delta("hi")),
        sse_chunk(finish_chunk("stop")),
        sse_chunk(usage),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :usage_cached)

      assert {:ok, response} = result

      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 10,
               cache_read_input_tokens: 8,
               cache_creation_input_tokens: 2
             }
    end

    test "usage event with empty choices array is captured correctly" do
      # Some providers send choices: [] alongside usage
      usage_with_empty_choices = %{
        "id" => "chatcmpl-test",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10}
      }

      chunks = [
        sse_chunk(text_delta("hi")),
        sse_chunk(finish_chunk("stop")),
        sse_chunk(usage_with_empty_choices),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :usage_empty_choices)

      assert {:ok, response} = result
      assert response.usage.input_tokens == 20
      assert response.usage.output_tokens == 10
    end

    test "captures usage attached to a non-empty choices chunk" do
      payload = %{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "hi"}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 42, "completion_tokens" => 7}
      }

      Req.Test.stub(:openai_stream_inline_usage, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: #{Jason.encode!(payload)}\n\ndata: [DONE]\n\n")
      end)

      assert {:ok, response} =
               OpenAIStream.stream(
                 "http://localhost/v1/chat/completions",
                 [],
                 %{"model" => "m", "messages" => []},
                 fn _ -> :ok end,
                 plug: {Req.Test, :openai_stream_inline_usage}
               )

      assert response.usage.input_tokens == 42
      assert response.usage.output_tokens == 7
    end

    test "reuses slot for repeated tool call id without index, supports parallel id-keyed calls, and tolerates malformed usage" do
      chunks = [
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_a",
                    "function" => %{"name" => "read", "arguments" => "{\"path\":"}
                  }
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_b",
                    "function" => %{"name" => "write", "arguments" => "{\"ok\":true}"}
                  }
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"id" => "call_a", "function" => %{"arguments" => "\"mix.exs\"}"}}
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}],
          "usage" => %{
            "prompt_tokens" => "bad",
            "completion_tokens" => 5,
            "prompt_tokens_details" => "not-a-map"
          }
        }),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :repeated_id_no_index)

      assert {:ok, %{stop_reason: :tool_use, messages: [%Message{content: blocks}], usage: usage}} =
               result

      assert [
               %{type: "tool_use", id: "call_a", name: "read", input: %{"path" => "mix.exs"}},
               %{type: "tool_use", id: "call_b", name: "write", input: %{"ok" => true}}
             ] = blocks

      assert usage.input_tokens == 0
      assert usage.output_tokens == 5
    end

    test "handles sparse explicit indices mixed with omitted indices and routes id-less continuations to the most recently touched call" do
      # Explicit index 1 followed by an omitted-index call B must not overwrite index 1,
      # and an id-less fragment after a repeated-id touch on call_a must extend call_a.
      chunks = [
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 1,
                    "id" => "call_a",
                    "function" => %{"name" => "read", "arguments" => "{\"path\":"}
                  }
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_b",
                    "function" => %{"name" => "write", "arguments" => "{\"ok\":true}"}
                  }
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"id" => "call_a", "function" => %{"arguments" => "\"mix"}}
                ]
              }
            }
          ]
        }),
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"function" => %{"arguments" => ".exs\"}"}}
                ]
              }
            }
          ]
        }),
        # Choice without delta carrying finish_reason must still preserve :tool_use.
        sse_chunk(%{"choices" => [%{"index" => 0, "finish_reason" => "tool_calls"}]}),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :sparse_and_interleaved_indices)

      assert {:ok, %{stop_reason: :tool_use, messages: [%Message{content: blocks}]}} = result

      assert [
               %{type: "tool_use", id: "call_a", name: "read", input: %{"path" => "mix.exs"}},
               %{type: "tool_use", id: "call_b", name: "write", input: %{"ok" => true}}
             ] = blocks
    end

    test "rejects non-map choices, non-list choices, and non-string delta content/reasoning_content" do
      for {name, bad_chunk} <- [
            {:bad_choice_item, %{"choices" => ["bad"]}},
            {:bad_choices_field, %{"choices" => "bad"}},
            {:bad_delta_content,
             %{"choices" => [%{"delta" => %{"content" => %{"text" => "lost"}}}]}},
            {:bad_delta_content_part, %{"choices" => [%{"delta" => %{"content" => [123]}}]}},
            {:bad_delta_text_part,
             %{"choices" => [%{"delta" => %{"content" => [%{"type" => "text", "text" => 123}]}}]}},
            {:bad_delta_thinking_part,
             %{
               "choices" => [
                 %{"delta" => %{"content" => [%{"type" => "thinking", "thinking" => [123]}]}}
               ]
             }},
            {:bad_delta_thinking_scalar,
             %{
               "choices" => [
                 %{"delta" => %{"content" => [%{"type" => "thinking", "thinking" => 123}]}}
               ]
             }},
            {:bad_delta_reasoning, %{"choices" => [%{"delta" => %{"reasoning_content" => 123}}]}}
          ] do
        chunks = [sse_chunk(bad_chunk), sse_chunk(finish_chunk("stop")), sse_done()]
        {_collected, result} = collect_stream(chunks, test_name: name)
        assert {:error, %Error{kind: :malformed_reply}} = result
      end
    end

    test "maps finish_reason stop with tool calls to :tool_use while preserving length/content_filter, and supports array-of-parts delta content with unknown parts" do
      tool_stop_chunks = [
        sse_chunk(tool_call_start(0, "call_1", "ping")),
        sse_chunk(tool_call_args(0, "{}")),
        sse_chunk(finish_chunk("stop")),
        sse_done()
      ]

      {_, tool_result} = collect_stream(tool_stop_chunks, test_name: :stop_with_tool_calls)

      assert {:ok,
              %{stop_reason: :tool_use, messages: [%Message{content: [%{type: "tool_use"}]}]}} =
               tool_result

      length_chunks = [
        sse_chunk(tool_call_start(0, "call_1", "ping")),
        sse_chunk(tool_call_args(0, ~s({"path": "/tm))),
        sse_chunk(finish_chunk("length")),
        sse_done()
      ]

      {_, length_res} = collect_stream(length_chunks, test_name: :tool_length)

      assert {:ok,
              %{
                stop_reason: :max_tokens,
                messages: [
                  %Message{
                    content: [%{type: "tool_use", id: "call_1", name: "ping", input: %{}}]
                  }
                ]
              }} = length_res

      missing_meta_length_chunks = [
        sse_chunk(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{}}]}}
          ]
        }),
        sse_chunk(finish_chunk("length")),
        sse_done()
      ]

      {_, placeholder_res} =
        collect_stream(missing_meta_length_chunks, test_name: :tool_length_placeholder)

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
              }} = placeholder_res

      filter_chunks = [
        sse_chunk(tool_call_start(0, "call_1", "ping")),
        sse_chunk(tool_call_args(0, ~s({"path": "/tm))),
        sse_chunk(finish_chunk("content_filter")),
        sse_done()
      ]

      {_, filter_res} = collect_stream(filter_chunks, test_name: :tool_content_filter)

      assert {:ok, %{stop_reason: :refusal, messages: [%Message{content: []}]}} = filter_res

      # End-to-end Alloy.stream/3 check: truncated streamed tool call under
      # finish_reason: "length" fails with max_tokens without retrying or executing the tool.
      test_pid = self()

      tool =
        Alloy.Tool.inline(
          name: "ping",
          description: "Ping",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _input, _ctx ->
            send(test_pid, :stream_tool_should_not_run)
            {:ok, "pong"}
          end
        )

      Req.Test.stub(:stream_truncated_length_e2e, fn conn ->
        send(test_pid, :stream_length_request_hit)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, Enum.join(length_chunks))
      end)

      assert {:error, %{status: :error, error: err_msg}} =
               Alloy.stream("ping it", fn _ -> :ok end,
                 provider:
                   {Alloy.Provider.OpenAICompat,
                    api_url: "http://localhost",
                    model: "m",
                    req_options: [plug: {Req.Test, :stream_truncated_length_e2e}]},
                 tools: [tool],
                 max_retries: 2,
                 retry_backoff_ms: 0
               )

      assert err_msg =~ "max_tokens"
      assert_received :stream_length_request_hit
      refute_received :stream_length_request_hit
      refute_received :stream_tool_should_not_run

      parts_chunks = [
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "content" => [
                  %{
                    "type" => "thinking",
                    "thinking" => [
                      %{"type" => "text", "text" => "plan "},
                      %{"type" => "reference", "reference_ids" => [1]}
                    ]
                  },
                  %{"type" => "reference", "reference_ids" => [2]},
                  %{"type" => "text", "text" => "hello"}
                ]
              }
            }
          ]
        }),
        sse_chunk(finish_chunk("stop")),
        sse_done()
      ]

      {collected, parts_result} = collect_stream(parts_chunks, test_name: :array_delta_content)
      assert collected == ["hello"]

      assert {:ok,
              %{
                stop_reason: :end_turn,
                messages: [
                  %Message{
                    content: [
                      %{type: "thinking", thinking: "plan ", source: "content_part"},
                      %{type: "text", text: "hello"}
                    ]
                  }
                ]
              }} = parts_result
    end

    test "malformed tool-call JSON error does not leak raw argument buffer into error message" do
      chunks = [
        sse_chunk(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_bad",
                    "type" => "function",
                    "function" => %{
                      "name" => "lookup",
                      "arguments" => "{broken SECRET_TOOL_ARG_BUFFER"
                    }
                  }
                ]
              }
            }
          ]
        }),
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :malformed_tool_arg_no_leak)
      assert {:error, %Error{kind: :malformed_reply, message: msg}} = result
      assert msg =~ "Invalid tool call JSON for lookup"
      refute msg =~ "SECRET_TOOL_ARG_BUFFER"
    end
  end

  describe "stream/5 reasoning_content" do
    test "accumulates reasoning_content deltas and produces thinking block" do
      reasoning_delta = fn text ->
        %{
          "id" => "chatcmpl-test",
          "choices" => [
            %{"index" => 0, "delta" => %{"reasoning_content" => text}, "finish_reason" => nil}
          ]
        }
      end

      chunks = [
        sse_chunk(reasoning_delta.("Step 1. ")),
        sse_chunk(reasoning_delta.("Step 2.")),
        sse_chunk(text_delta("The answer.")),
        sse_chunk(finish_chunk("stop")),
        sse_done()
      ]

      {collected, result} = collect_stream(chunks, test_name: :reasoning_stream)

      # Text chunks are emitted via on_chunk
      assert collected == ["The answer."]

      assert {:ok, response} = result
      [%Message{role: :assistant, content: blocks}] = response.messages

      thinking = Enum.find(blocks, &(&1.type == "thinking"))
      assert thinking.thinking == "Step 1. Step 2."

      text = Enum.find(blocks, &(&1.type == "text"))
      assert text.text == "The answer."
    end
  end

  describe "stream/5 failures inside a 200 stream" do
    test "a mid-stream error chunk is an error classified by its type" do
      error_chunk = %{
        "error" => %{
          "type" => "server_error",
          "code" => nil,
          "message" => "The server had an error"
        }
      }

      chunks = [sse_chunk(text_delta("Hel")), sse_chunk(error_chunk)]
      {_, result} = collect_stream(chunks, test_name: :mid_stream_error)

      assert {:error, %Error{kind: :server_error} = error} = result
      assert Exception.message(error) == "server_error: The server had an error"
    end

    test "an error chunk that also carries finish_reason \"error\" is an error" do
      # OpenRouter's mid-stream error shape.
      error_chunk = %{
        "id" => "gen-1",
        "object" => "chat.completion.chunk",
        "error" => %{"code" => 502, "message" => "Provider disconnected"},
        "choices" => [%{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "error"}]
      }

      chunks = [sse_chunk(text_delta("Hel")), sse_chunk(error_chunk), sse_done()]
      {_, result} = collect_stream(chunks, test_name: :openrouter_error)

      assert {:error, %Error{kind: :server_error, status: 502, message: "Provider disconnected"}} =
               result
    end

    test "a stream that ends without finish_reason or [DONE] is an error" do
      chunks = [sse_chunk(text_delta("Hel")), sse_chunk(tool_call_start(0, "call_1", "read"))]
      {_, result} = collect_stream(chunks, test_name: :truncated_stream)

      assert {:error, %Error{kind: :network} = error} = result
      assert Exception.message(error) =~ "ended before"
    end

    test "[DONE] without a finish_reason still completes" do
      chunks = [sse_chunk(text_delta("ok")), sse_done()]
      {_, result} = collect_stream(chunks, test_name: :done_only)

      assert {:ok, %{stop_reason: :end_turn}} = result
    end

    test "a finish_reason without [DONE] still completes" do
      chunks = [sse_chunk(text_delta("ok")), sse_chunk(finish_chunk("stop"))]
      {_, result} = collect_stream(chunks, test_name: :finish_only)

      assert {:ok, %{stop_reason: :end_turn}} = result
    end
  end

  describe "stream/5 error handling" do
    test "returns error on non-200 status" do
      Req.Test.stub(:stream_error, fn conn ->
        Plug.Conn.send_resp(
          conn,
          429,
          Jason.encode!(%{"error" => %{"type" => "rate_limit", "message" => "slow down"}})
        )
      end)

      url = "http://localhost/v1/chat/completions"
      headers = [{"authorization", "Bearer sk-test"}]
      body = %{"model" => "gpt-test", "messages" => []}
      on_chunk = fn _ -> :ok end

      result = OpenAIStream.stream(url, headers, body, on_chunk, plug: {Req.Test, :stream_error})
      assert {:error, _} = result
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(:stream_conn_error, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      url = "http://localhost/v1/chat/completions"
      headers = []
      body = %{"model" => "gpt-test", "messages" => []}
      on_chunk = fn _ -> :ok end

      result =
        OpenAIStream.stream(url, headers, body, on_chunk, plug: {Req.Test, :stream_conn_error})

      assert {:error, _} = result
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp collect_stream(chunks, opts) do
    test_pid = self()
    on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

    result = stream_with_sse_chunks(chunks, on_chunk, opts)
    collected = collect_messages([])

    {collected, result}
  end

  defp collect_messages(acc) do
    receive do
      {:chunk, chunk} -> collect_messages(acc ++ [chunk])
    after
      100 -> acc
    end
  end
end
