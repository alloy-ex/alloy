defmodule Alloy.Provider.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.OpenRouter
  alias Alloy.Message

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "gen-01",
              "object" => "chat.completion",
              "model" => "anthropic/claude-haiku-4-5-20251001",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => "Hello via OpenRouter!"
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

      assert {:ok, result} = OpenRouter.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello via OpenRouter!"
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
              "id" => "gen-02",
              "object" => "chat.completion",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{
                    "role" => "assistant",
                    "content" => nil,
                    "tool_calls" => [
                      %{
                        "id" => "call_abc123",
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

      assert {:ok, result} = OpenRouter.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "call_abc123"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "sends required OpenRouter headers" do
      config = config_that_captures_request()

      OpenRouter.complete([Message.user("Hi")], [], config)

      assert_received {:request_headers, headers}

      # Must have authorization
      auth = Enum.find(headers, fn {k, _v} -> k == "authorization" end)
      assert {"authorization", "Bearer or-test-key"} = auth

      # Must have HTTP-Referer for OpenRouter attribution
      referer = Enum.find(headers, fn {k, _v} -> k == "http-referer" end)
      assert referer != nil

      # Must have X-Title for OpenRouter attribution
      title = Enum.find(headers, fn {k, _v} -> k == "x-title" end)
      assert title != nil
    end

    test "uses custom app_name and app_url in headers" do
      config =
        config_that_captures_request()
        |> Map.put(:app_name, "My Cool App")
        |> Map.put(:app_url, "https://mycoolapp.com")

      OpenRouter.complete([Message.user("Hi")], [], config)

      assert_received {:request_headers, headers}

      referer = Enum.find(headers, fn {k, _v} -> k == "http-referer" end)
      assert {"http-referer", "https://mycoolapp.com"} = referer

      title = Enum.find(headers, fn {k, _v} -> k == "x-title" end)
      assert {"x-title", "My Cool App"} = title
    end

    test "uses correct API URL path" do
      config = config_that_captures_request()

      OpenRouter.complete([Message.user("Hi")], [], config)

      assert_received {:request_url, url}
      assert url =~ "/api/v1/chat/completions"
    end

    test "includes system prompt as system message" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      OpenRouter.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      system_msg = hd(decoded["messages"])
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful."
    end

    test "includes tool definitions in request" do
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

      OpenRouter.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read"
    end

    test "formats tool_result messages as role:tool" do
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

      OpenRouter.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      tool_msg = Enum.find(decoded["messages"], &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "call_abc"
      assert tool_msg["content"] == "file contents here"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = OpenRouter.complete([Message.user("Hi")], [], config)
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

      assert {:error, reason} = OpenRouter.complete([Message.user("Hi")], [], config)
      assert reason =~ "auth_error"
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

      assert {:error, reason} = OpenRouter.complete([Message.user("Hi")], [], config)
      assert reason =~ "rate_limit"
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "or-test-key",
      model: "anthropic/claude-haiku-4-5-20251001",
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
      api_key: "or-test-key",
      model: "anthropic/claude-haiku-4-5-20251001",
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
            "id" => "gen-capture",
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
end
