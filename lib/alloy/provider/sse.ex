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

  alias Alloy.Provider.Error

  require Logger

  @type sse_event :: %{event: String.t() | nil, data: String.t()}

  @max_error_body_bytes 65_536

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
          ({:data, String.t()}, {term(), term()} -> {:cont | :halt, {term(), term()}})
  def req_stream_handler(initial_acc, handle_event) do
    fn {:data, chunk}, {req, resp} ->
      if Map.get(resp, :status, 200) == 200 do
        acc =
          resp.private
          |> Map.get(:sse_acc, initial_acc)
          |> apply_chunk(chunk, handle_event)

        resp = put_in(resp.private[:sse_acc], acc)

        if match?(%{sse_handler_error: %Error{}}, acc),
          do: {:halt, {req, resp}},
          else: {:cont, {req, resp}}
      else
        append_error_chunk(chunk, req, resp)
      end
    end
  end

  @doc false
  # Accumulates non-200 SSE response chunks up to 64 KiB and halts early if a
  # misbehaving endpoint streams an unbounded error body.
  @spec append_error_chunk(binary(), term(), map()) :: {:cont | :halt, {term(), map()}}
  def append_error_chunk(chunk, req, resp) do
    existing_size = Map.get(resp.private, :sse_error_body_size, 0)
    remaining = @max_error_body_bytes - existing_size

    if remaining <= 0 do
      {:halt, {req, resp}}
    else
      kept =
        if byte_size(chunk) <= remaining,
          do: chunk,
          else: binary_part(chunk, 0, remaining)

      error_chunks = Map.get(resp.private, :sse_error_body, [])
      next_size = existing_size + byte_size(kept)

      resp =
        resp
        |> put_in([Access.key!(:private), :sse_error_body], [error_chunks, kept])
        |> put_in([Access.key!(:private), :sse_error_body_size], next_size)

      if next_size >= @max_error_body_bytes,
        do: {:halt, {req, resp}},
        else: {:cont, {req, resp}}
    end
  end

  @doc false
  @spec apply_chunk(map(), String.t(), (map(), sse_event() -> map())) :: map()
  def apply_chunk(acc, chunk, handle_event) do
    {events, remaining} = process_chunk(acc.buffer, chunk)
    acc = %{acc | buffer: remaining}
    Enum.reduce(events, acc, &invoke_event_handler(&2, &1, handle_event))
  end

  @doc false
  @spec apply_chunk_until(map(), String.t(), (map(), sse_event() -> map()), integer()) ::
          {:ok, map()} | {:timeout, map()}
  def apply_chunk_until(acc, chunk, handle_event, deadline) when is_integer(deadline) do
    {events, remaining} = process_chunk(acc.buffer, chunk)
    acc = %{acc | buffer: remaining}

    Enum.reduce_while(events, {:ok, acc}, fn event, {:ok, acc} ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:timeout, acc}}
      else
        {:cont, {:ok, invoke_event_handler(acc, event, handle_event)}}
      end
    end)
  end

  defp invoke_event_handler(%{sse_handler_error: %Error{}} = acc, _event, _handle_event),
    do: acc

  defp invoke_event_handler(acc, event, handle_event) do
    handle_event.(acc, event)
  rescue
    # Rescues parser exceptions only; user callbacks are already rescued in Retry.notify/5.
    e ->
      # Log only the exception module and argument-stripped stacktrace so
      # term-inspecting exceptions (MatchError, KeyError, CaseClauseError, etc.)
      # cannot leak streamed model output or accumulator state into logs/errors.
      # Use :unknown (non-retryable) so local parser crashes do not burn retries.
      exception_name = inspect(e.__struct__)
      sanitized_trace = Alloy.OwnedWorker.sanitize_stacktrace(__STACKTRACE__)

      Logger.warning(
        "SSE event handler crashed (#{exception_name})\n#{Exception.format_stacktrace(sanitized_trace)}"
      )

      Map.put(acc, :sse_handler_error, %Error{
        kind: :unknown,
        message: "SSE event handler failed: #{exception_name}"
      })
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

    # Per SSE spec: if multiple event: lines appear, the last one wins, and
    # at most one leading U+0020 space after the colon is stripped.
    event_type =
      Enum.reduce(lines, nil, fn
        "event:" <> type, _acc -> strip_leading_space(type)
        _line, acc -> acc
      end)

    # Per SSE spec: multiple data: lines are concatenated with \n between them.
    # Comment lines (starting with :) are ignored — they are used as keepalives.
    # Space after colon is optional — strip at most one leading space.
    data_parts =
      Enum.flat_map(lines, fn
        "data:" <> rest -> [strip_leading_space(rest)]
        _ -> []
      end)

    if data_parts == [] do
      nil
    else
      %{event: event_type, data: Enum.join(data_parts, "\n")}
    end
  end

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(value), do: value
end
