defmodule Alloy.Provider.GeminiTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Error
  alias Alloy.Provider.Gemini

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response(
                [%{"text" => "Hello!"}],
                "STOP",
                %{"promptTokenCount" => 10, "candidatesTokenCount" => 5}
              )
            )
        })

      assert {:ok, result} = Gemini.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn

      assert [%Message{role: :assistant, content: [%{type: "text", text: "Hello!"}]}] =
               result.messages

      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
      assert result.response_metadata == %{finish_reason: "STOP"}
    end

    test "bills thoughts as output and splits cache reads and tool-use prompts from input" do
      usage = %{
        "promptTokenCount" => 1_000,
        "cachedContentTokenCount" => 600,
        "toolUsePromptTokenCount" => 300,
        "candidatesTokenCount" => 50,
        "thoughtsTokenCount" => 200,
        "totalTokenCount" => 1_550
      }

      config =
        config_with_response(%{
          status: 200,
          body: Jason.encode!(gemini_response([%{"text" => "Hi"}], "STOP", usage))
        })

      assert {:ok, result} = Gemini.complete([Message.user("Hi")], [], config)

      assert result.usage == %{
               input_tokens: 700,
               output_tokens: 250,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 600
             }

      assert result.usage.input_tokens + result.usage.cache_read_input_tokens +
               result.usage.output_tokens == usage["totalTokenCount"]
    end

    test "preserves thinking parts with thought signatures" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response([
                %{"text" => "Reasoning...", "thought" => true, "thoughtSignature" => "sig_123"},
                %{"text" => "Done."}
              ])
            )
        })

      assert {:ok, result} = Gemini.complete([Message.user("Think")], [], config)

      [thinking, text] = hd(result.messages).content
      assert thinking.type == "thinking"
      assert thinking.thinking == "Reasoning..."
      assert thinking.signature == "sig_123"
      assert text == %{type: "text", text: "Done."}
    end
  end

  describe "complete/3 with tool calls" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response([
                %{"text" => "Let me read that."},
                %{
                  "functionCall" => %{
                    "id" => "call_abc123",
                    "name" => "read",
                    "args" => %{"file_path" => "mix.exs"}
                  }
                }
              ])
            )
        })

      assert {:ok, result} =
               Gemini.complete(
                 [Message.user("Read mix.exs")],
                 [%{name: "read", description: "Read a file", input_schema: %{}}],
                 config
               )

      assert result.stop_reason == :tool_use
      [message] = result.messages
      tool = Enum.find(message.content, &(&1.type == "tool_use"))
      assert tool.id == "call_abc123"
      assert tool.name == "read"
      assert tool.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 request formatting" do
    test "includes system instructions, tool declarations, and Gemini endpoint path" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Gemini.complete(
        [Message.user("Hi")],
        [
          %{
            name: "read",
            description: "Read a file",
            input_schema: %{
              type: "object",
              properties: %{file_path: %{type: "string"}},
              required: ["file_path"]
            }
          }
        ],
        config
      )

      assert_received {:request_body, body}

      assert_received {:request_info,
                       %{request_path: "/v1beta/models/gemini-2.5-flash:generateContent"}}

      assert_received {:request_headers, headers}

      decoded = Jason.decode!(body)
      assert decoded["systemInstruction"]["parts"] == [%{"text" => "You are helpful."}]
      assert decoded["generationConfig"]["maxOutputTokens"] == 4096

      assert [%{"functionDeclarations" => [tool]}] = decoded["tools"]
      assert tool["name"] == "read"
      assert tool["parametersJsonSchema"]["properties"]["file_path"]["type"] == "string"
      assert {"x-goog-api-key", "gem-test-key"} in headers
    end

    test "leaves the output budget to the model when :max_tokens is not set" do
      # The budget includes thinking, so a small fixed default truncates
      # answers from thinking models.
      config = Map.delete(config_that_captures_request(), :max_tokens)

      Gemini.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      refute Map.has_key?(Jason.decode!(body), "generationConfig")
    end

    test "sends :max_tokens as maxOutputTokens next to raw generation_config" do
      config =
        config_that_captures_request()
        |> Map.put(:max_tokens, 1_234)
        |> Map.put(:generation_config, %{thinkingConfig: %{thinkingLevel: "LOW"}})

      Gemini.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}

      assert Jason.decode!(body)["generationConfig"] == %{
               "maxOutputTokens" => 1_234,
               "thinkingConfig" => %{"thinkingLevel" => "LOW"}
             }
    end

    test "omits strict field because Gemini has no strict tool equivalent" do
      config = config_that_captures_request()

      Gemini.complete(
        [Message.user("Hi")],
        [
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
        ],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [%{"functionDeclarations" => [tool]}] = decoded["tools"]
      refute Map.has_key?(tool, "strict")
      refute Map.has_key?(tool, "parameters")
      assert tool["parametersJsonSchema"]["additionalProperties"] == false
      assert tool["parametersJsonSchema"]["required"] == ["query"]
    end

    test "formats tool results as function responses using the original tool call name" do
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

      Gemini.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      function_response =
        decoded["contents"]
        |> List.last()
        |> Map.fetch!("parts")
        |> hd()
        |> Map.fetch!("functionResponse")

      assert function_response["id"] == "call_abc"
      assert function_response["name"] == "read"
      assert function_response["response"] == %{"output" => "file contents here"}
    end

    test "preserves tool text in output or error envelopes without reinterpreting JSON" do
      for {text, is_error} <- [
            {~s({"value":3973}), false},
            {~s([1,2,3]), false},
            {~s({"is_error":true,"error":"ordinary data"}), false},
            {~s({"output":"must remain an error"}), true},
            {"unavailable", true}
          ] do
        messages = [
          Message.assistant_blocks([
            %{type: "tool_use", id: "c1", name: "calculate", input: %{}}
          ]),
          Message.tool_results([Message.tool_result_block("c1", text, is_error)])
        ]

        Gemini.complete(messages, [], config_that_captures_request())
        assert_received {:request_body, body}
        response = body |> Jason.decode!() |> Map.fetch!("contents") |> List.last()

        assert [
                 %{
                   "functionResponse" => %{
                     "id" => "c1",
                     "name" => "calculate",
                     "response" => payload
                   }
                 }
               ] = response["parts"]

        assert payload == %{if(is_error, do: "error", else: "output") => text}
      end
    end

    test "formats thinking blocks back into Gemini thought parts" do
      config = config_that_captures_request()

      messages = [
        Message.assistant_blocks([
          %{type: "thinking", thinking: "Reasoning...", signature: "sig_123"},
          %{type: "text", text: "Answer"}
        ])
      ]

      Gemini.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [first_part, second_part] = hd(decoded["contents"])["parts"]
      assert first_part["text"] == "Reasoning..."
      assert first_part["thought"] == true
      assert first_part["thoughtSignature"] == "sig_123"
      assert second_part["text"] == "Answer"
    end

    test "a step's first unsigned function call gets Google's placeholder signature" do
      config = config_that_captures_request()
      call = fn id -> %{type: "tool_use", id: id, name: "read", input: %{}} end

      messages = [
        Message.user("Read both"),
        Message.assistant_blocks([%{type: "text", text: "Reading."}, call.("a"), call.("b")]),
        Message.tool_results([
          Message.tool_result_block("a", "one"),
          Message.tool_result_block("b", "two")
        ]),
        Message.assistant_blocks([Map.put(call.("c"), :signature, "sig_real")]),
        Message.tool_results([Message.tool_result_block("c", "three")])
      ]

      Gemini.complete(messages, [], config)

      assert_received {:request_body, body}
      [_user, first_step, results, second_step, _results] = Jason.decode!(body)["contents"]

      assert [%{"text" => "Reading."} = text, first_call, second_call] = first_step["parts"]
      refute Map.has_key?(text, "thoughtSignature")
      assert first_call["thoughtSignature"] == "skip_thought_signature_validator"
      refute Map.has_key?(second_call, "thoughtSignature")
      refute Enum.any?(results["parts"], &Map.has_key?(&1, "thoughtSignature"))
      assert [%{"thoughtSignature" => "sig_real"}] = second_step["parts"]
    end

    test "omits empty-map thoughtSignature on parse and falls back to placeholder on replay" do
      parse_config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response([
                %{
                  "functionCall" => %{
                    "id" => "call_empty_sig",
                    "name" => "read",
                    "args" => %{"path" => "a.ex"}
                  },
                  "thoughtSignature" => %{}
                }
              ])
            )
        })

      assert {:ok, %{messages: [assistant_msg]}} =
               Gemini.complete([Message.user("Read")], [], parse_config)

      assert [%{type: "tool_use", id: "call_empty_sig", name: "read"} = parsed_block] =
               assistant_msg.content

      refute Map.has_key?(parsed_block, :signature)

      replay_config = config_that_captures_request()

      hand_built =
        Message.assistant_blocks([
          %{type: "tool_use", id: "call_hand", name: "read", input: %{}, signature: %{}}
        ])

      messages = [
        Message.user("Read"),
        assistant_msg,
        Message.tool_results([Message.tool_result_block("call_empty_sig", "ok")]),
        hand_built,
        Message.tool_results([Message.tool_result_block("call_hand", "ok")])
      ]

      Gemini.complete(messages, [], replay_config)

      assert_received {:request_body, body}
      [_user, first_step, _r1, second_step, _r2] = Jason.decode!(body)["contents"]

      assert [%{"thoughtSignature" => "skip_thought_signature_validator"}] = first_step["parts"]
      assert [%{"thoughtSignature" => "skip_thought_signature_validator"}] = second_step["parts"]

      # Empty list signatures are preserved (only nil and %{} are omitted, matching baseline).
      list_sig_config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response([
                %{"text" => "With list sig", "thoughtSignature" => []}
              ])
            )
        })

      assert {:ok, %{messages: [%Message{content: [%{type: "text", signature: []}]}]}} =
               Gemini.complete([Message.user("Hi")], [], list_sig_config)
    end

    test "formats inline/file_id documents, image URLs, cached_content conflicts, native tools, and server-tool replay" do
      # 1. :cached_content works with system_prompt and local Alloy tools (omitting
      #    systemInstruction/tools from the wire body while still executing returned calls).
      test_pid = self()
      turn_counter = :atomics.new(1, signed: false)

      cached_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:cached_req_body, body})
        send(test_pid, {:cached_req_headers, conn.req_headers})

        resp =
          if :atomics.add_get(turn_counter, 1, 1) == 1 do
            gemini_response([
              %{
                "functionCall" => %{"id" => "c1", "name" => "echo", "args" => %{}},
                "thoughtSignature" => "sig_cached_1"
              }
            ])
          else
            gemini_response([%{"text" => "cached done"}])
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end

      echo_tool =
        Alloy.Tool.inline(
          name: "echo",
          description: "Echo",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _, _ -> {:ok, "ran locally"} end
        )

      assert {:ok, %{text: "cached done"}} =
               Alloy.run("Hi",
                 system_prompt: "Baked into cache",
                 tools: [echo_tool],
                 provider:
                   {Gemini,
                    api_key: fn -> {:ok, "adc-bearer-tok"} end,
                    origin_key: "gem-acct-1",
                    auth_scheme: :bearer,
                    model: "gemini-3.8-flash",
                    cached_content: "cachedContents/abc123",
                    req_options: [plug: cached_plug]}
               )

      assert_received {:cached_req_body, cache_body}
      assert_received {:cached_req_headers, headers}
      assert {"authorization", "Bearer adc-bearer-tok"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "x-goog-api-key" end)
      decoded_cached = Jason.decode!(cache_body)
      assert decoded_cached["cachedContent"] == "cachedContents/abc123"
      refute Map.has_key?(decoded_cached, "systemInstruction")
      refute Map.has_key?(decoded_cached, "tools")

      # 2. :cached_content combined with explicit provider-level tool_config, native tools,
      #    or extra_body tools fails fast; invalid :auth_scheme also fails fast.
      cache_only =
        config_that_captures_request()
        |> Map.put(:cached_content, "cachedContents/abc123")

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request}} =
               Gemini.complete(
                 [Message.user("Hi")],
                 [],
                 Map.put(cache_only, :tool_config, %{functionCallingConfig: %{mode: "AUTO"}})
               )

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request}} =
               Gemini.complete(
                 [Message.user("Hi")],
                 [],
                 Map.put(cache_only, :google_search, true)
               )

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request}} =
               Gemini.complete(
                 [Message.user("Hi")],
                 [],
                 Map.put(cache_only, :extra_body, %{"tools" => [%{"googleSearch" => %{}}]})
               )

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request}} =
               Gemini.complete(
                 [Message.user("Hi")],
                 [],
                 Map.put(cache_only, :auth_scheme, :basic)
               )

      # 3. Combining native tools + custom functionDeclarations sets includeServerSideToolInvocations
      #    and formats multimodal document/image blocks.
      combined_config =
        config_that_captures_request()
        |> Map.merge(%{
          google_search: true,
          url_context: true,
          code_execution: true
        })

      messages = [
        %Alloy.Message{
          role: :user,
          content: [
            Message.image_url("https://example.com/pic.png", mime_type: "image/png"),
            Message.document_data("application/pdf", "JVBERi0="),
            Message.document_file(
              "application/pdf",
              "https://generativelanguage.googleapis.com/v1beta/files/gem-file-1"
            )
          ]
        }
      ]

      assert {:ok, _} = Gemini.complete(messages, tool_defs, combined_config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [
               %{"functionDeclarations" => [%{"name" => "read"}]},
               %{"googleSearch" => %{}},
               %{"urlContext" => %{}},
               %{"codeExecution" => %{}}
             ] = decoded["tools"]

      assert decoded["toolConfig"] == %{"includeServerSideToolInvocations" => true}

      [%{"parts" => [img, doc_data, doc_file]}] = decoded["contents"]

      assert img == %{
               "fileData" => %{
                 "fileUri" => "https://example.com/pic.png",
                 "mimeType" => "image/png"
               }
             }

      assert doc_data == %{
               "inlineData" => %{"mimeType" => "application/pdf", "data" => "JVBERi0="}
             }

      assert doc_file == %{
               "fileData" => %{
                 "mimeType" => "application/pdf",
                 "fileUri" => "https://generativelanguage.googleapis.com/v1beta/files/gem-file-1"
               }
             }

      # 4. Multi-turn round-trip of executableCode, codeExecutionResult, toolCall, and toolResponse
      #    with thoughtSignature preserved verbatim across both complete/3 and stream/4.
      exec_part = %{
        "executableCode" => %{"language" => "PYTHON", "code" => "print(2 + 2)"},
        "thoughtSignature" => "sig_exec_1"
      }

      exec_result = %{
        "codeExecutionResult" => %{"outcome" => "OUTCOME_OK", "output" => "4\n"}
      }

      server_call = %{
        "toolCall" => %{"toolType" => "GOOGLE_SEARCH", "args" => %{"q" => "elixir"}},
        "thoughtSignature" => "sig_srv_1"
      }

      server_resp = %{
        "toolResponse" => %{"toolType" => "GOOGLE_SEARCH", "response" => %{"hits" => 1}}
      }

      resp_cfg =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              gemini_response([
                exec_part,
                exec_result,
                server_call,
                server_resp,
                %{"text" => "4"}
              ])
            )
        })

      assert {:ok, %{messages: [asst_msg]}} =
               Gemini.complete([Message.user("2+2?")], [], resp_cfg)

      assert [
               %{type: "gemini_part", raw: ^exec_part},
               %{type: "gemini_part", raw: ^exec_result},
               %{type: "gemini_part", raw: ^server_call},
               %{type: "gemini_part", raw: ^server_resp},
               %{type: "text", text: "4"}
             ] = asst_msg.content

      # Replay on the next turn preserves all 4 raw parts and their signatures verbatim.
      assert {:ok, _} =
               Gemini.complete(
                 [Message.user("2+2?"), asst_msg, Message.user("Again")],
                 [],
                 config_that_captures_request()
               )

      assert_received {:request_body, replay_body}
      [_u1, model_turn, _u2] = Jason.decode!(replay_body)["contents"]

      assert [^exec_part, ^exec_result, ^server_call, ^server_resp, %{"text" => "4"}] =
               model_turn["parts"]

      # Streaming path also preserves gemini_part blocks verbatim.
      stream_cfg =
        config_with_sse_stream([
          sse_chunk(gemini_response([exec_part, exec_result], nil)),
          sse_chunk(gemini_response([%{"text" => "4"}]))
        ])

      assert {:ok, %{messages: [streamed_asst]}} =
               Gemini.stream([Message.user("2+2?")], [], stream_cfg, fn _ -> :ok end)

      assert [
               %{type: "gemini_part", raw: ^exec_part},
               %{type: "gemini_part", raw: ^exec_result},
               %{type: "text", text: "4"}
             ] = streamed_asst.content
    end

    test "rejects AUTO functionCallingConfig with combined native tools and scopes top-level code_execution to Anthropic" do
      key_called = :atomics.new(1, signed: false)

      tool_defs = [
        %{name: "read", description: "Read", input_schema: %{type: "object", properties: %{}}}
      ]

      conflict_cfg =
        config_that_captures_request()
        |> Map.merge(%{
          api_key: fn ->
            :atomics.add_get(key_called, 1, 1)
            {:ok, "should-not-run"}
          end,
          google_search: true,
          tool_config: %{functionCallingConfig: %{mode: "AUTO"}}
        })

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request, message: msg}} =
               Gemini.complete([Message.user("Hi")], tool_defs, conflict_cfg)

      assert msg =~ "AUTO"
      assert :atomics.get(key_called, 1) == 0

      assert {:error, %Alloy.Provider.Error{kind: :invalid_request}} =
               Gemini.stream([Message.user("Hi")], tool_defs, conflict_cfg, fn _ -> :ok end)

      # VALIDATED mode succeeds alongside native + custom tools.
      valid_cfg =
        config_that_captures_request()
        |> Map.merge(%{
          google_search: true,
          tool_config: %{functionCallingConfig: %{mode: "VALIDATED"}}
        })

      assert {:ok, _} = Gemini.complete([Message.user("Hi")], tool_defs, valid_cfg)
      assert_received {:request_body, valid_body}

      assert Jason.decode!(valid_body)["toolConfig"] == %{
               "functionCallingConfig" => %{"mode" => "VALIDATED"},
               "includeServerSideToolInvocations" => true
             }

      # Top-level Alloy.run code_execution: true does not activate Gemini codeExecution.
      gem_cfg = config_that_captures_request()

      assert {:ok, _} =
               Alloy.run("Hi",
                 provider: {Gemini, gem_cfg},
                 code_execution: true
               )

      assert_received {:request_body, top_body}
      refute Map.has_key?(Jason.decode!(top_body), "tools")
    end
  end

  describe "stream/4" do
    test "emits text chunks via on_chunk and returns a normalized response" do
      config =
        config_with_sse_stream([
          sse_chunk(gemini_response([%{"text" => "Hello"}])),
          sse_chunk(
            gemini_response([%{"text" => " world"}], "STOP", %{
              "promptTokenCount" => 10,
              "candidatesTokenCount" => 5
            })
          )
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = Gemini.stream([Message.user("Hi")], [], config, on_chunk)

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
      assert result.stop_reason == :end_turn
      assert [%Message{content: [%{type: "text", text: "Hello world"}]}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end

    test "merges streamed thought and text pieces and keeps the trailing signature" do
      config =
        config_with_sse_stream([
          sse_chunk(gemini_response([%{"text" => "Let me ", "thought" => true}], nil)),
          sse_chunk(gemini_response([%{"text" => "think.", "thought" => true}], nil)),
          sse_chunk(gemini_response([%{"text" => "The answer"}], nil)),
          sse_chunk(gemini_response([%{"text" => " is 4."}], nil)),
          sse_chunk(gemini_response([%{"text" => "", "thoughtSignature" => "sig_final"}]))
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = Gemini.stream([Message.user("2+2?")], [], config, on_chunk)

      assert [
               %Message{
                 content: [
                   %{type: "thinking", thinking: "Let me think."} = thinking,
                   %{type: "text", text: "The answer is 4.", signature: "sig_final"}
                 ]
               }
             ] = result.messages

      refute Map.has_key?(thinking, :signature)
      refute_received {:chunk, ""}
    end

    test "never merges across a function call and keeps call signatures on the call" do
      config =
        config_with_sse_stream([
          sse_chunk(gemini_response([%{"text" => "Reading "}], nil)),
          sse_chunk(gemini_response([%{"text" => "both."}], nil)),
          sse_chunk(
            gemini_response(
              [
                %{
                  "functionCall" => %{"id" => "c1", "name" => "read", "args" => %{"p" => "a"}},
                  "thoughtSignature" => "sig_call"
                },
                %{"functionCall" => %{"id" => "c2", "name" => "read", "args" => %{"p" => "b"}}}
              ],
              nil
            )
          ),
          sse_chunk(gemini_response([%{"text" => "Done."}]))
        ])

      assert {:ok, result} = Gemini.stream([Message.user("Read")], [], config, fn _ -> :ok end)

      assert [
               %Message{
                 content: [
                   %{type: "text", text: "Reading both."} = text,
                   %{type: "tool_use", id: "c1", signature: "sig_call"},
                   %{type: "tool_use", id: "c2"} = second_call,
                   %{type: "text", text: "Done."}
                 ]
               }
             ] = result.messages

      refute Map.has_key?(text, :signature)
      refute Map.has_key?(second_call, :signature)
    end

    test "reports the final cumulative usage, thoughts included" do
      config =
        config_with_sse_stream([
          sse_chunk(
            gemini_response([%{"text" => "Hel"}], nil, %{
              "promptTokenCount" => 40,
              "cachedContentTokenCount" => 30,
              "thoughtsTokenCount" => 90
            })
          ),
          sse_chunk(
            gemini_response([%{"text" => "lo"}], "STOP", %{
              "promptTokenCount" => 40,
              "cachedContentTokenCount" => 30,
              "candidatesTokenCount" => 2,
              "thoughtsTokenCount" => 90
            })
          )
        ])

      assert {:ok, result} = Gemini.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert result.usage == %{
               input_tokens: 10,
               output_tokens: 92,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 30
             }
    end

    test "never puts two signatures in one block" do
      config =
        config_with_sse_stream([
          sse_chunk(gemini_response([%{"text" => "One.", "thoughtSignature" => "sig_1"}], nil)),
          sse_chunk(gemini_response([%{"text" => "Two.", "thoughtSignature" => "sig_2"}]))
        ])

      assert {:ok, result} = Gemini.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert [
               %Message{
                 content: [
                   %{type: "text", text: "One.", signature: "sig_1"},
                   %{type: "text", text: "Two.", signature: "sig_2"}
                 ]
               }
             ] = result.messages
    end

    test "returns tool_use blocks from streamed function calls" do
      config =
        config_with_sse_stream([
          sse_chunk(
            gemini_response([
              %{
                "functionCall" => %{
                  "id" => "call_tool_1",
                  "name" => "read",
                  "args" => %{"file_path" => "mix.exs"}
                }
              }
            ])
          )
        ])

      assert {:ok, result} =
               Gemini.stream([Message.user("Read mix.exs")], [], config, fn _ -> :ok end)

      assert result.stop_reason == :tool_use

      tool = hd(hd(result.messages).content)
      assert tool.type == "tool_use"
      assert tool.id == "call_tool_1"
      assert tool.name == "read"
      assert tool.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "finish reasons" do
    @refusal_reasons ~w(SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII
                        IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_RECITATION IMAGE_OTHER
                        ESCALATION PUP_LIMITED_DISABLED)

    test "MAX_TOKENS is :max_tokens, keeping the truncated output" do
      response = gemini_response([%{"text" => "Truncat"}], "MAX_TOKENS")

      for result <- [complete_with(response), stream_with([response])] do
        assert {:ok, %{stop_reason: :max_tokens, messages: [message]}} = result
        assert Message.text(message) == "Truncat"
      end
    end

    test "a truncated function call is still :max_tokens so the loop can reject it" do
      response =
        gemini_response(
          [%{"functionCall" => %{"id" => "c1", "name" => "read", "args" => %{}}}],
          "MAX_TOKENS"
        )

      assert {:ok, %{stop_reason: :max_tokens}} = complete_with(response)
    end

    test "content filters are :refusal with the reason in stop_details" do
      rating = %{"category" => "HARM_CATEGORY_HARASSMENT", "probability" => "HIGH"}

      for reason <- @refusal_reasons do
        response =
          [%{"text" => "Partial"}]
          |> gemini_response(reason)
          |> update_in(["candidates", Access.at(0)], fn candidate ->
            Map.merge(candidate, %{"finishMessage" => "Blocked.", "safetyRatings" => [rating]})
          end)

        for result <- [complete_with(response), stream_with([response])] do
          assert {:ok, %{stop_reason: :refusal, response_metadata: metadata}} = result

          assert metadata.stop_details == %{
                   "finishReason" => reason,
                   "finishMessage" => "Blocked.",
                   "safetyRatings" => [rating]
                 }
        end
      end
    end

    test "a blocked prompt with no candidates is :refusal with the block reason" do
      rating = %{"category" => "HARM_CATEGORY_DANGEROUS_CONTENT", "probability" => "HIGH"}

      response = %{
        "promptFeedback" => %{"blockReason" => "PROHIBITED_CONTENT", "safetyRatings" => [rating]},
        "usageMetadata" => %{"promptTokenCount" => 12, "totalTokenCount" => 12}
      }

      for result <- [complete_with(response), stream_with([response])] do
        assert {:ok, %{stop_reason: :refusal, messages: [], usage: usage} = refusal} = result
        assert usage.input_tokens == 12

        assert refusal.response_metadata.stop_details == %{
                 "blockReason" => "PROHIBITED_CONTENT",
                 "safetyRatings" => [rating]
               }
      end
    end

    test "MALFORMED_FUNCTION_CALL is a retryable provider error" do
      response =
        [%{"text" => ""}]
        |> gemini_response("MALFORMED_FUNCTION_CALL")
        |> put_in(
          ["candidates", Access.at(0), "finishMessage"],
          "Malformed function call: read(path=)"
        )

      for result <- [complete_with(response), stream_with([response])] do
        assert {:error, %Error{kind: :server_error} = error} = result
        assert Error.retryable?(error)

        assert Exception.message(error) ==
                 "MALFORMED_FUNCTION_CALL: Malformed function call: read(path=)"
      end
    end

    test "other generation failures are provider errors too" do
      for reason <- ~w(MALFORMED_RESPONSE UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS NO_IMAGE) do
        response = gemini_response([], reason)

        assert {:error, %Error{kind: :server_error, type: ^reason}} = complete_with(response)
        assert {:error, %Error{kind: :server_error, type: ^reason}} = stream_with([response])
      end
    end

    test "MISSING_THOUGHT_SIGNATURE is an invalid request, not retried" do
      response = gemini_response([], "MISSING_THOUGHT_SIGNATURE")

      assert {:error, %Error{kind: :invalid_request, type: "MISSING_THOUGHT_SIGNATURE"}} =
               complete_with(response)
    end

    test "OTHER keeps the content-based stop reason" do
      assert {:ok, %{stop_reason: :end_turn}} =
               complete_with(gemini_response([%{"text" => "ok"}], "OTHER"))
    end
  end

  describe "error handling" do
    test "parses Gemini API errors" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "error" => %{"status" => "INVALID_ARGUMENT", "message" => "bad request"}
            })
        })

      assert {:error, %Error{kind: :invalid_request} = error} =
               Gemini.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) == "INVALID_ARGUMENT: bad request"
    end

    test "an error chunk mid-stream fails the stream instead of returning partial output" do
      error = %{"code" => 503, "message" => "The model is overloaded.", "status" => "UNAVAILABLE"}

      assert {:error, %Error{kind: :overloaded, status: 503} = error} =
               stream_with([
                 gemini_response([%{"text" => "Partial"}], nil),
                 %{"error" => error}
               ])

      assert Exception.message(error) == "UNAVAILABLE: The model is overloaded."
    end

    test "an error object without a numeric code is still classified by its status" do
      assert {:error, %Error{kind: :server_error, type: "INTERNAL"}} =
               stream_with([%{"error" => %{"status" => "INTERNAL", "message" => "boom"}}])
    end

    test "a stream that ends without a finishReason is a retryable error" do
      assert {:error, %Error{kind: :network} = error} =
               stream_with([gemini_response([%{"text" => "Cut o"}], nil)])

      assert Error.retryable?(error)
      assert Exception.message(error) =~ "finishReason"
    end

    test "an empty stream is an error, not an empty answer" do
      assert {:error, %Error{kind: :network}} = stream_with([])
    end

    test "an error object in a 200 response is a provider error" do
      response = %{"error" => %{"code" => 500, "message" => "Internal", "status" => "INTERNAL"}}

      assert {:error, %Error{kind: :server_error, status: 500}} = complete_with(response)
    end

    test "an unrecognised payload is a provider error" do
      assert {:error, %Error{kind: :unknown} = error} = complete_with(%{"candidates" => []})
      assert Exception.message(error) =~ "Unexpected Gemini response payload"
    end

    test "a body that is not JSON is a provider error" do
      config = config_with_response(%{status: 200, body: "<html>proxy error</html>"})

      assert {:error, %Error{kind: :malformed_reply}} =
               Gemini.complete([Message.user("Hi")], [], config)
    end

    test "rejects cut-off stream with null finishReason and supports extra_body" do
      chunk = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "half"}]}, "finishReason" => nil}
        ]
      }

      Req.Test.stub(:gemini_null_finish, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["cachedContent"] == "cachedContents/123"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: #{Jason.encode!(chunk)}\n\n")
      end)

      config = %{
        api_key: "k",
        model: "models/gemini-3.8-flash",
        extra_body: %{cachedContent: "cachedContents/123"},
        req_options: [plug: {Req.Test, :gemini_null_finish}]
      }

      assert {:error, %Error{kind: :network}} =
               Gemini.stream([Message.user("hi")], [], config, fn _ -> :ok end)
    end

    test "classifies undecodable SSE chunk as :malformed_reply while prioritizing in-band API errors" do
      bad_then_good =
        "data: {not-valid-json\n\n" <>
          "data: #{Jason.encode!(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}]})}\n\n"

      Req.Test.stub(:gemini_malformed_chunk, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, bad_then_good)
      end)

      config = %{
        api_key: "k",
        model: "models/gemini-3.8-flash",
        req_options: [plug: {Req.Test, :gemini_malformed_chunk}]
      }

      assert {:error, %Error{kind: :malformed_reply}} =
               Gemini.stream([Message.user("hi")], [], config, fn _ -> :ok end)

      bad_and_api_error =
        "data: {not-valid-json\n\n" <>
          "data: #{Jason.encode!(%{"error" => %{"code" => 429, "status" => "RESOURCE_EXHAUSTED", "message" => "quota"}})}\n\n"

      Req.Test.stub(:gemini_inband_over_malformed, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, bad_and_api_error)
      end)

      assert {:error, %Error{kind: :rate_limited, status: 429}} =
               Gemini.stream(
                 [Message.user("hi")],
                 [],
                 %{config | req_options: [plug: {Req.Test, :gemini_inband_over_malformed}]},
                 fn _ -> :ok end
               )

      # Non-map JSON (data: null) also yields to a later in-band API error.
      null_then_api_error =
        "data: null\n\n" <>
          "data: #{Jason.encode!(%{"error" => %{"code" => 429, "status" => "RESOURCE_EXHAUSTED", "message" => "quota"}})}\n\n"

      Req.Test.stub(:gemini_null_then_api_error, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, null_then_api_error)
      end)

      assert {:error, %Error{kind: :rate_limited, status: 429}} =
               Gemini.stream(
                 [Message.user("hi")],
                 [],
                 %{config | req_options: [plug: {Req.Test, :gemini_null_then_api_error}]},
                 fn _ -> :ok end
               )

      # Malformed first chunk suppresses stale text deltas so Retry can recover on attempt 2.
      test_pid = self()
      attempts = :atomics.new(1, signed: false)

      good_stream =
        "data: #{Jason.encode!(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "recovered"}]}, "finishReason" => "STOP"}]})}\n\n"

      Req.Test.stub(:gemini_retry_after_malformed, fn conn ->
        attempt = :atomics.add_get(attempts, 1, 1)
        body = if attempt == 1, do: bad_then_good, else: good_stream

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, result} =
               Alloy.stream(
                 "hi",
                 fn chunk -> send(test_pid, {:chunk, chunk}) end,
                 provider:
                   {Gemini,
                    api_key: "k",
                    model: "models/gemini-3.8-flash",
                    req_options: [plug: {Req.Test, :gemini_retry_after_malformed}]},
                 max_retries: 1,
                 retry_backoff_ms: 0
               )

      assert :atomics.get(attempts, 1) == 2
      assert result.text == "recovered"
      assert_received {:chunk, "recovered"}
      refute_received {:chunk, "ok"}
    end
  end

  # A nil finish reason builds an intermediate stream chunk.
  defp gemini_response(parts, finish_reason \\ "STOP", usage \\ %{}) do
    candidate =
      case finish_reason do
        nil -> %{"content" => %{"role" => "model", "parts" => parts}}
        reason -> %{"content" => %{"role" => "model", "parts" => parts}, "finishReason" => reason}
      end

    %{"candidates" => [candidate], "usageMetadata" => usage}
  end

  defp sse_chunk(data) when is_map(data), do: "data: #{Jason.encode!(data)}\n\n"

  defp complete_with(response) do
    config = config_with_response(%{status: 200, body: Jason.encode!(response)})
    Gemini.complete([Message.user("Hi")], [], config)
  end

  defp stream_with(responses) do
    config = config_with_sse_stream(Enum.map(responses, &sse_chunk/1))
    Gemini.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
  end

  describe "history from other providers" do
    test "drops OpenAI-only reasoning and output_item blocks" do
      config = config_that_captures_request()

      messages = [
        Message.user("Hi"),
        Message.assistant_blocks([
          %{type: "reasoning", raw: %{"type" => "reasoning", "id" => "rs_1"}},
          %{type: "output_item", raw: %{"type" => "web_search_call", "id" => "ws_1"}},
          %{type: "text", text: "Hello"}
        ]),
        Message.user("Again")
      ]

      Gemini.complete(messages, [], config)

      assert_received {:request_body, body}
      [_user, model, _again] = Jason.decode!(body)["contents"]
      assert model["parts"] == [%{"text" => "Hello"}]
    end
  end

  describe "malformed candidate, error, and usage hardening" do
    test "stream records sticky :protocol_error on malformed content/parts/candidates and suppresses later text" do
      for {label, bad_chunk} <- [
            {"false content", %{"candidates" => [%{"content" => false}]}},
            {"non-list parts", %{"candidates" => [%{"content" => %{"parts" => "bad"}}]}},
            {"non-map part", %{"candidates" => [%{"content" => %{"parts" => ["bad"]}}]}},
            {"non-map candidate", %{"candidates" => ["bad"]}},
            {"non-list candidates", %{"candidates" => "bad"}},
            {"bad functionCall args",
             %{
               "candidates" => [
                 %{
                   "content" => %{
                     "parts" => [%{"functionCall" => %{"name" => "f", "args" => "x"}}]
                   }
                 }
               ]
             }}
          ] do
        test_pid = self()

        chunks = [
          sse_chunk(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "prefix"}]}}]}),
          sse_chunk(bad_chunk),
          sse_chunk(%{
            "candidates" => [
              %{"content" => %{"parts" => [%{"text" => "suppressed"}]}, "finishReason" => "STOP"}
            ]
          })
        ]

        config = config_with_sse_stream(chunks)

        assert {:error, %Error{kind: :protocol_error}} =
                 Gemini.stream([Message.user("Hi")], [], config, fn text ->
                   send(test_pid, {:chunk, label, text})
                   :ok
                 end)

        assert_received {:chunk, ^label, "prefix"}
        refute_received {:chunk, ^label, "suppressed"}
      end
    end

    test "complete/3 returns :protocol_error on malformed candidate, content, parts, or functionCall" do
      for payload <- [
            %{"candidates" => ["bad"]},
            %{"candidates" => "bad"},
            %{"candidates" => [%{"content" => false, "finishReason" => "STOP"}]},
            %{"candidates" => [%{"content" => %{"parts" => "bad"}, "finishReason" => "STOP"}]},
            %{"candidates" => [%{"content" => %{"parts" => ["bad"]}, "finishReason" => "STOP"}]},
            %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [%{"functionCall" => %{"name" => "f", "args" => 123}}]
                  },
                  "finishReason" => "STOP"
                }
              ]
            }
          ] do
        assert {:error, %Error{kind: :protocol_error}} = complete_with(payload)
      end
    end

    test "ignores error: null and preserves list-wrapped in-band API error classification" do
      assert {:ok, %{stop_reason: :end_turn}} =
               stream_with([
                 %{
                   "error" => nil,
                   "candidates" => [
                     %{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
                   ],
                   "usageMetadata" => %{"promptTokenCount" => "bad", "candidatesTokenCount" => 3}
                 }
               ])

      list_error =
        "data: " <>
          Jason.encode!([
            %{
              "error" => %{
                "code" => 429,
                "status" => "RESOURCE_EXHAUSTED",
                "message" => "Quota exceeded"
              }
            }
          ]) <> "\n\n"

      config =
        config_with_sse_stream([
          sse_chunk(%{"candidates" => [%{"content" => false}]}),
          list_error
        ])

      assert {:error, %Error{kind: :rate_limited, message: "Quota exceeded"}} =
               Gemini.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
    end

    test "malformed SSE JSON error does not leak raw chunk payload into error message" do
      config = config_with_sse_stream(["data: {not json SECRET_GEMINI_CHUNK_PAYLOAD\n\n"])

      assert {:error, %Error{kind: :malformed_reply, message: msg}} =
               Gemini.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert msg =~ "Malformed JSON in Gemini SSE chunk"
      refute msg =~ "SECRET_GEMINI_CHUNK_PAYLOAD"
    end

    test "tolerates non-map usageMetadata and non-integer counts in complete/3 and stream/4" do
      assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0}}} =
               complete_with(%{
                 "candidates" => [
                   %{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
                 ],
                 "usageMetadata" => "not-a-map"
               })

      assert {:ok, %{usage: %{input_tokens: 10, output_tokens: 0}}} =
               stream_with([
                 %{
                   "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
                   "usageMetadata" => "not-a-map"
                 },
                 %{
                   "candidates" => [%{"finishReason" => "STOP"}],
                   "usageMetadata" => %{
                     "promptTokenCount" => 10,
                     "candidatesTokenCount" => "bad"
                   }
                 },
                 %{
                   "usageMetadata" => %{"promptTokenCount" => nil}
                 }
               ])
    end

    test "complete/3 prioritizes explicit API errors over malformed or present candidates" do
      assert {:error, %Error{kind: :auth, status: 403, type: "PERMISSION_DENIED"}} =
               complete_with(%{
                 "candidates" => false,
                 "error" => %{
                   "code" => 403,
                   "status" => "PERMISSION_DENIED",
                   "message" => "denied"
                 }
               })

      assert {:error, %Error{kind: :rate_limited, status: 429}} =
               complete_with(%{
                 "candidates" => [
                   %{
                     "content" => %{"parts" => [%{"text" => "partial"}]},
                     "finishReason" => "STOP"
                   }
                 ],
                 "error" => %{
                   "code" => 429,
                   "status" => "RESOURCE_EXHAUSTED",
                   "message" => "Quota exceeded"
                 }
               })
    end
  end

  defp config_with_response(response) do
    %{
      api_key: "gem-test-key",
      model: "gemini-2.5-flash",
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
      api_key: "gem-test-key",
      model: "gemini-2.5-flash",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_info, %{request_path: conn.request_path}})
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(gemini_response([%{"text" => "ok"}])))
      end)
    end)
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "gem-test-key",
      model: "gemini-2.5-flash",
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
end
