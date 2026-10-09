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

  require Logger

  @type sse_event :: %{event: String.t() | nil, data: String.t()}

  @doc """
  Process a raw chunk of bytes against a buffer.

  `buffer` is the `remaining_buffer` returned by the previous call (`""` for
  the first chunk). Returns `{complete_events, remaining_buffer}` where each
  event is a map with `:event` (may be nil) and `:data` keys.
  """
  @spec process_chunk(String.t(), String.t()) :: {[sse_event()], String.t()}
  def process_chunk(buffer, chunk) do
    # Normalize CRLF to LF so event boundaries are found with any server or
    # proxy line-ending style. Only the incoming chunk is normalized, after
    # dropping a \r left dangling at the end of the buffer when the chunk
    # starts with the \n of the same pair.
    buffer = drop_split_carriage_return(buffer, chunk)
    combined = buffer <> String.replace(chunk, "\r\n", "\n")

    # The buffer never holds a complete event, so a boundary can only end
    # in the new bytes. Scanning from one byte before them (a boundary may
    # straddle the two) keeps the work per chunk proportional to the chunk,
    # not to the event being accumulated.
    scan_from = max(byte_size(buffer) - 1, 0)

    case :binary.match(combined, "\n\n", scope: {scan_from, byte_size(combined) - scan_from}) do
      :nomatch ->
        {[], combined}

      {boundary, 2} ->
        first = binary_part(combined, 0, boundary)
        rest = binary_part(combined, boundary + 2, byte_size(combined) - boundary - 2)
        {raw_events, remaining} = split_events(rest)
        {parse_events([first | raw_events]), remaining}
    end
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

      acc =
        Enum.reduce(events, acc, fn event, acc ->
          try do
            handle_event.(acc, event)
          rescue
            e ->
              Logger.warning(
                "SSE event handler crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
              )

              acc
          end
        end)

      resp = put_in(resp.private[:sse_acc], acc)
      {:cont, {req, resp}}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp drop_split_carriage_return(buffer, "\n" <> _chunk) when byte_size(buffer) > 0 do
    case :binary.last(buffer) do
      ?\r -> binary_part(buffer, 0, byte_size(buffer) - 1)
      _other -> buffer
    end
  end

  defp drop_split_carriage_return(buffer, _chunk), do: buffer

  defp parse_events(raw_events) do
    raw_events
    |> Enum.map(&parse_event/1)
    |> Enum.reject(&is_nil/1)
  end

  # Split on double-newline SSE event boundaries.
  # Returns {complete_event_strings, remaining_buffer}.
  defp split_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [only] ->
        {[], only}

      _ ->
        {complete, [remainder]} = Enum.split(parts, -1)
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
