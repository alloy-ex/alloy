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
      assert tool["parameters"]["properties"]["file_path"]["type"] == "string"
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
      assert function_response["response"] == %{"content" => "file contents here"}
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
                   finish_reason: reason,
                   finish_message: "Blocked.",
                   safety_ratings: [rating]
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
                 block_reason: "PROHIBITED_CONTENT",
                 safety_ratings: [rating]
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

      assert {:error, %Error{kind: :unknown}} = Gemini.complete([Message.user("Hi")], [], config)
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
