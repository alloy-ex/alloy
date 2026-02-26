defmodule Alloy.Provider.GoogleTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Google
  alias Alloy.Message

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [%{"text" => "Hello!"}],
                    "role" => "model"
                  },
                  "finishReason" => "STOP"
                }
              ],
              "usageMetadata" => %{
                "promptTokenCount" => 10,
                "candidatesTokenCount" => 5,
                "totalTokenCount" => 15
              }
            })
        })

      messages = [Message.user("Hi")]

      assert {:ok, result} = Google.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with function call response" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{
                        "functionCall" => %{
                          "name" => "read",
                          "args" => %{"file_path" => "mix.exs"}
                        }
                      }
                    ],
                    "role" => "model"
                  },
                  "finishReason" => "STOP"
                }
              ],
              "usageMetadata" => %{
                "promptTokenCount" => 20,
                "candidatesTokenCount" => 15,
                "totalTokenCount" => 35
              }
            })
        })

      messages = [Message.user("Read mix.exs")]
      tool_defs = [%{name: "read", description: "Read a file", input_schema: %{}}]

      assert {:ok, result} = Google.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.input == %{"file_path" => "mix.exs"}
      assert tool_call.id != nil
    end

    test "handles text + function call in same response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{"text" => "Let me read that."},
                      %{
                        "functionCall" => %{
                          "name" => "read",
                          "args" => %{"file_path" => "mix.exs"}
                        }
                      }
                    ],
                    "role" => "model"
                  },
                  "finishReason" => "STOP"
                }
              ],
              "usageMetadata" => %{
                "promptTokenCount" => 20,
                "candidatesTokenCount" => 15,
                "totalTokenCount" => 35
              }
            })
        })

      assert {:ok, result} = Google.complete([Message.user("Read")], [], config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      assert Enum.find(blocks, &(&1.type == "text"))
      assert Enum.find(blocks, &(&1.type == "tool_use"))
    end
  end

  describe "complete/3 message formatting" do
    test "formats user and model messages" do
      config = config_that_captures_request()

      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert length(decoded["contents"]) == 3
      assert hd(decoded["contents"])["role"] == "user"
      assert Enum.at(decoded["contents"], 1)["role"] == "model"
    end

    test "includes system instruction" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Google.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["systemInstruction"]["parts"] == [%{"text" => "You are helpful."}]
    end

    test "includes tool definitions as function declarations" do
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

      Google.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [%{"functionDeclarations" => [decl]}] = decoded["tools"]
      assert decl["name"] == "read"
      assert decl["description"] == "Read a file"
    end

    test "unknown block type in user message formats to text notice instead of crashing" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [%{type: "unknown_future_type", some_data: "value"}]
        }
      ]

      # Should not raise FunctionClauseError
      result = Google.complete(messages, [], config)
      assert match?({:ok, _}, result)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [user_content] = decoded["contents"]
      [part] = user_content["parts"]
      assert is_binary(part["text"])
      assert String.contains?(part["text"], "Unhandled block type")
    end

    test "formats tool results as functionResponse parts" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read mix.exs"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "call_1", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("call_1", "file contents here")
        ])
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # Tool results should be a "user" message with functionResponse parts
      tool_msg = List.last(decoded["contents"])
      assert tool_msg["role"] == "user"
      [part] = tool_msg["parts"]
      assert part["functionResponse"]["name"] == "read"
      assert part["functionResponse"]["response"]["content"] == "file contents here"
    end
  end

  describe "complete/3 multimodal formatting" do
    test "image block in user message formats to inlineData" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [
            %{type: "text", text: "Describe this image."},
            Message.image("image/jpeg", "base64img==")
          ]
        }
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_content = hd(decoded["contents"])
      assert user_content["role"] == "user"

      img_part = Enum.find(user_content["parts"], &Map.has_key?(&1, "inlineData"))
      assert img_part != nil
      assert img_part["inlineData"]["mimeType"] == "image/jpeg"
      assert img_part["inlineData"]["data"] == "base64img=="
    end

    test "audio block in user message formats to inlineData" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.audio("audio/mp3", "base64audio==")]
        }
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [user_content] = decoded["contents"]
      [part] = user_content["parts"]
      assert part["inlineData"]["mimeType"] == "audio/mp3"
      assert part["inlineData"]["data"] == "base64audio=="
    end

    test "document block in user message formats to fileData" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.document("application/pdf", "gs://bucket/report.pdf")]
        }
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [user_content] = decoded["contents"]
      [part] = user_content["parts"]
      assert part["fileData"]["mimeType"] == "application/pdf"
      assert part["fileData"]["fileUri"] == "gs://bucket/report.pdf"
    end

    test "video block in user message formats to inlineData" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.video("video/mp4", "base64video==")]
        }
      ]

      Google.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [user_content] = decoded["contents"]
      [part] = user_content["parts"]
      assert part["inlineData"]["mimeType"] == "video/mp4"
      assert part["inlineData"]["data"] == "base64video=="
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = Google.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "error" => %{
                "code" => 400,
                "message" => "Invalid model",
                "status" => "INVALID_ARGUMENT"
              }
            })
        })

      assert {:error, reason} = Google.complete([Message.user("Hi")], [], config)
      assert reason =~ "INVALID_ARGUMENT"
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "test-api-key",
      model: "gemini-2.5-flash",
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
      api_key: "test-api-key",
      model: "gemini-2.5-flash",
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
            "candidates" => [
              %{
                "content" => %{
                  "parts" => [%{"text" => "ok"}],
                  "role" => "model"
                },
                "finishReason" => "STOP"
              }
            ],
            "usageMetadata" => %{
              "promptTokenCount" => 1,
              "candidatesTokenCount" => 1,
              "totalTokenCount" => 2
            }
          })
        )
      end)
    end)
  end
end
