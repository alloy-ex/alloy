defmodule Alloy.Provider.HTTP do
  @moduledoc false
  # Request plumbing shared by the built-in HTTP providers: the JSON POST,
  # Req's own retries switched off (Alloy.Provider.Retry owns retries and the
  # turn deadline), and every failure turned into an Alloy.Provider.Error.

  alias Alloy.OwnedWorker
  alias Alloy.Provider.{Error, SSE}

  @type headers :: [{String.t(), String.t()}]

  @doc """
  POSTs `body` as JSON. Returns the response body of a 200 response (raw binary
  by default unless `:decode_body` is overridden in `req_options`; built-in
  providers decode via `Alloy.Provider.decode_body/1`).

  `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  bound even if the server trickles bytes slowly. Passing `:deadline` requires
  `Alloy.TaskSupervisor` to be running (started by the `:alloy` application).
  """
  @spec post_json(String.t(), headers(), map(), keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_json(url, headers, body, req_options, opts \\ []) do
    case Keyword.get(opts, :deadline) do
      deadline when is_integer(deadline) ->
        post_json_with_deadline(url, headers, body, req_options, deadline)

      _nil ->
        decode_post_result(request(url, headers, body, req_options))
    end
  end

  @doc """
  POSTs `body` as JSON and feeds the SSE response through `handle_event`
  (see `Alloy.Provider.SSE.req_stream_handler/2`). Returns the final
  accumulator of a 200 response.

  `req_options` may carry extra Req options such as `params:`.
  `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  bound across stalled and trickling streams while running `handle_event` in
  the caller's process (requires `Alloy.TaskSupervisor` to be running).
  """
  @spec stream_sse(
          String.t(),
          headers(),
          map(),
          map(),
          (map(), SSE.sse_event() -> map()),
          keyword(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def stream_sse(url, headers, body, initial_acc, handle_event, req_options, opts \\ []) do
    case Keyword.get(opts, :deadline) do
      deadline when is_integer(deadline) ->
        stream_sse_with_deadline(
          url,
          headers,
          body,
          initial_acc,
          handle_event,
          req_options,
          deadline
        )

      _nil ->
        handler = SSE.req_stream_handler(initial_acc, handle_event)

        decode_sse_result(
          request(url, headers, body, [into: handler] ++ req_options),
          initial_acc
        )
    end
  end

  @doc false
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec stringify_extra_body(term()) :: map()
  def stringify_extra_body(extra_body) when is_map(extra_body) do
    Map.new(extra_body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def stringify_extra_body(_), do: %{}

  @doc false
  @spec join_url(String.t(), String.t()) :: String.t()
  def join_url(base_url, "") when is_binary(base_url), do: base_url

  def join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc false
  @spec cache_adjusted_usage(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: map()
  def cache_adjusted_usage(total_input, output, cache_read, cache_write) do
    %{
      input_tokens: max(total_input - cache_read - cache_write, 0),
      output_tokens: output,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_write
    }
  end

  defp post_json_with_deadline(url, headers, body, req_options, deadline) do
    encoded_body = Jason.encode!(body)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %Error{kind: :timeout, message: "Request exceeded deadline"}}
    else
      req_options = clamp_receive_timeout(req_options, remaining)

      owner =
        OwnedWorker.start(deadline, fn ->
          request_encoded(url, headers, encoded_body, req_options)
        end)

      case await_monitored_post(owner, deadline) do
        {:ok, result} -> decode_post_result(result)
        {:shutdown, _reason} -> shutdown_error()
        {:worker_exit, reason} -> propagate_worker_exit(reason)
        :timeout -> {:error, %Error{kind: :timeout, message: "Request exceeded deadline"}}
      end
    end
  end

  defp stream_sse_with_deadline(
         url,
         headers,
         body,
         initial_acc,
         handle_event,
         req_options,
         deadline
       ) do
    encoded_body = Jason.encode!(body)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}
    else
      caller = self()
      tag = make_ref()
      req_options = clamp_receive_timeout(req_options, remaining)

      # Synchronous per-chunk acknowledgement on 200 streams keeps at most one
      # chunk in flight (preserving backpressure while running callbacks in the
      # caller). Non-200 chunks stay scoped to each Req response's private map so
      # redirect bodies never contaminate a later error response.
      into_fn = fn {:data, chunk}, {req, resp} ->
        if Map.get(resp, :status, 200) == 200 do
          ack = make_ref()
          send(caller, {tag, :chunk, self(), ack, chunk})

          receive do
            {^ack, :ok} -> {:cont, {req, resp}}
            {^ack, :halt} -> {:halt, {req, resp}}
          end
        else
          SSE.append_error_chunk(chunk, req, resp)
        end
      end

      owner =
        OwnedWorker.start(deadline, fn ->
          request_encoded(url, headers, encoded_body, [into: into_fn] ++ req_options)
        end)

      outcome =
        try do
          await_sse(owner, tag, initial_acc, handle_event, deadline)
        catch
          kind, reason ->
            OwnedWorker.cancel(owner)
            flush_chunks(tag)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case outcome do
        {:propagate, reason} -> propagate_worker_exit(reason)
        result -> result
      end
    end
  end

  defp await_monitored_post(%Task{ref: ref} = owner, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:ok, result}} ->
        _ = Task.ignore(owner)
        {:ok, result}

      {^ref, {:worker_exit, reason}} ->
        _ = Task.ignore(owner)

        if worker_shutdown_reason?(reason),
          do: {:shutdown, reason},
          else: {:worker_exit, reason}

      {^ref, :timeout} ->
        _ = Task.ignore(owner)
        :timeout

      {:DOWN, ^ref, :process, _pid, reason} ->
        if OwnedWorker.shutdown_reason?(reason),
          do: {:shutdown, reason},
          else: {:worker_exit, reason}
    after
      remaining ->
        OwnedWorker.cancel(owner)
        :timeout
    end
  end

  defp await_sse(%Task{ref: ref} = owner, tag, acc, handle_event, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^tag, :chunk, worker, ack, chunk} ->
        if System.monotonic_time(:millisecond) >= deadline do
          send(worker, {ack, :halt})
          abort_sse_timeout(owner, tag)
        else
          case SSE.apply_chunk_until(acc, chunk, handle_event, deadline) do
            {:ok, %{sse_handler_error: %Error{} = error}} ->
              send(worker, {ack, :halt})
              OwnedWorker.cancel(owner)
              flush_chunks(tag)
              {:error, error}

            {:ok, next_acc} ->
              send(worker, {ack, :ok})
              await_sse(owner, tag, next_acc, handle_event, deadline)

            {:timeout, _partial_acc} ->
              send(worker, {ack, :halt})
              abort_sse_timeout(owner, tag)
          end
        end

      {^ref, {:ok, req_result}} ->
        _ = Task.ignore(owner)
        finish_stream_result(req_result, acc)

      {^ref, {:worker_exit, reason}} ->
        _ = Task.ignore(owner)
        flush_chunks(tag)

        if worker_shutdown_reason?(reason),
          do: shutdown_error(),
          else: {:propagate, reason}

      {^ref, :timeout} ->
        _ = Task.ignore(owner)
        flush_chunks(tag)
        {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}

      {:DOWN, ^ref, :process, _pid, reason} ->
        flush_chunks(tag)

        if OwnedWorker.shutdown_reason?(reason),
          do: shutdown_error(),
          else: {:propagate, reason}
    after
      remaining ->
        abort_sse_timeout(owner, tag)
    end
  end

  defp abort_sse_timeout(owner, tag) do
    OwnedWorker.cancel(owner)
    flush_chunks(tag)
    {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}
  end

  defp flush_chunks(tag) do
    receive do
      {^tag, :chunk, _worker, _ack, _chunk} -> flush_chunks(tag)
    after
      0 -> :ok
    end
  end

  # Dedicated non-retryable :shutdown kind (never produced from provider
  # payloads) so Retry neither retries nor spawns fallback workers against a
  # shutting-down supervisor.
  defp shutdown_error do
    {:error,
     %Error{
       kind: :shutdown,
       message: "HTTP request interrupted by shutdown"
     }}
  end

  defp worker_shutdown_reason?({:worker_crash, :exit, reason, _stacktrace}),
    do: OwnedWorker.shutdown_reason?(reason)

  defp worker_shutdown_reason?(reason),
    do: OwnedWorker.shutdown_reason?(reason)

  @spec propagate_worker_exit(term()) :: {:error, Error.t()}
  defp propagate_worker_exit(:normal) do
    {:error, %Error{kind: :unknown, message: "HTTP worker exited normally without a reply"}}
  end

  defp propagate_worker_exit({:worker_crash, :exit, :normal, _stacktrace}) do
    {:error, %Error{kind: :unknown, message: "HTTP worker exited normally without a reply"}}
  end

  defp propagate_worker_exit({:worker_crash, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  # External worker/owner kills (e.g. max_heap_size, Process.exit/2, or linked
  # process crashes) return a typed error with a sanitized reason instead of
  # crashing the caller or leaking exception payloads/stacktrace arguments.
  defp propagate_worker_exit(reason) do
    {:error,
     %Error{
       kind: :unknown,
       message: "HTTP worker exited unexpectedly: #{OwnedWorker.format_exit_reason(reason)}"
     }}
  end

  defp finish_stream_result({:ok, %{status: 200}}, %{sse_handler_error: %Error{} = error}),
    do: {:error, error}

  defp finish_stream_result({:ok, %{status: 200}}, acc), do: {:ok, acc}

  defp finish_stream_result({:ok, resp}, acc) do
    {:error, Error.from_response(resp.status, resp.headers, error_body(resp, acc))}
  end

  defp finish_stream_result({:error, reason}, _acc),
    do: {:error, Error.from_transport(reason)}

  defp decode_post_result({:ok, %{status: 200, body: resp_body}}), do: {:ok, resp_body}

  defp decode_post_result({:ok, resp}),
    do: {:error, Error.from_response(resp.status, resp.headers, resp.body)}

  defp decode_post_result({:error, reason}), do: {:error, Error.from_transport(reason)}

  defp decode_sse_result({:ok, %{status: 200} = resp}, initial_acc) do
    case Map.get(resp.private, :sse_acc, initial_acc) do
      %{sse_handler_error: %Error{} = error} -> {:error, error}
      acc -> {:ok, acc}
    end
  end

  defp decode_sse_result({:ok, resp}, initial_acc),
    do: {:error, Error.from_response(resp.status, resp.headers, error_body(resp, initial_acc))}

  defp decode_sse_result({:error, reason}, _initial_acc),
    do: {:error, Error.from_transport(reason)}

  defp clamp_receive_timeout(req_options, remaining) do
    case Keyword.get(req_options, :receive_timeout) do
      existing when is_integer(existing) and existing > 0 ->
        Keyword.put(req_options, :receive_timeout, min(existing, remaining))

      _other ->
        Keyword.put(req_options, :receive_timeout, remaining)
    end
  end

  defp request(url, headers, body, req_options) do
    request_encoded(url, headers, Jason.encode!(body), req_options)
  end

  defp request_encoded(url, headers, encoded_body, req_options) do
    # Leave response body decoding to Alloy.Provider.decode_body/1 and
    # Error.from_response/3 so malformed JSON with `content-type: application/json`
    # classifies as :malformed_reply and non-200 error statuses are never masked
    # by a Req JSON decode error.
    [url: url, method: :post, headers: headers, body: encoded_body, decode_body: false]
    |> Keyword.merge(req_options)
    |> Keyword.put(:retry, false)
    |> Req.request()
  end

  # With an `into:` handler, non-200 chunks are captured verbatim under
  # :sse_error_body so multi-paragraph or HTML error bodies are never split
  # or discarded by the SSE parser.
  defp error_body(%{body: ""} = resp, initial_acc) do
    case Map.fetch(resp.private, :sse_error_body) do
      {:ok, chunks} ->
        IO.iodata_to_binary(chunks)

      :error ->
        resp.private
        |> Map.get(:sse_acc, initial_acc)
        |> Map.get(:buffer, "")
    end
  end

  defp error_body(resp, _initial_acc), do: resp.body
end
