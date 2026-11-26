defmodule Alloy.Provider.HTTP do
  @moduledoc false
  # Request plumbing shared by the built-in HTTP providers: the JSON POST,
  # Req's own retries switched off (Alloy.Provider.Retry owns retries and the
  # turn deadline), and every failure turned into an Alloy.Provider.Error.

  alias Alloy.Cancel
  alias Alloy.Internal.Sanitize
  alias Alloy.OwnedWorker
  alias Alloy.Provider
  alias Alloy.Provider.{Error, SSE}

  @cancel_poll_ms 25

  @type headers :: [{String.t(), String.t()}]

  @doc false
  @spec request_opts(map()) :: keyword()
  def request_opts(config) when is_map(config) do
    [
      deadline: Map.get(config, :alloy_request_deadline),
      cancel_token: Map.get(config, :alloy_cancel_token)
    ]
  end

  @doc """
  POSTs `body` as JSON. Returns the response body of a 200 response (raw binary
  by default unless `:decode_body` is overridden in `req_options`; built-in
  providers decode via `Alloy.Provider.decode_body/1`).

  `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  bound even if the server trickles bytes slowly, and `:cancel_token`
  (`Alloy.Cancel.t()`) for cooperative cancellation. Passing either requires
  `Alloy.TaskSupervisor` to be running (started by the `:alloy` application).
  """
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

  @doc """
  POSTs `body` as JSON and feeds the SSE response through `handle_event`
  (see `Alloy.Provider.SSE.req_stream_handler/2`). Returns the final
  accumulator of a 200 response.

  `req_options` may carry extra Req options such as `params:`.
  `opts` may carry `:deadline` (monotonic ms) to enforce an absolute wall-clock
  bound across stalled and trickling streams, and `:cancel_token`
  (`Alloy.Cancel.t()`) for cooperative cancellation, while running
  `handle_event` in the caller's process (requires `Alloy.TaskSupervisor` to be
  running).
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

  @doc false
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec maybe_put_unless_empty_list(map(), term(), term()) :: map()
  def maybe_put_unless_empty_list(map, _key, value) when value in [nil, []], do: map
  def maybe_put_unless_empty_list(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec maybe_put_unless_empty_map(map(), term(), term()) :: map()
  def maybe_put_unless_empty_map(map, _key, value) when value in [nil, %{}], do: map
  def maybe_put_unless_empty_map(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec maybe_put_new(map(), term(), term()) :: map()
  def maybe_put_new(map, _key, nil), do: map
  def maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  @doc false
  @spec non_neg_int(term()) :: non_neg_integer()
  def non_neg_int(n) when is_integer(n) and n >= 0, do: n
  def non_neg_int(_other), do: 0

  @doc false
  @spec record_sticky_error(map(), Error.kind(), String.t()) :: map()
  def record_sticky_error(%{sticky_error: %Error{}} = acc, _kind, _message), do: acc

  def record_sticky_error(acc, kind, message) do
    %{acc | sticky_error: %Error{kind: kind, message: message}}
  end

  @doc false
  @spec stringify_extra_body(term()) :: map()
  def stringify_extra_body(extra_body) when is_map(extra_body) and not is_struct(extra_body) do
    Map.new(extra_body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def stringify_extra_body(_), do: %{}

  @doc false
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

  @doc false
  @spec join_url(String.t(), String.t()) :: String.t()
  def join_url(base_url, "") when is_binary(base_url), do: base_url

  def join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc false
  @spec http_url?(term()) :: boolean()
  def http_url?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme) in ["http", "https"]

      _ ->
        false
    end
  end

  def http_url?(_other), do: false

  # Account-scoped provider File API URIs look like ordinary HTTPS URLs but
  # require the uploading provider's credentials and fail if another provider
  # attempts to fetch them as public URLs.
  @doc false
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

  @doc false
  @spec resolve_api_key(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve_api_key(config) when is_map(config) do
    case Map.get(config, :api_key) do
      key when is_binary(key) ->
        validate_api_key_bytes(key)

      fun when is_function(fun, 0) ->
        resolve_api_key_callback(
          fun,
          Map.get(config, :alloy_request_deadline),
          Map.get(config, :alloy_cancel_token)
        )

      nil ->
        {:error, %Error{kind: :auth, message: "Missing :api_key in provider config"}}

      other ->
        {:error,
         %Error{
           kind: :auth,
           message: "Invalid :api_key in provider config: #{Sanitize.shape_summary(other)}"
         }}
    end
  end

  defp validate_api_key_bytes(key) do
    if contains_invalid_header_byte?(key) do
      {:error,
       %Error{
         kind: :auth,
         message: "Invalid :api_key: contains non-ASCII or control bytes"
       }}
    else
      {:ok, key}
    end
  end

  # Mint's HTTP/1 encoder rejects bytes outside printable ASCII (0x20..0x7E)
  # with {:invalid_header_value, name, value}; reject them upfront so secrets
  # can never leak into transport error messages.
  defp contains_invalid_header_byte?(<<>>), do: false
  defp contains_invalid_header_byte?(<<b, _rest::binary>>) when b < 0x20 or b >= 0x7F, do: true

  defp contains_invalid_header_byte?(<<_b, rest::binary>>),
    do: contains_invalid_header_byte?(rest)

  @doc false
  @spec resolve_optional_api_key(map()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def resolve_optional_api_key(config) when is_map(config) do
    case Map.get(config, :api_key) do
      nil -> {:ok, nil}
      _present -> resolve_api_key(config)
    end
  end

  defp resolve_api_key_callback(fun, deadline, cancel_token)
       when is_integer(deadline) or not is_nil(cancel_token) do
    cond do
      Cancel.cancelled?(cancel_token) ->
        cancelled_error("Request cancelled while resolving :api_key")

      deadline_expired?(deadline) ->
        {:error,
         %Error{kind: :timeout, message: "Request exceeded deadline while resolving :api_key"}}

      true ->
        owner =
          OwnedWorker.start(deadline, fn -> invoke_api_key_callback(fun) end,
            cancel_token: cancel_token
          )

        case await_monitored_post(owner, deadline, cancel_token) do
          {:ok, result} ->
            maybe_override_cancelled(
              result,
              cancel_token,
              "Request cancelled while resolving :api_key"
            )

          :cancelled ->
            cancelled_error("Request cancelled while resolving :api_key")

          {:shutdown, _reason} ->
            shutdown_error()

          {:worker_exit, reason} ->
            {:error,
             %Error{
               kind: :auth,
               message:
                 "Dynamic :api_key callback exited: #{OwnedWorker.format_exit_reason(reason)}"
             }}

          :timeout ->
            {:error,
             %Error{
               kind: :timeout,
               message: "Dynamic :api_key callback exceeded request deadline"
             }}
        end
    end
  end

  defp resolve_api_key_callback(fun, _no_deadline, nil), do: invoke_api_key_callback(fun)

  defp invoke_api_key_callback(fun) do
    case fun.() do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        validate_api_key_bytes(key)

      key when is_binary(key) and byte_size(key) > 0 ->
        validate_api_key_bytes(key)

      {:error, %Error{} = err} ->
        safe_kind =
          if err.kind in [
               :auth,
               :timeout,
               :rate_limited,
               :overloaded,
               :server_error,
               :network,
               :invalid_request,
               :quota
             ],
             do: err.kind,
             else: :auth

        safe_status = if is_integer(err.status) and err.status > 0, do: err.status, else: nil

        safe_retry_after =
          if is_integer(err.retry_after_ms) and err.retry_after_ms >= 0,
            do: err.retry_after_ms,
            else: nil

        {:error,
         %Error{
           kind: safe_kind,
           status: safe_status,
           retry_after_ms: safe_retry_after,
           message: "Dynamic :api_key callback failed (#{safe_kind})"
         }}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :auth,
           message: "Dynamic :api_key callback failed: #{Sanitize.shape_summary(reason)}"
         }}

      other ->
        {:error,
         %Error{
           kind: :auth,
           message:
             "Dynamic :api_key callback returned invalid value: #{Sanitize.shape_summary(other)}"
         }}
    end
  rescue
    exception ->
      {:error,
       %Error{
         kind: :auth,
         message: "Dynamic :api_key callback raised: #{inspect(exception.__struct__)}"
       }}
  catch
    kind, reason ->
      {:error,
       %Error{
         kind: :auth,
         message: "Dynamic :api_key callback #{kind}: #{Sanitize.exit_summary(reason, :redact)}"
       }}
  end

  @doc false
  @spec resolve_auth_scheme(map()) :: {:ok, :api_key | :bearer} | {:error, Error.t()}
  def resolve_auth_scheme(config) when is_map(config) do
    case Map.get(config, :auth_scheme, :api_key) do
      scheme when scheme in [:api_key, :bearer] ->
        {:ok, scheme}

      other ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "Invalid :auth_scheme: expected :api_key or :bearer, got #{Sanitize.shape_summary(other)}"
         }}
    end
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

  defp post_json_managed(url, headers, body, req_options, deadline, cancel_token) do
    encoded_body = Jason.encode!(body)

    cond do
      Cancel.cancelled?(cancel_token) ->
        cancelled_error("Request cancelled")

      deadline_expired?(deadline) ->
        {:error, %Error{kind: :timeout, message: "Request exceeded deadline"}}

      true ->
        req_options = maybe_clamp_receive_timeout(req_options, deadline)

        owner =
          OwnedWorker.start(
            deadline,
            fn -> request_encoded(url, headers, encoded_body, req_options) end,
            cancel_token: cancel_token
          )

        case await_monitored_post(owner, deadline, cancel_token) do
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

          :timeout ->
            {:error, %Error{kind: :timeout, message: "Request exceeded deadline"}}
        end
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
              OwnedWorker.cancel(owner)
              flush_task_reply(owner.ref)
              flush_chunks(tag)
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
            OwnedWorker.cancel(owner)
            flush_task_reply(ref)
            flush_chunks(tag)
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
    OwnedWorker.cancel(owner)
    flush_task_reply(ref)
    flush_chunks(tag)
    {:error, %Error{kind: :timeout, message: "Stream exceeded request deadline"}}
  end

  defp abort_sse_cancelled(owner, ref, tag) do
    OwnedWorker.cancel(owner)
    flush_task_reply(ref)
    flush_chunks(tag)
    cancelled_error("Stream cancelled")
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

  defp cancelled_error(message) do
    {:error, %Error{kind: :cancelled, message: message}}
  end

  defp maybe_override_cancelled({:error, _} = err, cancel_token, message) do
    if Cancel.cancelled?(cancel_token), do: cancelled_error(message), else: err
  end

  defp maybe_override_cancelled(ok, _cancel_token, _message), do: ok

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
