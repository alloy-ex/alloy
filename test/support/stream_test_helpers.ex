defmodule Alloy.StreamTestHelpers do
  @moduledoc """
  Shared helpers for SSE streaming tests across all OpenAI-format providers.

  Import this module in provider test files that test `stream/4`:

      import Alloy.StreamTestHelpers

  Then call `Req.Test.stub(__MODULE__, sse_chunks_plug(chunks))` to wire up
  the plug, keeping provider-specific config (api_key, model) local.
  """

  # ── SSE Event Builders ────────────────────────────────────────────────────

  @doc "Build an SSE data line containing a text delta chunk."
  def sse_text_delta(text) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]})}\n\n"
  end

  @doc "Build an SSE data line that starts a tool call with the given index, id, and name."
  def sse_tool_call_start(index, id, name) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => index, "id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => ""}}]}, "finish_reason" => nil}]})}\n\n"
  end

  @doc "Build an SSE data line that appends arguments to an in-progress tool call."
  def sse_tool_call_args(index, args) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => args}}]}, "finish_reason" => nil}]})}\n\n"
  end

  @doc "Build an SSE data line that signals stream completion with the given finish reason."
  def sse_finish(reason) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
  end

  @doc "Build an SSE data line carrying usage token counts (OpenAI stream_options format)."
  def sse_usage(prompt, completion) do
    "data: #{Jason.encode!(%{"id" => "test", "choices" => [], "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => completion}})}\n\n"
  end

  # ── Plug Builders ─────────────────────────────────────────────────────────

  @doc """
  Returns a `Req.Test` plug that streams `chunks` as a chunked HTTP response.

  Use with `Req.Test.stub/2`:

      Req.Test.stub(__MODULE__, sse_chunks_plug(chunks))
  """
  def sse_chunks_plug(chunks) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end
  end

  @doc """
  Returns a `Req.Test` plug that captures the request body (sent to `test_pid`
  as `{:request_body, body}`) before streaming `chunks`.

  Use with `Req.Test.stub/2`:

      Req.Test.stub(__MODULE__, sse_chunks_capturing_plug(self(), chunks))
  """
  def sse_chunks_capturing_plug(test_pid, chunks) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, body})

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end
  end

  @doc """
  Returns a `Req.Test` plug that sends a chunked error response.

  Simulates what happens when an API returns a non-200 status during streaming:
  the `into:` handler consumes the body, so `resp.body` is empty and the error
  must be recovered from the SSE buffer.

  Use with `Req.Test.stub/2`:

      Req.Test.stub(__MODULE__, sse_error_plug(400, error_json))
  """
  def sse_error_plug(status, body) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, status)
      {:ok, conn} = Plug.Conn.chunk(conn, body)
      conn
    end
  end

  # ── Chunk Collection ──────────────────────────────────────────────────────

  @doc """
  Runs `fun.(on_chunk)` and collects all `{:chunk, text}` messages sent to the
  current process during the call. Returns the list of chunk strings in order.
  """
  def collect_chunks(fun) do
    test_pid = self()
    on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end
    fun.(on_chunk)
    collect_messages([])
  end

  @doc false
  def collect_messages(acc) do
    receive do
      {:chunk, chunk} -> collect_messages([chunk | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
