defmodule Alloy.Provider.OpenAIStreamTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.OpenAIStream
  alias Alloy.Message

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

    test "length maps to :end_turn" do
      chunks = [sse_chunk(text_delta("hi")), sse_chunk(finish_chunk("length")), sse_done()]
      {_, result} = collect_stream(chunks, test_name: :finish_length)
      assert {:ok, %{stop_reason: :end_turn}} = result
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

    test "returns ok when tool call has malformed JSON arguments (network truncation)" do
      chunks = [
        sse_chunk(tool_call_start(0, "call_bad", "read")),
        sse_chunk(tool_call_args(0, "{\"file_path\": \"mix")),
        # Truncated — no closing brace
        sse_chunk(finish_chunk("tool_calls")),
        sse_done()
      ]

      {_collected, result} = collect_stream(chunks, test_name: :tool_malformed_args)

      # Should return an error tuple, NOT raise an exception
      assert {:error, _reason} = result
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
