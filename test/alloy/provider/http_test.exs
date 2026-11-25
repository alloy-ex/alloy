defmodule Alloy.Provider.HTTPTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.{Error, HTTP, OpenAI, OpenAICompat, Retry, SSE}

  defmodule BackpressureAdapter do
    def run(req) do
      [bp_id] = Req.Request.get_header(req, "x-bp-key")
      counter = :persistent_term.get({Alloy.Provider.HTTPTest, :backpressure_pushed, bp_id})
      resp = Req.Response.new(status: 200)

      {_req, final_resp} =
        Enum.reduce_while(1..25, {req, resp}, fn n, state ->
          :atomics.put(counter, 1, n)

          case req.into.({:data, "data: {\"n\":#{n}}\n\n"}, state) do
            {:cont, next_state} -> {:cont, next_state}
            {:halt, next_state} -> {:halt, next_state}
          end
        end)

      {req, final_resp}
    end
  end

  defmodule ShutdownProbeAdapter do
    def run(req) do
      [probe_id] = Req.Request.get_header(req, "x-probe-id")
      test_pid = :persistent_term.get({Alloy.Provider.HTTPTest, :shutdown_probe, probe_id})

      if Req.Request.get_header(req, "x-trap-exit") == ["true"] do
        Process.flag(:trap_exit, true)
      end

      [owner_pid | _] = Process.get(:"$callers", [])
      send(test_pid, {:shutdown_probe_started, owner_pid, self()})

      if Req.Request.get_header(req, "x-emit-chunk") == ["true"] do
        resp = Req.Response.new(status: 200)
        _ = req.into.({:data, "data: {\"n\":1}\n\n"}, {req, resp})
      end

      receive do
        :never -> {req, Req.Response.new(status: 200, body: "{}")}
      end
    end
  end

  defmodule LinkedChildCrashAdapter do
    def run(req) do
      [probe_id] = Req.Request.get_header(req, "x-probe-id")
      test_pid = :persistent_term.get({Alloy.Provider.HTTPTest, :crash_probe, probe_id})
      child = spawn_link(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:linked_child_started, child})
      raise "adapter boom"
    end
  end

  defmodule NormalExitAdapter do
    def run(_req), do: exit(:normal)
  end

  defmodule CustomReqProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_messages, _tools, config) do
      req_options = Map.get(config, :req_options, [])

      case Req.request([url: "http://localhost/custom", method: :post] ++ req_options) do
        {:ok, %{status: 200, body: %{"reply" => text}}} ->
          {:ok, %{stop_reason: :end_turn, messages: [Message.assistant(text)], usage: %{}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  describe "SSE error bodies and JSON decoding" do
    test "non-200 multi-paragraph HTML SSE error bodies are preserved verbatim" do
      html_body = "<html>\n\n<body>502 Bad Gateway\n\nUpstream failed</body>\n\n</html>"

      Req.Test.stub(:http_sse_non200_error_body, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(502, html_body)
      end)

      assert {:error, %Error{kind: :server_error, status: 502, message: message}} =
               HTTP.stream_sse(
                 "http://localhost/stream",
                 [],
                 %{},
                 %{buffer: ""},
                 fn _acc, _event -> flunk("handle_event must not run on non-200") end,
                 plug: {Req.Test, :http_sse_non200_error_body}
               )

      assert message == html_body
    end

    test "redirect bodies do not contaminate final SSE error classification" do
      Req.Test.stub(:http_sse_redirect_error, fn conn ->
        case conn.request_path do
          "/start" ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://localhost/final")
            |> Plug.Conn.send_resp(307, "Temporary Redirect body")

          "/final" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              429,
              Jason.encode!(%{
                "error" => %{
                  "type" => "insufficient_quota",
                  "code" => "insufficient_quota",
                  "message" => "out of credits"
                }
              })
            )
        end
      end)

      future = System.monotonic_time(:millisecond) + 5_000

      assert {:error, %Error{kind: :quota, status: 429}} =
               HTTP.stream_sse(
                 "http://localhost/start",
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, _ -> acc end,
                 [plug: {Req.Test, :http_sse_redirect_error}],
                 deadline: future
               )
    end

    test "malformed JSON with application/json classifies as :malformed_reply and non-200 HTML keeps HTTP status" do
      future = System.monotonic_time(:millisecond) + 5_000

      Req.Test.stub(:http_malformed_json_ct, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{bad")
      end)

      assert {:error, %Error{kind: :malformed_reply}} =
               OpenAI.complete([Message.user("hi")], [], %{
                 api_key: "k",
                 model: "gpt-5.4",
                 alloy_request_deadline: future,
                 req_options: [plug: {Req.Test, :http_malformed_json_ct}]
               })

      Req.Test.stub(:http_502_json_ct, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(502, "<html>Bad Gateway</html>")
      end)

      assert {:error, %Error{kind: :server_error, status: 502}} =
               OpenAI.complete([Message.user("hi")], [], %{
                 api_key: "k",
                 model: "gpt-5.4",
                 alloy_request_deadline: future,
                 req_options: [plug: {Req.Test, :http_502_json_ct}]
               })
    end
  end

  describe "hard wall-clock deadlines over TCP" do
    test "stream_sse drops incremental TCP chunks arriving past deadline" do
      test_pid = self()

      {url, _server} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"n\":1}\n\n")
          Process.sleep(1_200)
          send_http_chunk(sock, "data: {\"n\":2}\n\n")
          send_http_chunk(sock, "")
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               HTTP.stream_sse(
                 url,
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, %{data: data} ->
                   send(test_pid, {:sse_event, Jason.decode!(data)["n"]})
                   acc
                 end,
                 [receive_timeout: 5_000],
                 deadline: started + 700
               )

      assert_received {:sse_event, 1}
      refute_received {:sse_event, 2}
    end

    test "stream_sse stops dispatching additional events within a single chunk once deadline passes" do
      test_pid = self()

      {url, _server} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"n\":1}\n\ndata: {\"n\":2}\n\ndata: {\"n\":3}\n\n")
          send_http_chunk(sock, "")
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               HTTP.stream_sse(
                 url,
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, %{data: data} ->
                   n = Jason.decode!(data)["n"]
                   send(test_pid, {:multi_event, n})
                   Process.sleep(900)
                   acc
                 end,
                 [receive_timeout: 5_000],
                 deadline: started + 800
               )

      assert_received {:multi_event, 1}
      refute_received {:multi_event, 2}
      refute_received {:multi_event, 3}
    end

    test "stream_sse aborts stalled TCP streams at the absolute deadline" do
      test_pid = self()

      {url, _server} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"n\":1}\n\n")
          Process.sleep(5_000)
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               HTTP.stream_sse(
                 url,
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, %{data: data} ->
                   send(test_pid, {:stalled_event, Jason.decode!(data)["n"]})
                   acc
                 end,
                 [receive_timeout: 5_000],
                 deadline: started + 600
               )

      assert_received {:stalled_event, 1}
      assert System.monotonic_time(:millisecond) - started < 3_000
    end

    test "post_json aborts continuously trickling TCP responses at the absolute deadline" do
      {url, _server} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "application/json")
          send_http_chunk(sock, "{\"ok\":")

          Enum.each(1..30, fn _ ->
            Process.sleep(25)
            send_http_chunk(sock, " ")
          end)

          send_http_chunk(sock, "true}")
          send_http_chunk(sock, "")
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               HTTP.post_json(
                 url,
                 [],
                 %{},
                 [receive_timeout: 5_000],
                 deadline: started + 150
               )

      assert System.monotonic_time(:millisecond) - started < 2_500
    end

    test "streaming request under timeout_ms: 3_000 completes across a 1.15s pause without a 1s cutoff" do
      {url, _} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"choices\":[{\"delta\":{\"content\":\"hi \"}}]}\n\n")
          Process.sleep(1_150)

          send_http_chunk(
            sock,
            "data: {\"choices\":[{\"delta\":{\"content\":\"there\"},\"finish_reason\":\"stop\"}]}\n\n"
          )

          send_http_chunk(sock, "data: [DONE]\n\n")
          send_http_chunk(sock, "")
        end)

      assert {:ok, short_result} =
               Alloy.stream(
                 "go",
                 fn _ -> :ok end,
                 provider:
                   {OpenAICompat,
                    api_url: url, chat_path: "", model: "test", stream_options: false},
                 timeout_ms: 3_000
               )

      assert short_result.text == "hi there"
    end

    test "already-expired deadlines return :timeout immediately without invoking Req" do
      past = System.monotonic_time(:millisecond) - 10

      assert {:error, %Error{kind: :timeout}} =
               HTTP.post_json("http://127.0.0.1:1/", [], %{}, [bogus_req_opt: true],
                 deadline: past
               )

      assert {:error, %Error{kind: :timeout}} =
               HTTP.stream_sse(
                 "http://127.0.0.1:1/",
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, _ -> acc end,
                 [bogus_req_opt: true],
                 deadline: past
               )
    end
  end

  describe "cancellation, backpressure, shutdown, and context propagation" do
    test "killing caller mid-POST immediately closes the underlying TCP connection" do
      test_pid = self()

      {url, _} =
        start_tcp_http_server(fn sock ->
          send(test_pid, :post_connected)
          result = :gen_tcp.recv(sock, 0, 2_000)
          send(test_pid, {:post_server_saw, result})
        end)

      caller =
        spawn(fn ->
          HTTP.post_json(
            url,
            [],
            %{},
            [receive_timeout: 10_000],
            deadline: System.monotonic_time(:millisecond) + 10_000
          )
        end)

      assert_receive :post_connected, 1_500
      Process.exit(caller, :kill)
      assert_receive {:post_server_saw, {:error, :closed}}, 1_500
    end

    test "killing caller mid-SSE immediately closes the underlying TCP connection" do
      test_pid = self()

      {url, _} =
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"n\":1}\n\n")
          send(test_pid, :sse_connected)
          result = :gen_tcp.recv(sock, 0, 2_000)
          send(test_pid, {:sse_server_saw, result})
        end)

      caller =
        spawn(fn ->
          HTTP.stream_sse(
            url,
            [],
            %{},
            %{buffer: ""},
            fn acc, _ev -> acc end,
            [receive_timeout: 10_000],
            deadline: System.monotonic_time(:millisecond) + 10_000
          )
        end)

      assert_receive :sse_connected, 1_500
      Process.exit(caller, :kill)
      assert_receive {:sse_server_saw, {:error, :closed}}, 1_500
    end

    test "stream_sse enforces one-chunk-in-flight backpressure for slow consumers" do
      pushed = :atomics.new(1, signed: false)
      bp_id = "bp-#{System.unique_integer([:positive])}"
      bp_key = {__MODULE__, :backpressure_pushed, bp_id}
      :persistent_term.put(bp_key, pushed)
      on_exit(fn -> :persistent_term.erase(bp_key) end)

      {:ok, bp_acc} =
        HTTP.stream_sse(
          "http://localhost/backpressure",
          [{"x-bp-key", bp_id}],
          %{},
          %{buffer: "", count: 0, pushed_while_blocked: nil},
          fn acc, _ev ->
            if acc.count == 0 do
              Process.sleep(50)
              %{acc | count: 1, pushed_while_blocked: :atomics.get(pushed, 1)}
            else
              %{acc | count: acc.count + 1}
            end
          end,
          [adapter: BackpressureAdapter],
          deadline: System.monotonic_time(:millisecond) + 5_000
        )

      assert bp_acc.count == 25
      assert bp_acc.pushed_while_blocked == 1
    end

    test "programmer errors from Req still raise on deadline paths" do
      future = System.monotonic_time(:millisecond) + 5_000

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        HTTP.post_json("http://127.0.0.1:1/", [], %{}, [bogus_req_opt: true], deadline: future)
      end

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        HTTP.stream_sse(
          "http://127.0.0.1:1/",
          [],
          %{},
          %{buffer: ""},
          fn acc, _ -> acc end,
          [bogus_req_opt: true],
          deadline: future
        )
      end
    end

    test "caller Logger.metadata and OpenTelemetry context propagate into HTTP workers" do
      test_pid = self()
      future = System.monotonic_time(:millisecond) + 5_000
      logger_meta = [request_id: "req-42"]
      reset_meta = [request_id: nil]
      Logger.metadata(logger_meta)
      Process.put(:"$__current_otel_ctx", {:fake_otel_ctx, "span-99"})

      Req.Test.stub(:http_context_propagation, fn conn ->
        send(
          test_pid,
          {:worker_context, Logger.metadata()[:request_id], Process.get(:"$__current_otel_ctx")}
        )

        Req.Test.json(conn, %{"ok" => true})
      end)

      try do
        assert {:ok, _} =
                 HTTP.post_json(
                   "http://localhost/ctx",
                   [],
                   %{},
                   [plug: {Req.Test, :http_context_propagation}],
                   deadline: future
                 )

        assert_received {:worker_context, "req-42", {:fake_otel_ctx, "span-99"}}

        assert {:ok, _} =
                 HTTP.stream_sse(
                   "http://localhost/ctx",
                   [],
                   %{},
                   %{buffer: ""},
                   fn acc, _ -> acc end,
                   [plug: {Req.Test, :http_context_propagation}],
                   deadline: future
                 )

        assert_received {:worker_context, "req-42", {:fake_otel_ctx, "span-99"}}
      after
        Logger.metadata(reset_meta)
        Process.delete(:"$__current_otel_ctx")
      end
    end

    test "owner shutdown kills in-flight post_json and stream_sse workers and returns non-retryable error" do
      test_pid = self()
      future = System.monotonic_time(:millisecond) + 5_000

      post_probe_id = "post-shutdown-#{System.unique_integer([:positive])}"
      post_key = {__MODULE__, :shutdown_probe, post_probe_id}
      :persistent_term.put(post_key, test_pid)
      on_exit(fn -> :persistent_term.erase(post_key) end)

      post_task =
        Task.async(fn ->
          HTTP.post_json(
            "http://localhost/shutdown",
            [{"x-probe-id", post_probe_id}],
            %{},
            [adapter: ShutdownProbeAdapter],
            deadline: future
          )
        end)

      assert_receive {:shutdown_probe_started, post_owner, post_worker}, 1_000
      worker_ref = Process.monitor(post_worker)
      # Sync with post_worker so the monitor is installed before post_owner kills it.
      _ = Process.info(post_worker, :status)
      Process.exit(post_owner, :shutdown)
      assert_receive {:DOWN, ^worker_ref, :process, ^post_worker, :killed}, 1_000

      assert {:error, %Error{kind: :shutdown, message: post_msg} = post_err} =
               Task.await(post_task, 2_000)

      assert post_msg =~ "shutdown"
      refute Retry.retryable?(post_err)

      sse_probe_id = "sse-shutdown-#{System.unique_integer([:positive])}"
      sse_key = {__MODULE__, :shutdown_probe, sse_probe_id}
      :persistent_term.put(sse_key, test_pid)
      on_exit(fn -> :persistent_term.erase(sse_key) end)

      sse_task =
        Task.async(fn ->
          HTTP.stream_sse(
            "http://localhost/shutdown",
            [{"x-probe-id", sse_probe_id}],
            %{},
            %{buffer: ""},
            fn acc, _ -> acc end,
            [adapter: ShutdownProbeAdapter],
            deadline: future
          )
        end)

      assert_receive {:shutdown_probe_started, sse_owner, sse_worker}, 1_000
      sse_worker_ref = Process.monitor(sse_worker)
      _ = Process.info(sse_worker, :status)
      Process.exit(sse_owner, :shutdown)
      assert_receive {:DOWN, ^sse_worker_ref, :process, ^sse_worker, :killed}, 1_000

      assert {:error, %Error{kind: :shutdown, message: sse_msg} = sse_err} =
               Task.await(sse_task, 2_000)

      assert sse_msg =~ "shutdown"
      refute Retry.retryable?(sse_err)

      defmodule InWorkerShutdownAdapter do
        def run(_req), do: exit({:shutdown, :pool_stopped})
      end

      assert {:error, %Error{kind: :shutdown}} =
               HTTP.post_json(
                 "http://localhost/shutdown",
                 [],
                 %{},
                 [adapter: InWorkerShutdownAdapter],
                 deadline: future
               )
    end

    test "custom providers forwarding config.req_options directly to Req work without unknown-option errors" do
      Req.Test.stub(:http_custom_req_provider, fn conn ->
        Req.Test.json(conn, %{"reply" => "from custom provider"})
      end)

      assert {:ok, result} =
               Alloy.run("hi",
                 provider:
                   {CustomReqProvider, req_options: [plug: {Req.Test, :http_custom_req_provider}]}
               )

      assert result.text == "from custom provider"
    end

    test "timeout and SSE abort cancellation kill exit-trapping workers" do
      test_pid = self()
      probe_id = "trap-exit-#{System.unique_integer([:positive])}"
      key = {__MODULE__, :shutdown_probe, probe_id}
      :persistent_term.put(key, test_pid)
      on_exit(fn -> :persistent_term.erase(key) end)

      # Repeatedly exercise the shared-deadline race between caller and owner.
      for _ <- 1..5 do
        deadline = System.monotonic_time(:millisecond) + 40

        task =
          Task.async(fn ->
            HTTP.post_json(
              "http://localhost/timeout",
              [{"x-probe-id", probe_id}, {"x-trap-exit", "true"}],
              %{},
              [adapter: ShutdownProbeAdapter],
              deadline: deadline
            )
          end)

        assert_receive {:shutdown_probe_started, _owner, worker}, 1_000
        ref = Process.monitor(worker)
        assert {:error, %Error{kind: :timeout}} = Task.await(task, 2_000)
        refute Process.alive?(worker)
        assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
      end

      # SSE timeout cancellation also kills an exit-trapping worker.
      sse_deadline = System.monotonic_time(:millisecond) + 40

      sse_task =
        Task.async(fn ->
          HTTP.stream_sse(
            "http://localhost/timeout",
            [{"x-probe-id", probe_id}, {"x-trap-exit", "true"}],
            %{},
            %{buffer: ""},
            fn acc, _ -> acc end,
            [adapter: ShutdownProbeAdapter],
            deadline: sse_deadline
          )
        end)

      assert_receive {:shutdown_probe_started, _owner, sse_worker}, 1_000
      sse_ref = Process.monitor(sse_worker)
      assert {:error, %Error{kind: :timeout}} = Task.await(sse_task, 2_000)
      refute Process.alive?(sse_worker)
      assert_receive {:DOWN, ^sse_ref, :process, ^sse_worker, _reason}, 1_000

      # SSE callback abort also kills an exit-trapping worker.
      future = System.monotonic_time(:millisecond) + 5_000

      assert :abort_sse =
               catch_throw(
                 HTTP.stream_sse(
                   "http://localhost/abort",
                   [{"x-probe-id", probe_id}, {"x-trap-exit", "true"}, {"x-emit-chunk", "true"}],
                   %{},
                   %{buffer: ""},
                   fn _acc, _event -> throw(:abort_sse) end,
                   [adapter: ShutdownProbeAdapter],
                   deadline: future
                 )
               )

      assert_receive {:shutdown_probe_started, _owner, abort_worker}, 1_000
      refute Process.alive?(abort_worker)
      abort_ref = Process.monitor(abort_worker)
      assert_receive {:DOWN, ^abort_ref, :process, ^abort_worker, _reason}, 1_000
    end

    test "join_url/2 normalizes leading-slash, relative, and empty paths" do
      assert HTTP.join_url("https://host/v1/", "/chat/completions") ==
               "https://host/v1/chat/completions"

      assert HTTP.join_url("https://host/v1", "/chat/completions") ==
               "https://host/v1/chat/completions"

      assert HTTP.join_url("https://host/v1/", "chat/completions") ==
               "https://host/v1/chat/completions"

      assert HTTP.join_url("https://host/v1", "chat/completions") ==
               "https://host/v1/chat/completions"

      assert HTTP.join_url("https://host/v1/chat/completions", "") ==
               "https://host/v1/chat/completions"

      assert HTTP.join_url("https://host/v1/chat/completions/", "") ==
               "https://host/v1/chat/completions/"
    end

    test "worker crash propagates abnormal exit to linked children before re-raising" do
      test_pid = self()
      probe_id = "crash-child-#{System.unique_integer([:positive])}"
      key = {__MODULE__, :crash_probe, probe_id}
      :persistent_term.put(key, test_pid)
      on_exit(fn -> :persistent_term.erase(key) end)

      future = System.monotonic_time(:millisecond) + 5_000

      assert_raise RuntimeError, "adapter boom", fn ->
        HTTP.post_json(
          "http://localhost/crash",
          [{"x-probe-id", probe_id}],
          %{},
          [adapter: LinkedChildCrashAdapter],
          deadline: future
        )
      end

      assert_receive {:linked_child_started, child}, 1_000
      ref = Process.monitor(child)
      assert_receive {:DOWN, ^ref, :process, ^child, _reason}, 1_000
    end

    test "worker exiting :normal returns a typed error instead of terminating the caller" do
      future = System.monotonic_time(:millisecond) + 5_000

      assert {:error, %Error{kind: :unknown, message: msg}} =
               HTTP.post_json(
                 "http://localhost/normal-exit",
                 [],
                 %{},
                 [adapter: NormalExitAdapter],
                 deadline: future
               )

      assert msg =~ "exited normally without a reply"
    end

    test "SSE event handler crash halts the stream early on both paths and sanitizes stacktrace args" do
      test_pid = self()

      # Use a real chunked TCP stream where chunk 2 is held behind a 5_000 ms
      # gate that is stopped as soon as stream_sse/7 returns. Returning before
      # the gate expires proves Req halted the stream on chunk 1 instead of
      # draining subsequent chunks.
      start_gated_sse_server = fn tag ->
        start_tcp_http_server(fn sock ->
          send_http_chunked_headers(sock, "text/event-stream")
          send_http_chunk(sock, "data: {\"n\":1}\n\n")

          receive do
            :stop -> :ok
          after
            5_000 ->
              send(test_pid, {:gate_expired, tag})
              send_http_chunk(sock, "data: {\"n\":2}\n\n")
              send_http_chunk(sock, "")
          end
        end)
      end

      # Trigger both a FunctionClauseError (arguments in __STACKTRACE__) and a
      # MatchError (offending accumulator term in Exception.message/1) to verify
      # neither logs nor returned error messages leak accumulator values.
      strict_fn = fn %{never_matches: true}, _event -> :ok end

      clause_crash_handler = fn acc, %{data: data} = event ->
        case Jason.decode!(data)["n"] do
          1 ->
            strict_fn.(acc, event)

          2 ->
            send(test_pid, :second_event_processed)
            acc
        end
      end

      match_crash_handler = fn acc, %{data: data} ->
        case Jason.decode!(data)["n"] do
          1 ->
            %{never_matches: true} = acc
            acc

          2 ->
            send(test_pid, :second_event_processed)
            acc
        end
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {url1, pid1} = start_gated_sse_server.(:no_deadline)

          assert {:error, %Error{kind: :unknown, message: msg1}} =
                   HTTP.stream_sse(
                     url1,
                     [],
                     %{},
                     %{buffer: "", secret: "SUPER_SECRET_ACCUMULATOR_TOKEN"},
                     clause_crash_handler,
                     retry: false
                   )

          send(pid1, :stop)
          assert msg1 == "SSE event handler failed: FunctionClauseError"
          refute_received {:gate_expired, :no_deadline}

          {url2, pid2} = start_gated_sse_server.(:with_deadline)

          assert {:error, %Error{kind: :unknown, message: msg2}} =
                   HTTP.stream_sse(
                     url2,
                     [],
                     %{},
                     %{buffer: "", secret: "SUPER_SECRET_ACCUMULATOR_TOKEN"},
                     match_crash_handler,
                     [retry: false],
                     deadline: System.monotonic_time(:millisecond) + 5_000
                   )

          send(pid2, :stop)
          assert msg2 == "SSE event handler failed: MatchError"
          refute_received {:gate_expired, :with_deadline}
        end)

      assert log =~ "SSE event handler crashed (FunctionClauseError)"
      assert log =~ "SSE event handler crashed (MatchError)"
      refute log =~ "SUPER_SECRET_ACCUMULATOR_TOKEN"
      refute_received :second_event_processed
    end

    test "re-raised worker FunctionClauseError under :deadline strips stacktrace arguments" do
      defmodule ClauseCrashAdapter do
        def run(req), do: crash_with_secret(req.headers)
        defp crash_with_secret(%{"never" => :matches}), do: :ok
      end

      future = System.monotonic_time(:millisecond) + 5_000

      try do
        HTTP.post_json(
          "http://localhost/clause-crash",
          [{"authorization", "Bearer SUPER_SECRET_BEARER_TOKEN"}],
          %{},
          [adapter: ClauseCrashAdapter],
          deadline: future
        )

        flunk("expected FunctionClauseError to be re-raised")
      rescue
        e in FunctionClauseError ->
          formatted = Exception.format_stacktrace(__STACKTRACE__)
          assert Exception.message(e) =~ "crash_with_secret"
          refute formatted =~ "SUPER_SECRET_BEARER_TOKEN"
      end
    end

    test "external worker kill and linked-process crashes under :deadline return sanitized :unknown errors on both post_json and stream_sse" do
      defmodule ExternalKillAdapter do
        def run(_req) do
          Process.exit(self(), :kill)
        end
      end

      defmodule LinkedSecretCrashAdapter do
        def run(_req) do
          spawn_link(fn ->
            secret = "SUPER_SECRET_BEARER_TOKEN"
            :never_matches = %{token: secret}
          end)

          receive do
            :never -> :ok
          end
        end
      end

      future = System.monotonic_time(:millisecond) + 5_000

      assert {:error, %Error{kind: :unknown, message: msg1}} =
               HTTP.post_json(
                 "http://localhost/external-kill",
                 [],
                 %{},
                 [adapter: ExternalKillAdapter],
                 deadline: future
               )

      assert msg1 == "HTTP worker exited unexpectedly: :killed"

      assert {:error, %Error{kind: :unknown, message: msg2}} =
               HTTP.stream_sse(
                 "http://localhost/external-kill-sse",
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, _ -> acc end,
                 [adapter: ExternalKillAdapter],
                 deadline: future
               )

      assert msg2 == "HTTP worker exited unexpectedly: :killed"

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{kind: :unknown, message: msg3}} =
                 HTTP.post_json(
                   "http://localhost/linked-secret-crash",
                   [],
                   %{},
                   [adapter: LinkedSecretCrashAdapter],
                   deadline: future
                 )

        assert msg3 =~ "HTTP worker exited unexpectedly:"
        refute msg3 =~ "SUPER_SECRET_BEARER_TOKEN"
      end)
    end

    test "non-200 SSE error stream halts early at 64 KiB on both no-deadline and :deadline paths" do
      test_pid = self()

      start_huge_500_server = fn tag ->
        start_tcp_http_server(fn sock ->
          :gen_tcp.send(
            sock,
            "HTTP/1.1 500 Internal Server Error\r\ncontent-type: text/plain\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
          )

          # Send 80 KiB in chunks, then wait behind a 5s gate that must never expire.
          chunk_16k = String.duplicate("E", 16_384)

          for _ <- 1..5 do
            send_http_chunk(sock, chunk_16k)
          end

          receive do
            :stop -> :ok
          after
            5_000 ->
              send(test_pid, {:error_stream_gate_expired, tag})
              send_http_chunk(sock, "")
          end
        end)
      end

      {url1, pid1} = start_huge_500_server.(:no_deadline)

      assert {:error, %Error{kind: :server_error, status: 500, message: m1}} =
               HTTP.stream_sse(url1, [], %{}, %{buffer: ""}, fn acc, _ -> acc end, retry: false)

      send(pid1, :stop)
      assert byte_size(m1) == 2_000
      refute_received {:error_stream_gate_expired, :no_deadline}

      {url2, pid2} = start_huge_500_server.(:with_deadline)

      assert {:error, %Error{kind: :server_error, status: 500, message: m2}} =
               HTTP.stream_sse(
                 url2,
                 [],
                 %{},
                 %{buffer: ""},
                 fn acc, _ -> acc end,
                 [retry: false],
                 deadline: System.monotonic_time(:millisecond) + 5_000
               )

      send(pid2, :stop)
      assert byte_size(m2) == 2_000
      refute_received {:error_stream_gate_expired, :with_deadline}

      # Pin the exact 64 KiB (65_536-byte) accumulation boundary in SSE.append_error_chunk/3.
      resp0 = %{private: %{}}

      {:cont, {:req, resp1}} =
        SSE.append_error_chunk(String.duplicate("a", 65_535), :req, resp0)

      assert resp1.private.sse_error_body_size == 65_535
      {:halt, {:req, resp2}} = SSE.append_error_chunk("bcde", :req, resp1)
      assert resp2.private.sse_error_body_size == 65_536

      assert IO.iodata_to_binary(resp2.private.sse_error_body) ==
               String.duplicate("a", 65_535) <> "b"

      # Further chunks once full halt immediately without growing the buffer.
      {:halt, {:req, resp3}} = SSE.append_error_chunk("more", :req, resp2)
      assert resp3.private.sse_error_body_size == 65_536
    end

    test "OwnedWorker.format_exit_reason/1 sanitizes exception payloads and exit tuples" do
      alias Alloy.OwnedWorker

      assert OwnedWorker.format_exit_reason(:killed) == ":killed"
      assert OwnedWorker.format_exit_reason({:shutdown, :closed}) == "{:shutdown, :closed}"
      assert OwnedWorker.format_exit_reason({:shutdown, %{secret: 1}}) == "{:shutdown, ...}"

      assert OwnedWorker.format_exit_reason({%RuntimeError{message: "secret"}, []}) ==
               "RuntimeError"

      assert OwnedWorker.format_exit_reason(%RuntimeError{message: "secret"}) == "RuntimeError"
      assert OwnedWorker.format_exit_reason({:noproc, []}) == ":noproc"
      assert OwnedWorker.format_exit_reason({{:badmatch, "secret"}, []}) == "unexpected tuple"

      assert OwnedWorker.format_exit_reason(
               {:timeout, {GenServer, :call, [self(), {:secret, "sk-123"}, 100]}}
             ) == ":timeout"
    end
  end

  defp start_tcp_http_server(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, sock} ->
            _ = read_http_headers(sock, "")
            handler.(sock)
            :gen_tcp.close(sock)

          {:error, _} ->
            :ok
        end

        :gen_tcp.close(listen)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    {"http://127.0.0.1:#{port}/test", pid}
  end

  defp read_http_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(sock, 0, 1_000) do
        {:ok, data} -> read_http_headers(sock, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp send_http_chunked_headers(sock, content_type) do
    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
    )
  end

  defp send_http_chunk(sock, "") do
    :gen_tcp.send(sock, "0\r\n\r\n")
  end

  defp send_http_chunk(sock, data) do
    size = data |> byte_size() |> Integer.to_string(16)
    :gen_tcp.send(sock, "#{size}\r\n#{data}\r\n")
  end
end
