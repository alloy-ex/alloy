defmodule Alloy.Provider.SSETest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.SSE

  # ── process_chunk/2 ──────────────────────────────────────────────────

  describe "process_chunk/2" do
    test "returns one event from a complete single event" do
      chunk = "event: message_start\ndata: {\"type\":\"start\"}\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: "message_start", data: "{\"type\":\"start\"}"}] = events
      assert buffer == ""
    end

    test "buffers partial data and returns no events" do
      chunk = "event: delta\ndata: {\"partial\":"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert events == []
      assert buffer == "event: delta\ndata: {\"partial\":"
    end

    test "completes a buffered event across two calls" do
      {events1, buffer1} = SSE.process_chunk("", "event: delta\ndata: {\"x\":")
      assert events1 == []

      {events2, buffer2} = SSE.process_chunk(buffer1, "1}\n\n")
      assert [%{event: "delta", data: "{\"x\":1}"}] = events2
      assert buffer2 == ""
    end

    test "returns multiple events from one chunk" do
      chunk =
        "event: start\ndata: {\"a\":1}\n\n" <>
          "event: delta\ndata: {\"b\":2}\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [
               %{event: "start", data: "{\"a\":1}"},
               %{event: "delta", data: "{\"b\":2}"}
             ] = events

      assert buffer == ""
    end

    test "handles data-only events (no event: field)" do
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: nil, data: "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"}] = events
      assert buffer == ""
    end

    test "handles [DONE] sentinel as raw data" do
      chunk = "data: [DONE]\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: nil, data: "[DONE]"}] = events
      assert buffer == ""
    end

    test "handles empty chunk" do
      {events, buffer} = SSE.process_chunk("", "")

      assert events == []
      assert buffer == ""
    end

    test "handles chunk ending exactly on boundary" do
      chunk = "event: stop\ndata: {\"done\":true}\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert length(events) == 1
      assert buffer == ""
    end

    test "preserves remaining buffer after complete events" do
      chunk = "event: a\ndata: {\"x\":1}\n\nevent: b\ndata: {\"y\":"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: "a", data: "{\"x\":1}"}] = events
      assert buffer == "event: b\ndata: {\"y\":"
    end

    test "normalizes CRLF line endings to LF" do
      chunk = "event: delta\r\ndata: {\"a\":1}\r\n\r\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: "delta", data: "{\"a\":1}"}] = events
      assert buffer == ""
    end

    test "concatenates multiple data: lines within one event" do
      # SSE spec: multiple data: lines are joined with \n between them.
      # Note: no leading space — each line must start with "data: ".
      chunk = "data: {\"a\":\ndata: 1}\n\n"

      {events, _buffer} = SSE.process_chunk("", chunk)

      assert [%{event: nil, data: "{\"a\":\n1}"}] = events
    end

    test "ignores SSE comment lines (colon prefix)" do
      chunk = ": keep-alive\ndata: {\"ok\":true}\n\n"

      {events, _buffer} = SSE.process_chunk("", chunk)

      assert [%{event: nil, data: "{\"ok\":true}"}] = events
    end

    test "handles data: field with no space after colon (Ollama format)" do
      # SSE spec: the space after the colon is optional — some providers
      # like Ollama emit data:{...} without a space.
      chunk = "data:{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"

      {events, buffer} = SSE.process_chunk("", chunk)

      assert [%{event: nil, data: "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"}] = events
      assert buffer == ""
    end
  end

  # ── req_stream_handler/2 ─────────────────────────────────────────────

  describe "req_stream_handler/2" do
    test "builds a function that processes SSE chunks into accumulator" do
      initial_acc = %{events: [], buffer: ""}

      handle_event = fn acc, event ->
        %{acc | events: acc.events ++ [event]}
      end

      handler = SSE.req_stream_handler(initial_acc, handle_event)

      # Simulate Req's into: callback pattern
      req = %{}
      resp = %{private: %{}}

      {:cont, {_req, resp}} =
        handler.({:data, "event: test\ndata: {\"ok\":true}\n\n"}, {req, resp})

      sse_acc = resp.private.sse_acc
      assert length(sse_acc.events) == 1
      assert hd(sse_acc.events).event == "test"
    end

    test "accumulates across multiple chunks" do
      initial_acc = %{events: [], buffer: ""}

      handle_event = fn acc, event ->
        %{acc | events: acc.events ++ [event]}
      end

      handler = SSE.req_stream_handler(initial_acc, handle_event)

      req = %{}
      resp = %{private: %{}}

      # Chunk 1: partial
      {:cont, {req, resp}} =
        handler.({:data, "event: a\ndata: {\"x\":"}, {req, resp})

      assert resp.private.sse_acc.events == []

      # Chunk 2: completes first event + starts second
      {:cont, {_req, resp}} =
        handler.({:data, "1}\n\nevent: b\ndata: {\"y\":2}\n\n"}, {req, resp})

      assert length(resp.private.sse_acc.events) == 2
    end
  end
end
