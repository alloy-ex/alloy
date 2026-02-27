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
          TestProvider.error_response(
            "rate_limit_exceeded: Rate limit reached for model"
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

    test "uses exponential backoff (not linear) for retries" do
      # With retry_backoff_ms: 25 and 3 retries:
      #   Exponential: 25*2^0 + 25*2^1 + 25*2^2 = 25 + 50 + 100 = 175ms minimum
      #   Linear would be: 25*1 + 25*2 + 25*3 = 25 + 50 + 75 = 150ms
      # We assert the total elapsed time is >= 170ms (exponential floor with tolerance)
      # which would fail if backoff were linear (150ms).
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

      # Exponential total sleep = 25 + 50 + 100 = 175ms
      # Linear total sleep would be = 25 + 50 + 75 = 150ms
      # Assert elapsed >= 170ms (exponential floor minus small tolerance)
      # Linear's 150ms would fail this assertion
      assert elapsed >= 170,
             "Expected exponential backoff (>=170ms) but elapsed was #{elapsed}ms"
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
end
