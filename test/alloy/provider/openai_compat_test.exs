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
