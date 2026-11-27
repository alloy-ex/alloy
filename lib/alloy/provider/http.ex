defmodule Alloy.Provider.HTTP do
  @moduledoc false
  # Request plumbing shared by the built-in HTTP providers: the JSON POST,
  # Req's own retries switched off (Alloy.Provider.Retry owns retries and the
  # turn deadline), and every failure turned into an Alloy.Provider.Error.

  alias Alloy.Cancel
  alias Alloy.OwnedWorker
  alias Alloy.Provider
  alias Alloy.Provider.{Auth, Error, SSE}

  @cancel_poll_ms 25

  @type headers :: [{String.t(), String.t()}]

  @type managed_result ::
          {:ok, term()}
          | :cancelled
          | :expired
          | :timeout
          | {:shutdown, term()}
          | {:worker_exit, term()}

  @spec request_opts(map()) :: keyword()
  def request_opts(config) when is_map(config) do
    [
      deadline: Map.get(config, :alloy_request_deadline),
      cancel_token: Map.get(config, :alloy_cancel_token)
    ]
  end

  # POSTs `body` as JSON. Returns the response body of a 200 response (raw binary
  # by default unless `:decode_body` is overridden in `req_options`; built-in
  # providers decode via `Alloy.Provider.decode_body/1`).
  #
  # `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  # bound even if the server trickles bytes slowly, and `:cancel_token`
  # (`Alloy.Cancel.t()`) for cooperative cancellation. Passing either requires
  # `Alloy.TaskSupervisor` to be running (started by the `:alloy` application).
  @spec post_json(String.t(), headers(), map(), keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_json(url, headers, body, req_options, opts \\ []) do
    deadline = Keyword.get(opts, :deadline)
    cancel_token = Keyword.get(opts, :cancel_token)

    cond do
      Cancel.cancelled?(cancel_token) ->
        cancelled_error("Request cancelled")

      is_integer(deadline) or not is_nil(cancel_token) ->
        post_json_managed(url, headers, body, req_options, deadline, cancel_token)

      true ->
        decode_post_result(request(url, headers, body, req_options))
    end
  end

  # POSTs `body` as JSON and feeds the SSE response through `handle_event`
  # (see `Alloy.Provider.SSE.req_stream_handler/2`). Returns the final
  # accumulator of a 200 response.
  #
  # `req_options` may carry extra Req options such as `params:`.
  # `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  # bound across stalled and trickling streams, and `:cancel_token`
  # (`Alloy.Cancel.t()`) for cooperative cancellation, while running
  # `handle_event` in the caller's process (requires `Alloy.TaskSupervisor` to be
  # running).
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
    deadline = Keyword.get(opts, :deadline)
    cancel_token = Keyword.get(opts, :cancel_token)

    cond do
      Cancel.cancelled?(cancel_token) ->
        cancelled_error("Stream cancelled")

      is_integer(deadline) or not is_nil(cancel_token) ->
        stream_sse_managed(
          url,
          headers,
          body,
          initial_acc,
          handle_event,
          req_options,
          deadline,
          cancel_token
        )

      true ->
        handler = SSE.req_stream_handler(initial_acc, handle_event)

        decode_sse_result(
          request(url, headers, body, [into: handler] ++ req_options),
          initial_acc
        )
    end
  end

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_unless_empty_list(map(), term(), term()) :: map()
  def maybe_put_unless_empty_list(map, _key, value) when value in [nil, []], do: map
  def maybe_put_unless_empty_list(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_unless_empty_map(map(), term(), term()) :: map()
  def maybe_put_unless_empty_map(map, _key, value) when value in [nil, %{}], do: map
  def maybe_put_unless_empty_map(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_new(map(), term(), term()) :: map()
  def maybe_put_new(map, _key, nil), do: map
  def maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  @spec non_neg_int(term()) :: non_neg_integer()
  def non_neg_int(n) when is_integer(n) and n >= 0, do: n
  def non_neg_int(_other), do: 0

  @spec record_sticky_error(map(), Error.kind(), String.t()) :: map()
  def record_sticky_error(%{sticky_error: %Error{}} = acc, _kind, _message), do: acc

  def record_sticky_error(acc, kind, message) do
    %{acc | sticky_error: %Error{kind: kind, message: message}}
  end

  @spec stringify_extra_body(term()) :: map()
  def stringify_extra_body(extra_body) when is_map(extra_body) and not is_struct(extra_body) do
    Map.new(extra_body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def stringify_extra_body(_), do: %{}

  @spec merge_extra_body(map(), map(), String.t()) :: map()
  def merge_extra_body(body, extra_body, nested_key)
      when is_map(body) and is_map(extra_body) and is_binary(nested_key) do
    case {Map.get(body, nested_key), Map.get(extra_body, nested_key)} do
      {base_nested, extra_nested}
      when is_map(base_nested) and is_map(extra_nested) and not is_struct(extra_nested) ->
        merged_nested = Map.merge(base_nested, Provider.stringify_keys(extra_nested))

        body
        |> Map.merge(extra_body)
        |> Map.put(nested_key, merged_nested)

      _other ->
        Map.merge(body, extra_body)
    end
  end

  @spec join_url(String.t(), String.t()) :: String.t()
  def join_url(base_url, "") when is_binary(base_url), do: base_url

  def join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  @spec uri_with_scheme?(term(), [String.t()]) :: boolean()
  def uri_with_scheme?(uri, schemes) when is_binary(uri) and is_list(schemes) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme) in schemes

      _ ->
        false
    end
  end

  def uri_with_scheme?(_other, _schemes), do: false

  @spec http_url?(term()) :: boolean()
  def http_url?(uri), do: uri_with_scheme?(uri, ["http", "https"])

  # Account-scoped provider File API URIs look like ordinary HTTPS URLs but
  # require the uploading provider's credentials and fail if another provider
  # attempts to fetch them as public URLs.
  @spec provider_file_uri?(term()) :: boolean()
  def provider_file_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        String.downcase(scheme) in ["http", "https"] and
          String.downcase(host) == "generativelanguage.googleapis.com" and
          String.contains?(path, "/files/")

      _ ->
        false
    end
  end

  def provider_file_uri?(_other), do: false

  @spec public_http_url?(term()) :: boolean()
  def public_http_url?(uri), do: http_url?(uri) and not provider_file_uri?(uri)

  @spec decode_tool_arguments(term(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def decode_tool_arguments(args, name, opts \\ [])

  def decode_tool_arguments("", _name, _opts), do: {:ok, %{}}

  def decode_tool_arguments(args, name, opts) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, input} when is_map(input) ->
        {:ok, input}

      {:ok, _non_map} ->
        {:error,
         %Error{
           kind: :malformed_reply,
           message: "Tool call arguments for #{name} must be a JSON object"
         }}

      {:error, reason} ->
        prefix = Keyword.get(opts, :message_prefix, "Invalid JSON in tool call arguments for")

        message =
          if Keyword.get(opts, :include_reason, false),
            do: "#{prefix} #{name}: #{Exception.message(reason)}",
            else: "#{prefix} #{name}"

        {:error, %Error{kind: :malformed_reply, message: message}}
    end
  end

  def decode_tool_arguments(args, _name, _opts) when is_map(args) and not is_struct(args),
    do: {:ok, args}

  def decode_tool_arguments(_args, name, _opts) do
    {:error,
     %Error{
       kind: :malformed_reply,
       message: "Invalid tool call arguments payload for #{name}"
     }}
  end

  @spec decode_truncated_arguments(term()) :: map()
  def decode_truncated_arguments(""), do: %{}

  def decode_truncated_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def decode_truncated_arguments(args) when is_map(args) and not is_struct(args), do: args
  def decode_truncated_arguments(_other), do: %{}

  @spec truncated_tool_call_id(non_neg_integer()) :: String.t()
  def truncated_tool_call_id(index) when is_integer(index) and index >= 0 do
    "truncated_#{index}_#{System.unique_integer([:positive])}"
  end

  @spec map_ok(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def map_ok(enumerable, fun) when is_function(fun, 1) do
    case Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
           case fun.(item) do
             {:ok, value} -> {:cont, {:ok, [value | acc]}}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = err -> err
    end
  end

  @spec resolve_api_key(map()) :: {:ok, String.t()} | {:error, Error.t()}
  defdelegate resolve_api_key(config), to: Auth

  @spec resolve_optional_api_key(map()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  defdelegate resolve_optional_api_key(config), to: Auth

  @spec resolve_auth_scheme(map()) :: {:ok, :api_key | :bearer} | {:error, Error.t()}
  defdelegate resolve_auth_scheme(config), to: Auth

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

  @spec run_managed(integer() | nil, Cancel.t() | nil, (-> term())) :: managed_result()
  def run_managed(deadline, cancel_token, fun)
      when (is_integer(deadline) or is_nil(deadline)) and is_function(fun, 0) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        :cancelled

      deadline_expired?(deadline) ->
        :expired

      true ->
        owner = OwnedWorker.start(deadline, fun, cancel_token: cancel_token)
        await_monitored_post(owner, deadline, cancel_token)
    end
  end

  @spec cancelled_error(String.t()) :: {:error, Error.t()}
  def cancelled_error(message) do
    {:error, %Error{kind: :cancelled, message: message}}
  end

  @spec maybe_override_cancelled(
          {:ok, term()} | {:error, Error.t()},
          Cancel.t() | nil,
          String.t()
        ) :: {:ok, term()} | {:error, Error.t()}
  def maybe_override_cancelled({:error, _} = err, cancel_token, message) do
    if Cancel.cancelled?(cancel_token), do: cancelled_error(message), else: err
  end

  def maybe_override_cancelled(ok, _cancel_token, _message), do: ok

  # Dedicated non-retryable :shutdown kind (never produced from provider
  # payloads) so Retry neither retries nor spawns fallback workers against a
  # shutting-down supervisor.
  @spec shutdown_error() :: {:error, Error.t()}
  def shutdown_error do
    {:error,
     %Error{
       kind: :shutdown,
       message: "HTTP request interrupted by shutdown"
     }}
  end

  defp post_json_managed(url, headers, body, req_options, deadline, cancel_token) do
    encoded_body = Jason.encode!(body)

    case run_managed(deadline, cancel_token, fn ->
           request_encoded(
             url,
             headers,
             encoded_body,
             maybe_clamp_receive_timeout(req_options, deadline)
           )
         end) do
      {:ok, result} ->
        maybe_override_cancelled(
          decode_post_result(result),
          cancel_token,
          "Request cancelled"
        )

      :cancelled ->
        cancelled_error("Request cancelled")

      {:shutdown, _reason} ->
        shutdown_error()

      {:worker_exit, reason} ->
        propagate_worker_exit(reason)

      timeout when timeout in [:expired, :timeout] ->
        {:error, %Error{kind: :timeout, message: "Request exceeded deadline"}}
    end
  end

  defp stream_sse_managed(
         url,
         headers,
         body,
         initial_acc,
         handle_event,
         req_options,
         deadline,
         cancel_token
       ) do
    encoded_body = Jason.encode!(body)

    cond do
      Cancel.cancelled?(cancel_token) ->
        cancelled_error("Stream cancelled")

      deadline_expired?(deadline) ->
        {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}

      true ->
        caller = self()
        tag = make_ref()
        req_options = maybe_clamp_receive_timeout(req_options, deadline)

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
          OwnedWorker.start(
            deadline,
            fn -> request_encoded(url, headers, encoded_body, [into: into_fn] ++ req_options) end,
            cancel_token: cancel_token
          )

        sse = %{
          owner: owner,
          ref: owner.ref,
          tag: tag,
          handle_event: handle_event,
          deadline: deadline,
          cancel_token: cancel_token
        }

        outcome =
          try do
            await_sse(sse, initial_acc)
          catch
            kind, reason ->
              cleanup_sse_worker(owner, owner.ref, tag)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        case outcome do
          {:propagate, reason} -> propagate_worker_exit(reason)
          result -> result
        end
    end
  end

  defp await_monitored_post(%Task{ref: ref} = owner, deadline, cancel_token) do
    if Cancel.cancelled?(cancel_token) do
      OwnedWorker.cancel(owner)
      flush_task_reply(ref)
      :cancelled
    else
      wait_ms = next_wait_ms(deadline, cancel_token)

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

        {^ref, :cancelled} ->
          _ = Task.ignore(owner)
          :cancelled

        {:DOWN, ^ref, :process, _pid, reason} ->
          if OwnedWorker.shutdown_reason?(reason),
            do: {:shutdown, reason},
            else: {:worker_exit, reason}
      after
        wait_ms ->
          handle_post_wait_timeout(owner, ref, deadline, cancel_token)
      end
    end
  end

  defp handle_post_wait_timeout(owner, ref, deadline, cancel_token) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        OwnedWorker.cancel(owner)
        flush_task_reply(ref)
        :cancelled

      deadline_expired?(deadline) ->
        OwnedWorker.cancel(owner)
        flush_task_reply(ref)
        :timeout

      true ->
        await_monitored_post(owner, deadline, cancel_token)
    end
  end

  defp await_sse(
         %{
           owner: owner,
           ref: ref,
           tag: tag,
           deadline: deadline,
           cancel_token: cancel_token
         } = sse,
         acc
       ) do
    if Cancel.cancelled?(cancel_token) do
      abort_sse_cancelled(owner, ref, tag)
    else
      wait_ms = next_wait_ms(deadline, cancel_token)

      receive do
        {^tag, :chunk, worker, ack, chunk} ->
          handle_sse_chunk(sse, worker, ack, chunk, acc)

        {^ref, {:ok, req_result}} ->
          _ = Task.ignore(owner)

          maybe_override_cancelled(
            finish_stream_result(req_result, acc),
            cancel_token,
            "Stream cancelled"
          )

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

        {^ref, :cancelled} ->
          _ = Task.ignore(owner)
          flush_chunks(tag)
          cancelled_error("Stream cancelled")

        {:DOWN, ^ref, :process, _pid, reason} ->
          flush_chunks(tag)

          if OwnedWorker.shutdown_reason?(reason),
            do: shutdown_error(),
            else: {:propagate, reason}
      after
        wait_ms ->
          handle_sse_wait_timeout(sse, acc)
      end
    end
  end

  defp handle_sse_chunk(
         %{
           owner: owner,
           ref: ref,
           tag: tag,
           handle_event: handle_event,
           deadline: deadline,
           cancel_token: cancel_token
         } = sse,
         worker,
         ack,
         chunk,
         acc
       ) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        send(worker, {ack, :halt})
        abort_sse_cancelled(owner, ref, tag)

      deadline_expired?(deadline) ->
        send(worker, {ack, :halt})
        abort_sse_timeout(owner, ref, tag)

      true ->
        case SSE.apply_chunk_until(acc, chunk, handle_event, deadline, cancel_token) do
          {:ok, %{sse_handler_error: %Error{} = error}} ->
            send(worker, {ack, :halt})
            cleanup_sse_worker(owner, ref, tag)
            {:error, error}

          {:ok, next_acc} ->
            send(worker, {ack, :ok})
            await_sse(sse, next_acc)

          {:cancelled, _partial_acc} ->
            send(worker, {ack, :halt})
            abort_sse_cancelled(owner, ref, tag)

          {:timeout, _partial_acc} ->
            send(worker, {ack, :halt})
            abort_sse_timeout(owner, ref, tag)
        end
    end
  end

  defp handle_sse_wait_timeout(
         %{owner: owner, ref: ref, tag: tag, deadline: deadline, cancel_token: cancel_token} =
           sse,
         acc
       ) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        abort_sse_cancelled(owner, ref, tag)

      deadline_expired?(deadline) ->
        abort_sse_timeout(owner, ref, tag)

      true ->
        await_sse(sse, acc)
    end
  end

  defp abort_sse_timeout(owner, ref, tag) do
    cleanup_sse_worker(owner, ref, tag)
    {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}
  end

  defp abort_sse_cancelled(owner, ref, tag) do
    cleanup_sse_worker(owner, ref, tag)
    cancelled_error("Stream cancelled")
  end

  defp cleanup_sse_worker(owner, ref, tag) do
    OwnedWorker.cancel(owner)
    flush_task_reply(ref)
    flush_chunks(tag)
  end

  defp flush_task_reply(ref) do
    receive do
      {^ref, _reply} -> flush_task_reply(ref)
    after
      0 -> :ok
    end
  end

  defp flush_chunks(tag) do
    receive do
      {^tag, :chunk, _worker, _ack, _chunk} -> flush_chunks(tag)
    after
      0 -> :ok
    end
  end

  defp deadline_expired?(nil), do: false
  defp deadline_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp next_wait_ms(nil, nil), do: :infinity
  defp next_wait_ms(nil, _cancel_token), do: @cancel_poll_ms

  defp next_wait_ms(deadline, nil),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp next_wait_ms(deadline, _cancel_token),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), @cancel_poll_ms)

  defp maybe_clamp_receive_timeout(req_options, nil), do: req_options

  defp maybe_clamp_receive_timeout(req_options, deadline) when is_integer(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    clamp_receive_timeout(req_options, remaining)
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

  defp decode_sse_result({:ok, %{status: 200} = resp} = result, initial_acc) do
    finish_stream_result(result, Map.get(resp.private, :sse_acc, initial_acc))
  end

  defp decode_sse_result(result, initial_acc), do: finish_stream_result(result, initial_acc)

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
