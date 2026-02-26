defmodule Alloy.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Anthropic
  alias Alloy.Message

  # We test by intercepting the HTTP call via a custom Req adapter
  # that returns canned responses.

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            })
        })

      messages = [Message.user("Hi")]

      assert {:ok, result} = Anthropic.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with tool_use response" do
    test "returns normalized tool_use response with tool calls" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_02",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read that file."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      messages = [Message.user("Read mix.exs")]
      tool_defs = [%{name: "read", description: "Read a file", input_schema: %{}}]

      assert {:ok, result} = Anthropic.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages
      assert length(blocks) == 2

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      # This will "fail" because our mock returns the request body, not a real response
      # But we can verify the request format
      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert length(decoded["messages"]) == 3
      assert hd(decoded["messages"])["role"] == "user"
      assert hd(decoded["messages"])["content"] == "Hello"
    end

    test "includes system prompt in request" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["system"] == "You are helpful."
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

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["name"] == "read"
      assert tool["description"] == "Read a file"
      assert tool["input_schema"]["type"] == "object"
    end

    test "formats tool_result messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read mix.exs"),
        Message.assistant_blocks([
          %{type: "text", text: "Reading..."},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("toolu_01", "file contents here")
        ])
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # tool_results become a user message with content blocks
      tool_result_msg = List.last(decoded["messages"])
      assert tool_result_msg["role"] == "user"
      assert is_list(tool_result_msg["content"])
      assert hd(tool_result_msg["content"])["type"] == "tool_result"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "type" => "invalid_request_error",
                "message" => "messages: at least one message is required"
              }
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end

    test "returns error on overloaded response" do
      config =
        config_with_response(%{
          status: 529,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "overloaded"
    end
  end

  describe "complete/3 with cache control" do
    test "includes cache usage in response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_03",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Cached!"}],
              "stop_reason" => "end_turn",
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 5,
                "cache_creation_input_tokens" => 100,
                "cache_read_input_tokens" => 50
              }
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.usage.cache_creation_input_tokens == 100
      assert result.usage.cache_read_input_tokens == 50
    end
  end

  describe "complete/3 retry behavior" do
    test "retries on 429 rate limit and eventually succeeds" do
      calls = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        n = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if n == 0 do
          Plug.Conn.send_resp(conn, 429, "Too Many Requests")
        else
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "id" => "msg_retry",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello after retry!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
            })
          )
        end
      end)

      config = %{
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-5-20250514",
        max_tokens: 4096,
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry_delay: 1
        ]
      }

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert :counters.get(calls, 1) == 2
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-5-20250514",
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
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-5-20250514",
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
            "id" => "msg_capture",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)
    end)
  end
end
