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
