defmodule Alloy.Provider.RetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias Alloy.Provider.{Error, OpenAICompat, Retry}
  alias Alloy.Provider.Test, as: TestProvider

  defmodule CompleteOnlyFallback do
    @behaviour Alloy.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("from complete-only fallback")],
         usage: %{input_tokens: 1, output_tokens: 1},
         provider_state: %{leaked_id: "should_not_merge"}
       }}
    end
  end

  defmodule FailingPrimary do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, _c), do: {:error, %Error{kind: :overloaded, message: "busy"}}
    @impl true
    def stream(_m, _t, _c, _cb), do: {:error, %Error{kind: :overloaded, message: "busy"}}
  end

  defmodule CaptureTimeoutProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, config) do
      send(config.owner, {:timeout, Keyword.get(config.req_options, :receive_timeout)})
      {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("ok")], usage: %{}}}
    end
  end

  defmodule SlowBeforeMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_completion, state) do
      Process.sleep(250)
      state
    end

    def call(_hook, state), do: state
  end

  defmodule CaptureBudgetProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, config) do
      now = System.monotonic_time(:millisecond)

      send(
        config.owner,
        {:captured_budget, config.req_options, config[:alloy_request_deadline] - now}
      )

      {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("ok")], usage: %{}}}
    end
  end

  defmodule CaptureStreamBudgetProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, _c), do: {:error, "unused"}

    @impl true
    def stream(_m, _t, config, on_chunk) do
      send(
        config.owner,
        {:stream_receive_timeout, Keyword.fetch!(config.req_options, :receive_timeout)}
      )

      on_chunk.("ok")
      {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("ok")], usage: %{}}}
    end
  end

  defmodule Http2TotalTimerAdapter do
    def run(req) do
      total_timeout = Map.fetch!(req.options, :receive_timeout)
      started = System.monotonic_time(:millisecond)
      resp = Req.Response.new(status: 200)

      {req, resp} =
        case req.into.(
               {:data, "data: {\"choices\":[{\"delta\":{\"content\":\"h2 \"}}]}\n\n"},
               {req, resp}
             ) do
          {:cont, st} -> st
          {:halt, st} -> st
        end

      Process.sleep(3_200)

      if System.monotonic_time(:millisecond) - started > total_timeout do
        {req, %Mint.TransportError{reason: :timeout}}
      else
        {req, resp} =
          case req.into.(
                 {:data,
                  "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"},
                 {req, resp}
               ) do
            {:cont, st} -> st
            {:halt, st} -> st
          end

        {req, resp}
      end
    end
  end

  defmodule MultiChunkStreamProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, _c), do: {:error, "unused"}

    @impl true
    def stream(_m, _t, _c, on_chunk) do
      Enum.each(["a", "b", "c", "d", "e"], on_chunk)
      {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("abcde")], usage: %{}}}
    end
  end

  describe "retryable?/1 with Alloy.Provider.Error" do
    test "retries transient kinds" do
      for kind <- [
            :rate_limited,
            :overloaded,
            :server_error,
            :timeout,
            :network,
            :malformed_reply
          ] do
        assert Retry.retryable?(%Error{kind: kind, message: "x"})
      end
    end

    test "does not retry quota, auth, overflow or invalid requests" do
      for kind <- [:quota, :auth, :context_overflow, :invalid_request, :unknown] do
        refute Retry.retryable?(%Error{kind: kind, message: "x"})
      end
    end
  end

  describe "retryable?/1" do
    # HTTP status errors
    test "408 request timeout is retryable" do
      assert Retry.retryable?("HTTP 408: Request Timeout")
    end

    test "429 rate limit is retryable" do
      assert Retry.retryable?("HTTP 429: Too Many Requests")
    end

    test "500 server error is retryable" do
      assert Retry.retryable?("HTTP 500: Internal Server Error")
    end

    test "502 bad gateway is retryable" do
      assert Retry.retryable?("HTTP 502: Bad Gateway")
    end

    test "503 service unavailable is retryable" do
      assert Retry.retryable?("HTTP 503: Service Unavailable")
    end

    test "504 gateway timeout is retryable" do
      assert Retry.retryable?("HTTP 504: Gateway Timeout")
    end

    test "400 bad request is not retryable" do
      refute Retry.retryable?("HTTP 400: Bad Request")
    end

    test "401 unauthorized is not retryable" do
      refute Retry.retryable?("HTTP 401: Unauthorized")
    end

    # Provider-specific error formats
    test "Anthropic rate_limit_error is retryable" do
      assert Retry.retryable?("rate_limit_error: rate limited")
    end

    test "OpenAI rate_limit_exceeded is retryable" do
      assert Retry.retryable?("rate_limit_exceeded: quota exceeded")
    end

    test "Anthropic overloaded_error is retryable" do
      assert Retry.retryable?("overloaded_error: model overloaded")
    end

    test "OpenAI server_error is retryable" do
      assert Retry.retryable?("server_error: internal error")
    end

    # Google Gemini errors
    test "Gemini RESOURCE_EXHAUSTED is retryable" do
      assert Retry.retryable?("RESOURCE_EXHAUSTED: quota exceeded")
    end

    test "Gemini INTERNAL is retryable" do
      assert Retry.retryable?("INTERNAL: server error")
    end

    test "Gemini UNAVAILABLE is retryable" do
      assert Retry.retryable?("UNAVAILABLE: service down")
    end

    # Network failures
    test "econnrefused is retryable" do
      assert Retry.retryable?("HTTP request failed: econnrefused")
    end

    test "connection closed is retryable" do
      assert Retry.retryable?("HTTP request failed: closed")
    end

    test "timeout in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: timeout")
    end

    test "unprocessed in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: unprocessed")
    end

    test "atom :timeout is retryable" do
      assert Retry.retryable?(:timeout)
    end

    # Non-retryable
    test "unknown string error is not retryable" do
      refute Retry.retryable?("unknown error")
    end

    test "atom :badarg is not retryable" do
      refute Retry.retryable?(:badarg)
    end

    test "nil is not retryable" do
      refute Retry.retryable?(nil)
    end
  end

  describe "call_with_retry/6" do
    test "returns success on first try" do
      config = retry_config()
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      provider = success_provider()

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:ok, %{stop_reason: :end_turn}} = result
    end

    test "retries on retryable error and succeeds" do
      config = retry_config(max_retries: 2, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      # Use an agent to track call count
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      provider = counting_provider(counter, 1)

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:ok, %{stop_reason: :end_turn}} = result
      assert Agent.get(counter, & &1) == 2
    end

    test "returns error after exhausting retries" do
      config = retry_config(max_retries: 1, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      provider = always_fail_provider()

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:error, "HTTP 500: Server Error"} = result
    end

    test "does not retry non-retryable errors" do
      config = retry_config(max_retries: 3, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      provider = non_retryable_fail_provider(counter)

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:error, "HTTP 401: Unauthorized"} = result
      # Should only be called once (no retries)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "call_with_retry/6 with structured errors" do
    test "malformed replies retry within the configured attempt limit" do
      error = %Error{kind: :malformed_reply, message: "empty tool_use"}
      provider = scripted_provider([{:error, error}, :ok])
      state = build_state(retry_config(max_retries: 1, retry_backoff_ms: 1))
      deadline = System.monotonic_time(:millisecond) + 5_000

      assert {:ok, _} =
               Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, deadline)

      provider = scripted_provider([{:error, error}, {:error, error}, :ok])

      assert {:error, ^error} =
               Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, deadline)
    end

    test "waits at least retry_after_ms before retrying" do
      rate_limited = %Error{kind: :rate_limited, message: "slow", retry_after_ms: 150}
      provider = scripted_provider([{:error, rate_limited}, :ok])
      state = build_state(retry_config(max_retries: 1, retry_backoff_ms: 1))
      deadline = System.monotonic_time(:millisecond) + 10_000

      started = System.monotonic_time(:millisecond)
      result = Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, deadline)

      assert {:ok, _} = result
      assert System.monotonic_time(:millisecond) - started >= 150
    end

    test "gives up at once when retry_after_ms would overshoot the deadline" do
      retry_at = DateTime.add(DateTime.utc_now(), 60, :second)

      rate_limited =
        Error.from_response(
          429,
          %{"retry-after" => [Calendar.strftime(retry_at, "%a, %d %b %Y %H:%M:%S GMT")]},
          "slow"
        )

      provider = scripted_provider([{:error, rate_limited}, :ok])
      state = build_state(retry_config(max_retries: 3, retry_backoff_ms: 1))
      deadline = System.monotonic_time(:millisecond) + 2_000

      started = System.monotonic_time(:millisecond)
      result = Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, deadline)

      assert {:error, %Error{kind: :rate_limited}} = result
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "does not retry a quota error" do
      quota =
        Error.from_response(429, %{}, %{
          "error" => %{
            "type" => "rate_limit_error",
            "code" => "subscription_sharing_usage_limit_exceeded",
            "message" => "quota exhausted"
          }
        })

      provider = scripted_provider([{:error, quota}, :ok])
      state = build_state(retry_config(max_retries: 3, retry_backoff_ms: 1))
      deadline = System.monotonic_time(:millisecond) + 10_000

      assert {:error, ^quota} =
               Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, deadline)
    end
  end

  describe "streaming callbacks that raise" do
    import ExUnit.CaptureLog
    import Alloy.StreamTestHelpers

    setup do
      Req.Test.stub(
        __MODULE__,
        sse_chunks_plug([
          sse_text_delta("A"),
          sse_text_delta("B"),
          sse_text_delta("C"),
          sse_finish("stop"),
          "data: [DONE]\n\n"
        ])
      )

      provider =
        {Alloy.Provider.OpenAICompat,
         api_url: "http://localhost",
         model: "test-model",
         req_options: [plug: {Req.Test, __MODULE__}, retry: false]}

      %{provider: provider}
    end

    test "a raising on_chunk is logged and the full text is kept", %{provider: provider} do
      on_chunk = fn
        "B" -> raise "UI went away"
        _chunk -> :ok
      end

      log =
        capture_log(fn ->
          send(self(), {:result, Alloy.stream("hi", on_chunk, provider: provider)})
        end)

      assert_received {:result, {:ok, result}}
      assert result.text == "ABC"
      assert log =~ "on_chunk callback failed"
      assert log =~ "UI went away"
    end

    test "a raising on_event is logged and the full text is kept", %{provider: provider} do
      on_event = fn
        %{event: :text_delta, payload: "B"} -> raise "liveview_down"
        _envelope -> :ok
      end

      log =
        capture_log(fn ->
          send(
            self(),
            {:result, Alloy.stream("hi", fn _ -> :ok end, provider: provider, on_event: on_event)}
          )
        end)

      assert_received {:result, {:ok, result}}
      assert result.text == "ABC"
      assert log =~ "on_event callback failed"
      assert log =~ "liveview_down"
    end

    # Only raised exceptions (a bug in the UI callback) are absorbed. A throw
    # or exit is deliberate control flow and stops the stream, as in 0.12.4.
    test "a throw from on_chunk still aborts the stream", %{provider: provider} do
      on_chunk = fn
        "B" -> throw(:user_cancelled)
        _chunk -> :ok
      end

      assert catch_throw(Alloy.stream("hi", on_chunk, provider: provider)) == :user_cancelled
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # A provider that returns `responses` in order; `:ok` is a plain success.
  defp scripted_provider(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.ScriptedProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          case Agent.get_and_update(unquote(agent), fn [next | rest] -> {next, rest} end) do
            :ok -> {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
            error -> error
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp retry_config(overrides \\ []) do
    defaults = [
      max_retries: 3,
      retry_backoff_ms: 1,
      fallback_providers: []
    ]

    merged = Keyword.merge(defaults, overrides)

    %Alloy.Agent.Config{
      provider: Alloy.Provider.Test,
      provider_config: %{},
      max_retries: merged[:max_retries],
      retry_backoff_ms: merged[:retry_backoff_ms],
      fallback_providers: merged[:fallback_providers]
    }
  end

  defp build_state(config) do
    State.init(config, [Message.user("test")])
  end

  defp success_provider do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.SuccessProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp always_fail_provider do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.AlwaysFailProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          {:error, "HTTP 500: Server Error"}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp counting_provider(counter, fail_count) do
    # Use Agent to track state across calls
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.CountingProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          count = Agent.get_and_update(unquote(counter), fn c -> {c, c + 1} end)

          if count < unquote(fail_count) do
            {:error, "HTTP 500: Server Error"}
          else
            {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  describe "fallback streaming, budgets, and callback resilience" do
    test "streaming fallback to a provider without stream/4 uses complete/3 and isolates provider_state" do
      assert {:ok, result} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider: {FailingPrimary, model: "p", provider_state: %{primary_id: "p1"}},
                 max_retries: 0,
                 fallback_providers: [{CompleteOnlyFallback, %{model: "fb"}}]
               )

      assert result.text == "from complete-only fallback"
      assert result.metadata.provider_state == %{primary_id: "p1"}
    end

    test "receive_timeout uses remaining deadline without 1_000ms overshoot floor" do
      test_pid = self()
      config = %Config{provider: CaptureTimeoutProvider, provider_config: %{owner: test_pid}}
      state = State.init(config, [Message.user("hi")])
      deadline = System.monotonic_time(:millisecond) + 350

      assert {:ok, _} =
               Retry.call_with_retry(
                 state,
                 CaptureTimeoutProvider,
                 %{owner: test_pid},
                 false,
                 fn _ -> :ok end,
                 deadline
               )

      assert_received {:timeout, timeout}
      assert timeout > 0 and timeout <= 350
    end

    test "retry_backoff_ms: 0 retries immediately without crashing :rand.uniform(0)" do
      {:ok, pid} =
        TestProvider.start_link([
          {:error, %Error{kind: :overloaded, message: "busy"}},
          TestProvider.text_response("recovered")
        ])

      assert {:ok, result} =
               Alloy.run("hi",
                 provider: {TestProvider, agent_pid: pid},
                 max_retries: 2,
                 retry_backoff_ms: 0
               )

      assert result.text == "recovered"
    end

    test "request budgets scale monotonically across short and headroom timeouts and never renew expired budgets" do
      test_pid = self()

      assert {:ok, _} =
               Alloy.run("go",
                 provider: {CaptureBudgetProvider, owner: test_pid},
                 middleware: [SlowBeforeMiddleware],
                 timeout_ms: 500
               )

      assert_received {:captured_budget, req_options, deadline_remaining}
      receive_timeout = Keyword.fetch!(req_options, :receive_timeout)
      assert receive_timeout > 0 and receive_timeout <= 300
      assert deadline_remaining > 0 and deadline_remaining <= 300
      refute Keyword.has_key?(req_options, :stream_deadline)

      budgets =
        for timeout_ms <- [3_000, 4_000, 5_000, 5_200, 6_000, 8_000, 10_000] do
          assert {:ok, _} =
                   Alloy.run("go",
                     provider: {CaptureBudgetProvider, owner: test_pid},
                     timeout_ms: timeout_ms
                   )

          assert_received {:captured_budget, opts, remaining}
          {timeout_ms, Keyword.fetch!(opts, :receive_timeout), remaining}
        end

      [{3_000, recv_3000, rem_3000} | _] = budgets
      assert recv_3000 >= 2_500 and recv_3000 <= 3_000
      assert rem_3000 >= 2_500 and rem_3000 <= 3_000

      budgets
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{t1, recv1, rem1}, {t2, recv2, rem2}] ->
        assert recv2 >= recv1 - 50,
               "receive_timeout shrank from #{recv1}ms (timeout_ms: #{t1}) to #{recv2}ms (timeout_ms: #{t2})"

        assert rem2 >= rem1 - 50,
               "request deadline shrank from #{rem1}ms (timeout_ms: #{t1}) to #{rem2}ms (timeout_ms: #{t2})"
      end)

      expired_state =
        State.init(
          %Config{provider: CaptureBudgetProvider, provider_config: %{owner: test_pid}},
          [Message.user("hi")]
        )

      past = System.monotonic_time(:millisecond) - 10

      assert {:error, %Error{kind: :timeout}} =
               Retry.call_with_retry(
                 expired_state,
                 CaptureBudgetProvider,
                 %{owner: test_pid, alloy_request_deadline: past},
                 false,
                 fn _ -> :ok end,
                 past - 5_000
               )

      refute_received {:captured_budget, _, _}
    end

    test "streaming requests receive full remaining run budget (avoiding premature timeouts under total-request timers)" do
      test_pid = self()

      assert {:ok, _} =
               Alloy.stream("go", fn _ -> :ok end,
                 provider: {CaptureStreamBudgetProvider, owner: test_pid},
                 timeout_ms: 6_000
               )

      assert_received {:stream_receive_timeout, stream_recv_6000}
      assert stream_recv_6000 >= 5_500 and stream_recv_6000 <= 6_000

      assert {:ok, h2_result} =
               Alloy.stream("go", fn _ -> :ok end,
                 provider:
                   {OpenAICompat,
                    api_url: "http://localhost",
                    model: "test",
                    stream_options: false,
                    req_options: [adapter: Http2TotalTimerAdapter]},
                 timeout_ms: 6_000
               )

      assert h2_result.text == "h2 ok"
    end

    test "suppresses repeated warnings when streaming on_chunk raises across multiple chunks" do
      log =
        capture_log(fn ->
          assert {:ok, result} =
                   Alloy.stream("hi", fn _chunk -> raise "ui chunk boom" end,
                     provider: MultiChunkStreamProvider
                   )

          assert result.text == "abcde"
        end)

      assert length(Regex.scan(~r/on_chunk callback failed/, log)) == 1
    end

    test "strips callback arguments from FunctionClauseError logs on streaming on_chunk failure" do
      defmodule SecretChunkStreamProvider do
        @behaviour Alloy.Provider

        @impl true
        def complete(_messages, _tools, _config),
          do: {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}

        @impl true
        def stream(_messages, _tools, _config, on_chunk) do
          on_chunk.("SECRET_STREAMED_DELTA_TOKEN")

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("SECRET_STREAMED_DELTA_TOKEN")],
             usage: %{}
           }}
        end
      end

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   Alloy.stream("hi", fn "never_matches" -> :ok end,
                     provider: SecretChunkStreamProvider
                   )

          assert result.text == "SECRET_STREAMED_DELTA_TOKEN"
        end)

      assert log =~ "on_chunk callback failed"
      refute log =~ "SECRET_STREAMED_DELTA_TOKEN"
    end

    test "skips fallback providers on :shutdown (primary or fallback) while still falling back on provider code \"shutdown\"" do
      defmodule ShutdownErrorProvider do
        @behaviour Alloy.Provider

        alias Alloy.Provider.Error

        @impl true
        def complete(_messages, _tools, _config) do
          {:error, %Error{kind: :shutdown, message: "HTTP request interrupted by shutdown"}}
        end
      end

      defmodule UpstreamShutdownCodeProvider do
        @behaviour Alloy.Provider

        alias Alloy.Provider.Error

        @impl true
        def complete(_messages, _tools, _config) do
          {:error,
           Error.from_response(
             500,
             %{},
             %{"error" => %{"code" => "shutdown", "message" => "upstream rebooting"}}
           )}
        end
      end

      {:ok, fallback_counter} = Agent.start_link(fn -> 0 end)
      fallback_mod = non_retryable_fail_provider(fallback_counter)

      # Primary :shutdown skips fallback providers entirely.
      assert {:error, %{status: :error, error: err_msg}} =
               Alloy.run("hi",
                 provider: {ShutdownErrorProvider, []},
                 fallback_providers: [{fallback_mod, []}],
                 max_retries: 1,
                 retry_backoff_ms: 0
               )

      assert err_msg =~ "interrupted by shutdown"
      assert Agent.get(fallback_counter, & &1) == 0

      # Fallback #1 returning :shutdown halts immediately without invoking fallback #2.
      {:ok, primary_counter} = Agent.start_link(fn -> 0 end)
      primary_fail = non_retryable_fail_provider(primary_counter)

      assert {:error, %{status: :error, error: fb_err}} =
               Alloy.run("hi",
                 provider: {primary_fail, []},
                 fallback_providers: [{ShutdownErrorProvider, []}, {fallback_mod, []}],
                 max_retries: 0
               )

      assert fb_err =~ "interrupted by shutdown"
      assert Agent.get(fallback_counter, & &1) == 0

      # A provider payload carrying code: "shutdown" is NOT :shutdown kind and still reaches fallbacks.
      assert {:error, %{status: :error}} =
               Alloy.run("hi",
                 provider: {UpstreamShutdownCodeProvider, []},
                 fallback_providers: [{fallback_mod, []}],
                 max_retries: 0
               )

      assert Agent.get(fallback_counter, & &1) == 1
    end

    test "aborts immediately when timeout_ms: :infinity encounters a Retry-After over 60s" do
      rate_limited = Error.from_response(429, %{"retry-after" => ["3600"]}, "wait an hour")
      provider = scripted_provider([{:error, rate_limited}, :ok])
      state = build_state(retry_config(max_retries: 2, retry_backoff_ms: 1))

      started = System.monotonic_time(:millisecond)
      result = Retry.call_with_retry(state, provider, %{}, false, fn _ -> :ok end, nil)

      assert {:error, %Error{kind: :rate_limited, retry_after_ms: 3_600_000}} = result
      assert System.monotonic_time(:millisecond) - started < 1_000
    end
  end

  defp non_retryable_fail_provider(counter) do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.NonRetryableProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          Agent.update(unquote(counter), &(&1 + 1))
          {:error, "HTTP 401: Unauthorized"}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end
end
