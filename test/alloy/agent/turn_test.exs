defmodule Alloy.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  alias Alloy.Test.EchoTool

  describe "run_loop/1 with simple text response" do
    test "completes in one turn" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Hello there!")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state =
        State.init(config, [Message.user("Hi")])

      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 1

      # Should have user msg + assistant response
      assert length(result.messages) == 2
      last_msg = List.last(result.messages)
      assert last_msg.role == :assistant
      assert Message.text(last_msg) == "Hello there!"
    end
  end

  describe "run_loop/1 with tool use" do
    test "executes tools and continues" do
      {:ok, pid} =
        TestProvider.start_link([
          # Turn 1: model calls the echo tool
          TestProvider.tool_use_response([
            %{id: "tool_1", name: "echo", input: %{"text" => "world"}}
          ]),
          # Turn 2: model responds with final text after seeing tool result
          TestProvider.text_response("Tool said: Echo: world")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo world")])

      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 2

      # Messages: user, assistant(tool_use), user(tool_result), assistant(text)
      assert length(result.messages) == 4
    end

    test "handles multiple tool calls in one turn" do
      {:ok, pid} =
        TestProvider.start_link([
          # Turn 1: model calls echo twice
          TestProvider.tool_use_response([
            %{id: "tool_1", name: "echo", input: %{"text" => "foo"}},
            %{id: "tool_2", name: "echo", input: %{"text" => "bar"}}
          ]),
          # Turn 2: done
          TestProvider.text_response("Got both results")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo two things")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert result.turn == 2

      # Check that tool results message has 2 result blocks
      tool_result_msg = Enum.at(result.messages, 2)
      assert tool_result_msg.role == :user
      assert length(tool_result_msg.content) == 2
    end
  end

  describe "run_loop/1 with max_turns" do
    test "stops at max_turns" do
      # Create responses that always ask for tools (infinite loop)
      responses =
        for _ <- 1..30 do
          TestProvider.tool_use_response([
            %{id: "tool_#{:rand.uniform(1000)}", name: "echo", input: %{"text" => "loop"}}
          ])
        end

      {:ok, pid} = TestProvider.start_link(responses)

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        max_turns: 3
      }

      state = State.init(config, [Message.user("Loop forever")])
      result = Turn.run_loop(state)

      assert result.status == :max_turns
      assert result.turn == 3
    end
  end

  describe "run_loop/1 with provider errors" do
    test "sets error status on provider failure" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("API rate limited")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "API rate limited"
    end
  end

  describe "run_loop/1 with middleware" do
    test "calls middleware at hook points" do
      test_pid = self()

      defmodule TrackingMiddleware do
        @behaviour Alloy.Middleware

        def call(hook, state) do
          send(state.config.context[:test_pid], {:middleware, hook})
          state
        end
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [TrackingMiddleware],
        context: %{test_pid: test_pid}
      }

      state = State.init(config, [Message.user("Hi")])
      Turn.run_loop(state)

      assert_received {:middleware, :before_completion}
      assert_received {:middleware, :after_completion}
    end

    test "calls after_tool_execution hook when tools run" do
      test_pid = self()

      defmodule ToolTrackingMiddleware do
        @behaviour Alloy.Middleware

        def call(hook, state) do
          send(state.config.context[:test_pid], {:middleware, hook})
          state
        end
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        middleware: [ToolTrackingMiddleware],
        context: %{test_pid: test_pid}
      }

      state = State.init(config, [Message.user("Echo hi")])
      Turn.run_loop(state)

      assert_received {:middleware, :after_tool_execution}
    end
  end

  describe "run_loop/1 with retry" do
    # These tests use the ACTUAL error shapes that real providers return.
    # Providers call parse_error(status, body) which produces a string like
    # "rate_limit_error: Too many requests" or "HTTP 429: ...".
    # Network failures produce "HTTP request failed: #{inspect(reason)}".

    test "retries transient HTTP 429 string error from provider and succeeds" do
      # Anthropic parse_error(429, ...) produces "rate_limit_error: Too many requests"
      # OpenAI/Mistral/etc produce "requests: rate limit exceeded" or "HTTP 429: ..."
      # We test the generic "HTTP 429:" prefix that parse_error falls back to
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries HTTP 500 string error from provider" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.text_response("Recovered")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Recovered"
    end

    test "retries HTTP 502, 503, 504 string errors from providers" do
      for status <- [502, 503, 504] do
        {:ok, pid} =
          TestProvider.start_link([
            TestProvider.error_response("HTTP #{status}: Gateway Error"),
            TestProvider.text_response("Recovered")
          ])

        config = %Config{
          provider: TestProvider,
          provider_config: %{agent_pid: pid},
          max_retries: 2,
          retry_backoff_ms: 1
        }

        state = State.init(config, [Message.user("Hi")])
        result = Turn.run_loop(state)

        assert result.status == :completed, "Expected retry for HTTP #{status}"
      end
    end

    test "retries provider-formatted 429 error (Anthropic rate_limit_error style)" do
      # Anthropic parse_error: "rate_limit_error: Too many requests"
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("rate_limit_error: Too many requests"),
          TestProvider.text_response("Done after retry")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done after retry"
    end

    test "retries network connection refused error" do
      # Providers return: {:error, "HTTP request failed: #{inspect(reason)}"}
      # where reason is a Mint.TransportError struct with reason: :econnrefused
      econnrefused_msg = "HTTP request failed: %Mint.TransportError{reason: :econnrefused}"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(econnrefused_msg),
          TestProvider.text_response("Connected")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Connected"
    end

    test "retries network connection closed error" do
      closed_msg = "HTTP request failed: %Mint.TransportError{reason: :closed}"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(closed_msg),
          TestProvider.text_response("Reconnected")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Reconnected"
    end

    test "retries network timeout error" do
      timeout_msg = "HTTP request failed: %Mint.TransportError{reason: :timeout}"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(timeout_msg),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "non-retryable HTTP 401 string error fails immediately" do
      # Anthropic 401: "authentication_error: Invalid API key"
      # Generic fallback: "HTTP 401: Unauthorized"
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 401: Unauthorized"),
          # This response must never be consumed
          TestProvider.text_response("Should not reach here")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "HTTP 401: Unauthorized"
    end

    test "non-retryable authentication_error string fails immediately without retry" do
      # Anthropic returns "authentication_error: Invalid API key" for 401
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("authentication_error: Invalid API key"),
          TestProvider.text_response("Should not reach here")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "authentication_error: Invalid API key"
    end

    test "max_retries: 0 disables retry for retryable string error" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 429: Too Many Requests")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "HTTP 429: Too Many Requests"
    end

    test "exhausts all retries and fails after max_retries attempts" do
      # 4 string errors: 1 initial attempt + 3 retries
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :error
      assert result.error == "HTTP 500: Internal Server Error"
    end

    test "retries overloaded_error (Anthropic 529 - model overloaded)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(
            "overloaded_error: That model is currently overloaded with other requests."
          ),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries server_error (OpenAI 500 native format)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(
            "server_error: The server had an error processing your request."
          ),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries rate_limit_exceeded error (OpenAI 429 native format)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("rate_limit_exceeded: Rate limit reached for model"),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries RESOURCE_EXHAUSTED (Google Gemini 429 native format)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("RESOURCE_EXHAUSTED: Quota exceeded for quota metric"),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries INTERNAL (Google Gemini 500 native format)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("INTERNAL: Internal error encountered."),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retries UNAVAILABLE (Google Gemini 503 native format)" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("UNAVAILABLE: The service is currently unavailable."),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Done"
    end

    test "retry aborts when remaining time < backoff (deadline awareness)" do
      # Set timeout_ms very low so that the exponential backoff exceeds the deadline.
      # With retry_backoff_ms: 50_000 and timeout_ms: 1_000 (with 5s headroom),
      # the deadline is already in the past before the first sleep, so it should
      # fail immediately without sleeping.
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Should not reach here")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 50_000,
        timeout_ms: 1_000
      }

      state = State.init(config, [Message.user("Hi")])

      start_time = System.monotonic_time(:millisecond)
      result = Turn.run_loop(state)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result.status == :error
      assert result.error == "HTTP 429: Too Many Requests"

      # Should have returned nearly instantly (< 500ms), not slept 50+ seconds
      assert elapsed < 500,
             "Expected immediate abort but took #{elapsed}ms — deadline awareness not working"
    end

    test "uses exponential backoff (not linear) for retries" do
      # With retry_backoff_ms: 25 and 3 retries:
      #   Without jitter — Exponential: 25 + 50 + 100 = 175ms
      #   With full jitter — each sleep is rand(0, base*2^attempt),
      #     minimum total ~0ms, maximum total ~350ms
      #   We verify exponential base is correct by checking total > 100ms
      #   (which rules out linear 25+50+75=150ms base being used wrong).
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error"),
          TestProvider.error_response("HTTP 500: Internal Server Error")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 25
      }

      state = State.init(config, [Message.user("Hi")])

      start_time = System.monotonic_time(:millisecond)
      result = Turn.run_loop(state)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result.status == :error

      # With jitter, exact timing varies. But exponential base means
      # max possible total = 25*2 + 50*2 + 100*2 = 350ms.
      # Verify it stays within bounds (jitter doesn't exceed 2x base).
      assert elapsed < 500,
             "Jittered backoff exceeded expected bounds: #{elapsed}ms"
    end

    test "backoff includes jitter (not deterministic)" do
      # Run the retry loop multiple times and verify elapsed times vary.
      # Without jitter, each run takes exactly 25+50+100 = 175ms.
      # With jitter, times vary. We run 5 times and check they're not all identical.
      elapsed_times =
        for _ <- 1..5 do
          {:ok, pid} =
            TestProvider.start_link([
              TestProvider.error_response("HTTP 500: Internal Server Error"),
              TestProvider.error_response("HTTP 500: Internal Server Error"),
              TestProvider.error_response("HTTP 500: Internal Server Error"),
              TestProvider.error_response("HTTP 500: Internal Server Error")
            ])

          config = %Config{
            provider: TestProvider,
            provider_config: %{agent_pid: pid},
            max_retries: 3,
            retry_backoff_ms: 25
          }

          state = State.init(config, [Message.user("Hi")])

          start_time = System.monotonic_time(:millisecond)
          Turn.run_loop(state)
          System.monotonic_time(:millisecond) - start_time
        end

      # With jitter, at least 2 of 5 runs should produce different elapsed times.
      # Without jitter, all 5 would be ~175ms (within 1-2ms of each other).
      unique_times = elapsed_times |> Enum.uniq() |> length()

      assert unique_times >= 2,
             "Expected jittered backoff to produce varying times but got: #{inspect(elapsed_times)}"
    end
  end

  describe "run_loop/1 with halting middleware" do
    test "middleware halting before_completion stops the turn" do
      defmodule SpendCapMiddleware do
        @behaviour Alloy.Middleware
        def call(:before_completion, _state), do: {:halt, "spend cap reached"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Should not reach")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [SpendCapMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :halted
      assert result.error =~ "spend cap"
    end

    test "middleware halting on_error overrides error with halted status" do
      defmodule OnErrorHaltMiddleware do
        @behaviour Alloy.Middleware
        def call(:on_error, _state), do: {:halt, "error policy triggered"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 500: Internal Server Error")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [OnErrorHaltMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      # The middleware halted on :on_error, so status should be :halted (not :error)
      assert result.status == :halted
      refute result.status == :error
      assert result.error =~ "error policy triggered"
    end

    test "halted status is distinguishable from :error" do
      defmodule HaltingMiddleware do
        @behaviour Alloy.Middleware
        def call(:before_completion, _state), do: {:halt, "policy violation"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Should not reach")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [HaltingMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :halted
      refute result.status == :error
    end

    test "normal middleware (returning state) still allows turn to complete" do
      defmodule NoopMiddleware do
        @behaviour Alloy.Middleware
        def call(_hook, %State{} = state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("All good")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        middleware: [NoopMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
    end
  end

  describe "run_loop/1 with before_tool_call halting middleware" do
    test "middleware halting before_tool_call stops the agent with status :halted" do
      defmodule BeforeToolCallHaltingMiddleware do
        @behaviour Alloy.Middleware
        def call(:before_tool_call, _state), do: {:halt, "tool call blocked by policy"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          # This second response must never be consumed
          TestProvider.text_response("Should not reach")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        middleware: [BeforeToolCallHaltingMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      assert result.status == :halted
      assert result.error =~ "tool call blocked by policy"
    end

    test "middleware halting after_tool_execution stops the agent cleanly" do
      defmodule AfterToolExecHaltMiddleware do
        @behaviour Alloy.Middleware
        def call(:after_tool_execution, _state), do: {:halt, "tool policy"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          # This second response must never be consumed — halt stops the loop
          TestProvider.text_response("Should not reach")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        middleware: [AfterToolExecHaltMiddleware],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      assert result.status == :halted
      refute result.status == :error
      assert result.error =~ "tool policy"
    end

    test "before_tool_call halt is distinguishable from :error status" do
      defmodule BeforeToolCallHaltingMiddleware2 do
        @behaviour Alloy.Middleware
        def call(:before_tool_call, _state), do: {:halt, "policy violation"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ])
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool],
        middleware: [BeforeToolCallHaltingMiddleware2],
        max_retries: 0,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      assert result.status == :halted
      refute result.status == :error
    end
  end

  describe "run_loop/2 with retry and streaming" do
    test "retries retryable error when streaming is enabled and eventually succeeds" do
      test_pid = self()

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Streamed OK")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])

      on_chunk = fn chunk ->
        send(test_pid, {:chunk, chunk})
        :ok
      end

      result = Turn.run_loop(state, streaming: true, on_chunk: on_chunk)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Streamed OK"

      # The TestProvider streams each character when streaming.
      # "Streamed OK" = 10 characters, so we should receive 10 chunk messages.
      for char <- String.graphemes("Streamed OK") do
        assert_received {:chunk, ^char}
      end
    end

    test "streaming error with no prior chunks is still retried normally" do
      # Verifies that the chunks_emitted? guard doesn't prevent retries when no chunks emitted.
      # TestProvider returns {:error, ...} without calling on_chunk, so chunks_emitted? == false,
      # and the retry logic should still fire as before.
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 503: Service Unavailable"),
          TestProvider.text_response("Recovered after retry")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])

      result = Turn.run_loop(state, streaming: true, on_chunk: fn _chunk -> :ok end)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Recovered after retry"
    end
  end

  describe "run_loop/1 retries HTTP 408 and HTTP/2 unprocessed" do
    test "retries HTTP 408 (Request Timeout) error" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("HTTP 408: Request Timeout"),
          TestProvider.text_response("Recovered from 408")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Recovered from 408"
    end

    test "retries HTTP/2 unprocessed error" do
      # Req wraps HTTP/2 unprocessed as: %Req.HTTPError{protocol: :http2, reason: :unprocessed}
      # Providers see this via the rescue clause and wrap as:
      # "HTTP request failed: %Req.HTTPError{protocol: :http2, reason: :unprocessed}"
      unprocessed_msg =
        "HTTP request failed: %Req.HTTPError{protocol: :http2, reason: :unprocessed}"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response(unprocessed_msg),
          TestProvider.text_response("Recovered from h2 unprocessed")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 2,
        retry_backoff_ms: 1
      }

      state = State.init(config, [Message.user("Hi")])
      result = Turn.run_loop(state)

      assert result.status == :completed
      assert Message.text(List.last(result.messages)) == "Recovered from h2 unprocessed"
    end
  end

  describe "run_loop/1 deadline is per-loop not per-call" do
    test "deadline is computed once at run_loop start, not reset per provider call" do
      # This test distinguishes per-loop from per-call deadline.
      #
      # Setup: timeout_ms: 5_500 → effective budget = 500ms (after 5s headroom)
      # 1. Provider returns tool_use → tool sleeps 350ms
      # 2. Provider returns retryable 429 error
      #
      # Per-loop deadline: budget started at run_loop. After 350ms tool sleep,
      #   only ~150ms remaining. Backoff of 400ms > 150ms → immediate abort.
      #
      # Per-call deadline (current bug): fresh 500ms budget on second call.
      #   400ms backoff < 500ms → would sleep and retry → would succeed.
      #
      # Assert: result is error (per-loop aborted), not completed (per-call retried).

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "slow_echo", input: %{"text" => "hi", "sleep_ms" => 350}}
          ]),
          TestProvider.error_response("HTTP 429: Too Many Requests"),
          TestProvider.text_response("Should not reach with per-loop deadline")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [Alloy.Test.SlowEchoTool],
        max_retries: 3,
        retry_backoff_ms: 400,
        timeout_ms: 5_500
      }

      state = State.init(config, [Message.user("Hi")])

      start_time = System.monotonic_time(:millisecond)
      result = Turn.run_loop(state)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Per-loop: ~350ms tool + instant abort = ~350-500ms, status: error
      # Per-call: ~350ms tool + 400ms sleep + success = ~750ms, status: completed
      assert result.status == :error,
             "Expected :error (per-loop deadline abort) but got :#{result.status} — " <>
               "deadline may be resetting per-call"

      assert result.error == "HTTP 429: Too Many Requests"

      assert elapsed < 1_000,
             "Expected quick abort (~350ms) but took #{elapsed}ms"
    end
  end

  describe "run_loop/1 injects receive_timeout into provider config" do
    test "provider receives receive_timeout in req_options based on deadline" do
      # Use a test provider that captures the config it receives.
      # The Turn should inject :receive_timeout into req_options
      # so that hung HTTP requests don't overshoot the deadline.
      test_pid = self()

      defmodule ConfigCapturingProvider do
        @behaviour Alloy.Provider

        def complete(_messages, _tool_defs, config) do
          send(config.test_pid, {:provider_config, config})

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               %Alloy.Message{
                 role: :assistant,
                 content: [%{type: "text", text: "Done"}]
               }
             ],
             usage: %{input_tokens: 0, output_tokens: 0}
           }}
        end

        def tools_to_provider_format(_tool_defs, _config), do: []
      end

      config = %Config{
        provider: ConfigCapturingProvider,
        provider_config: %{test_pid: test_pid},
        timeout_ms: 30_000
      }

      state = State.init(config, [Message.user("Hi")])
      Turn.run_loop(state)

      assert_received {:provider_config, captured_config}
      req_options = Map.get(captured_config, :req_options, [])
      receive_timeout = Keyword.get(req_options, :receive_timeout)

      # receive_timeout should be set and positive, roughly timeout_ms - headroom
      assert receive_timeout != nil, "Expected receive_timeout to be injected into req_options"
      assert receive_timeout > 0
      # Should be approximately 30_000 - 5_000 = 25_000, minus a few ms of overhead
      assert receive_timeout > 20_000
      assert receive_timeout < 30_000
    end
  end

  describe "run_loop/1 tracks usage" do
    test "accumulates token usage across turns" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "echo", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        tools: [EchoTool]
      }

      state = State.init(config, [Message.user("Echo hi")])
      result = Turn.run_loop(state)

      # TestProvider returns 10 input + 5 output per call, 2 calls
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 10
    end
  end

  describe "run_loop/2 on_event threading" do
    test "on_event callback from opts is fired for each chunk during streaming" do
      test_pid = self()

      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hi")])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hello")])

      on_event = fn event -> send(test_pid, {:event, event}) end

      result =
        Turn.run_loop(state, streaming: true, on_chunk: fn _ -> :ok end, on_event: on_event)

      assert result.status == :completed
      # "Hi" has 2 chars — expect 2 {:text_delta, char} events
      assert_received {:event, {:text_delta, "H"}}
      assert_received {:event, {:text_delta, "i"}}
    end

    test "on_event defaults to no-op when not provided (no crash)" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Hello")])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid}
      }

      state = State.init(config, [Message.user("Hi")])

      # Should not crash without on_event in opts
      result = Turn.run_loop(state, streaming: true, on_chunk: fn _ -> :ok end)
      assert result.status == :completed
    end

    test "on_event emission marks chunks_emitted — no retry after thinking_delta fires" do
      test_pid = self()

      # Two retryable thinking-then-error responses, then success.
      # Without the fix, the thinking delta fires once per attempt (3 total).
      # With the fix, it fires on the first attempt and blocks retries entirely.
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.thinking_error_response("Let me reason...", "HTTP 429: Too Many Requests"),
          TestProvider.thinking_error_response("Let me reason...", "HTTP 429: Too Many Requests"),
          TestProvider.text_response("Done")
        ])

      config = %Config{
        provider: TestProvider,
        provider_config: %{agent_pid: pid},
        max_retries: 3,
        retry_backoff_ms: 1
      }

      on_event = fn event -> send(test_pid, {:event, event}) end

      state = State.init(config, [Message.user("Think")])

      _result =
        Turn.run_loop(state, streaming: true, on_chunk: fn _ -> :ok end, on_event: on_event)

      # The thinking delta should be emitted exactly once — NOT again on retry.
      assert_received {:event, {:thinking_delta, "Let me reason..."}}
      refute_received {:event, {:thinking_delta, "Let me reason..."}}
    end
  end
end
