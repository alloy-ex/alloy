defmodule Alloy.Provider.SSE do
  @moduledoc """
  Shared SSE (Server-Sent Events) framing utilities.

  Handles the transport-level concerns that are identical across all
  providers using SSE streaming: byte buffering, event boundary
  splitting, and field extraction.

  Provider-specific event handling is NOT in this module — each provider
  (or shared parser like `Alloy.Provider.OpenAIStream`) pattern-matches
  on the parsed events returned here.
  """

  @type sse_event :: %{event: String.t() | nil, data: String.t()}

  @doc """
  Process a raw chunk of bytes against a buffer.

  Returns `{complete_events, remaining_buffer}` where each event
  is a map with `:event` (may be nil) and `:data` keys.
  """
  @spec process_chunk(String.t(), String.t()) :: {[sse_event()], String.t()}
  def process_chunk(buffer, chunk) do
    # Normalize CRLF to LF so split_events works correctly with any
    # server or proxy line-ending style.
    combined = String.replace(buffer <> chunk, "\r\n", "\n")
    {raw_events, remaining} = split_events(combined)

    events =
      raw_events
      |> Enum.map(&parse_event/1)
      |> Enum.reject(&is_nil/1)

    {events, remaining}
  end

  @doc """
  Build a Req `into:` stream handler that accumulates SSE events.

  The `handle_event` function receives `(accumulator, sse_event)` and
  returns the updated accumulator. The accumulator must contain a
  `:buffer` key (string) for SSE framing state.

  The accumulator is stored in `resp.private.sse_acc`.
  """
  @spec req_stream_handler(map(), (map(), sse_event() -> map())) ::
          ({:data, String.t()}, {term(), term()} -> {:cont, {term(), term()}})
  def req_stream_handler(initial_acc, handle_event) do
    fn {:data, chunk}, {req, resp} ->
      acc = Map.get(resp.private, :sse_acc, initial_acc)
      {events, remaining} = process_chunk(acc.buffer, chunk)
      acc = %{acc | buffer: remaining}

      acc = Enum.reduce(events, acc, fn event, acc -> handle_event.(acc, event) end)

      resp = put_in(resp.private[:sse_acc], acc)
      {:cont, {req, resp}}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Split on double-newline SSE event boundaries.
  # Returns {complete_event_strings, remaining_buffer}.
  defp split_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [only] ->
        {[], only}

      _ ->
        {complete, [remainder]} = Enum.split(parts, length(parts) - 1)
        {complete, remainder}
    end
  end

  # Parse a raw event string into %{event: ..., data: ...}.
  # Returns nil if there is no data field.
  defp parse_event(event_str) do
    lines = String.split(event_str, "\n")

    event_type =
      Enum.find_value(lines, fn
        # SSE spec: space after colon is optional — strip at most one leading space.
        "event:" <> type -> String.trim_leading(type, " ")
        _ -> nil
      end)

    # Per SSE spec: multiple data: lines are concatenated with \n between them.
    # Comment lines (starting with :) are ignored — they are used as keepalives.
    # Space after colon is optional — strip at most one leading space.
    data_parts =
      Enum.flat_map(lines, fn
        "data:" <> rest -> [String.trim_leading(rest, " ")]
        _ -> []
      end)

    if data_parts == [] do
      nil
    else
      %{event: event_type, data: Enum.join(data_parts, "\n")}
    end
  end
end
