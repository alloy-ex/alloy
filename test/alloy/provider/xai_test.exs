defmodule Alloy.Provider.XAITest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.XAI

  describe "complete/3" do
    test "delegates to OpenAI provider with xAI API URL" do
      test_pid = self()

      config = %{
        api_key: "xai-test-key",
        model: "grok-4",
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry: false
        ]
      }

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.host, conn.request_path})

        body =
          Jason.encode!(%{
            id: "resp_test",
            output: [
              %{
                type: "message",
                role: "assistant",
                content: [%{type: "output_text", text: "Hello from Grok!"}]
              }
            ],
            usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
          })

        Plug.Conn.send_resp(conn, 200, body)
      end)

      assert {:ok, result} = XAI.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "Hello from Grok!"

      assert_received {:request, host, path}
      assert host == "api.x.ai"
      assert path == "/v1/responses"
    end

    test "preserves explicit api_url if provided" do
      test_pid = self()

      config = %{
        api_key: "xai-test-key",
        model: "grok-4",
        api_url: "https://custom.xai.endpoint",
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry: false
        ]
      }

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_host, conn.host})

        body =
          Jason.encode!(%{
            id: "resp_test",
            output: [
              %{
                type: "message",
                role: "assistant",
                content: [%{type: "output_text", text: "Custom endpoint"}]
              }
            ],
            usage: %{input_tokens: 5, output_tokens: 3, total_tokens: 8}
          })

        Plug.Conn.send_resp(conn, 200, body)
      end)

      assert {:ok, _result} = XAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_host, host}
      assert host == "custom.xai.endpoint"
    end
  end

  describe "stream/4" do
    test "delegates streaming to OpenAI provider with xAI URL" do
      config = %{
        api_key: "xai-test-key",
        model: "grok-4",
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry: false
        ]
      }

      Req.Test.stub(__MODULE__, fn conn ->
        sse_body =
          [
            sse_event(%{
              type: "response.output_item.added",
              output_index: 0,
              item: %{type: "message", role: "assistant"}
            }),
            sse_event(%{
              type: "response.content_part.added",
              output_index: 0,
              content_index: 0,
              part: %{type: "output_text", text: ""}
            }),
            sse_event(%{
              type: "response.output_text.delta",
              output_index: 0,
              content_index: 0,
              delta: "Grok "
            }),
            sse_event(%{
              type: "response.output_text.delta",
              output_index: 0,
              content_index: 0,
              delta: "says hi"
            }),
            sse_event(%{
              type: "response.completed",
              response: %{
                id: "resp_stream",
                output: [
                  %{
                    type: "message",
                    role: "assistant",
                    content: [%{type: "output_text", text: "Grok says hi"}]
                  }
                ],
                usage: %{input_tokens: 8, output_tokens: 4, total_tokens: 12}
              }
            })
          ]
          |> Enum.join("")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      assert {:ok, result} =
               XAI.stream([Message.user("Hi")], [], config, fn chunk ->
                 send(self(), {:chunk, chunk})
               end)

      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "Grok says hi"
    end
  end

  defp sse_event(data) do
    "data: #{Jason.encode!(data)}\n\n"
  end
end
