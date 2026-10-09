defmodule AlloyTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  # A simple tool for integration testing
  defmodule UpperTool do
    @behaviour Alloy.Tool

    @impl true
    def name, do: "uppercase"

    @impl true
    def description, do: "Converts text to uppercase"

    @impl true
    def input_schema do
      %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]}
    end

    @impl true
    def execute(%{"text" => text}, _ctx), do: {:ok, String.upcase(text)}
  end

  describe "Alloy.run/2 simple conversation" do
    test "returns text from a simple one-turn conversation" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("The answer is 4.")
        ])

      assert {:ok, result} =
               Alloy.run("What is 2+2?",
                 provider: {TestProvider, agent_pid: pid}
               )

      assert result.text == "The answer is 4."
      assert result.status == :completed
      assert result.turns == 1
      assert result.error == nil
    end

    test "passes system prompt to provider config" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("I'm helpful!")
        ])

      assert {:ok, result} =
               Alloy.run("Hi",
                 provider: {TestProvider, agent_pid: pid},
                 system_prompt: "You are helpful."
               )

      assert result.text == "I'm helpful!"
    end
  end

  describe "Alloy.run/2 with code_execution: true" do
    test "enables the Anthropic code execution tool" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:captured, conn.req_headers, Jason.decode!(body)})

        response = %{
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "55"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      assert {:ok, _result} =
               Alloy.run("What is fib(10)?",
                 provider:
                   {Alloy.Provider.Anthropic,
                    api_key: "sk-test", model: "claude-sonnet-4-6", req_options: [plug: plug]},
                 code_execution: true
               )

      assert_receive {:captured, headers, body}

      assert Enum.any?(
               body["tools"] || [],
               &(&1["name"] == "code_execution" and &1["type"] =~ "code_execution_")
             )

      # Code execution is GA (2026-02-17): no beta header is needed.
      refute List.keyfind(headers, "anthropic-beta", 0)
    end
  end

  describe "Alloy.stream/3" do
    test "streams text for a one-shot conversation" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Streaming works")
        ])

      test_pid = self()

      assert {:ok, result} =
               Alloy.stream(
                 "Explain OTP",
                 fn chunk -> send(test_pid, {:chunk, chunk}) end,
                 provider: {TestProvider, agent_pid: pid}
               )

      assert result.text == "Streaming works"
      assert result.status == :completed

      assert_received {:chunk, "S"}
      assert_received {:chunk, "t"}
      assert_received {:chunk, "r"}
    end

    test "forwards on_event callbacks" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("OK")
        ])

      test_pid = self()

      assert {:ok, result} =
               Alloy.stream(
                 "Hi",
                 fn _chunk -> :ok end,
                 provider: {TestProvider, agent_pid: pid},
                 on_event: fn event -> send(test_pid, {:event, event}) end
               )

      assert result.status == :completed

      assert_received {:event, %{event: :text_delta, payload: "O"}}
      assert_received {:event, %{event: :text_delta, payload: "K"}}
    end

    test "raises when on_event is not a function" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Nope")
        ])

      assert_raise ArgumentError, ~r/on_event must be a 1-arity function/, fn ->
        Alloy.stream(
          "Hi",
          fn _chunk -> :ok end,
          provider: {TestProvider, agent_pid: pid},
          on_event: :invalid
        )
      end
    end
  end

  describe "Alloy.run/2 with tools" do
    test "executes tools and returns final response" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "uppercase", input: %{"text" => "hello"}}
          ]),
          TestProvider.text_response("The uppercase is: HELLO")
        ])

      assert {:ok, result} =
               Alloy.run("Uppercase hello",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool]
               )

      assert result.text == "The uppercase is: HELLO"
      assert result.turns == 2
      assert result.status == :completed
    end

    test "forwards on_event callbacks for tool events" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "uppercase", input: %{"text" => "hello"}}
          ]),
          TestProvider.text_response("HELLO")
        ])

      test_pid = self()

      assert {:ok, _result} =
               Alloy.run("Uppercase hello",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool],
                 on_event: fn event -> send(test_pid, {:event, event}) end
               )

      assert_received {:event, %{v: 1, event: :tool_start, payload: %{name: "uppercase"}}}
      assert_received {:event, %{v: 1, event: :tool_end, payload: %{name: "uppercase"}}}
    end

    test "raises when on_event is not a function" do
      assert_raise ArgumentError, ~r/on_event must be a 1-arity function/, fn ->
        Alloy.run("Hi", provider: {TestProvider, agent_pid: self()}, on_event: :invalid)
      end
    end

    test "handles multi-turn tool usage" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "uppercase", input: %{"text" => "foo"}}
          ]),
          TestProvider.tool_use_response([
            %{id: "t2", name: "uppercase", input: %{"text" => "bar"}}
          ]),
          TestProvider.text_response("FOO and BAR")
        ])

      assert {:ok, result} =
               Alloy.run("Uppercase foo and bar separately",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool]
               )

      assert result.text == "FOO and BAR"
      assert result.turns == 3
    end
  end

  describe "Alloy.run/2 with conversation history" do
    test "continues from existing messages" do
      existing = [
        Message.user("What is 2+2?"),
        Message.assistant("4")
      ]

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Because math!")
        ])

      assert {:ok, result} =
               Alloy.run("Why?",
                 provider: {TestProvider, agent_pid: pid},
                 messages: existing
               )

      assert result.text == "Because math!"
      # existing 2 + new user msg + new assistant msg = 4
      assert length(result.messages) == 4
    end

    test "works with nil message and existing history" do
      existing = [Message.user("Hi")]

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Hello!")
        ])

      assert {:ok, result} =
               Alloy.run(nil,
                 provider: {TestProvider, agent_pid: pid},
                 messages: existing
               )

      assert result.text == "Hello!"
      assert length(result.messages) == 2
    end
  end

  describe "Alloy.run/2 error handling" do
    test "returns error tuple on provider failure" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.error_response("Rate limited")
        ])

      assert {:error, result} =
               Alloy.run("Hi",
                 provider: {TestProvider, agent_pid: pid}
               )

      assert result.status == :error
      assert result.error == "Rate limited"
    end

    test "returns ok with max_turns status when limit reached" do
      responses =
        for _ <- 1..30 do
          TestProvider.tool_use_response([
            %{id: "t#{:rand.uniform(9999)}", name: "uppercase", input: %{"text" => "loop"}}
          ])
        end

      {:ok, pid} = TestProvider.start_link(responses)

      assert {:ok, result} =
               Alloy.run("Keep going",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool],
                 max_turns: 5
               )

      assert result.status == :max_turns
      assert result.turns == 5
    end
  end

  describe "Alloy.run/2 with middleware" do
    test "middleware receives hooks" do
      test_pid = self()

      defmodule TestMiddleware do
        @behaviour Alloy.Middleware

        def call(hook, state) do
          send(state.config.context[:test_pid], {:hook, hook})
          state
        end
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Done")
        ])

      assert {:ok, _result} =
               Alloy.run("Hi",
                 provider: {TestProvider, agent_pid: pid},
                 middleware: [TestMiddleware],
                 context: %{test_pid: test_pid}
               )

      assert_received {:hook, :before_completion}
      assert_received {:hook, :after_completion}
    end
  end

  describe "the budget middleware recipe in the Alloy docs" do
    defmodule BudgetGuard do
      @behaviour Alloy.Middleware

      @input_per_m 3.0
      @output_per_m 15.0

      @impl true
      def call(:before_completion, state) do
        limit = Map.fetch!(state.config.context, :max_budget_cents)
        usage = Alloy.Usage.estimate_cost(state.usage, @input_per_m, @output_per_m)

        if usage.estimated_cost_cents >= limit do
          {:halt, "budget of #{limit} cents reached"}
        else
          state
        end
      end

      def call(_hook, state), do: state
    end

    test "halts before the request that would exceed the budget" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "uppercase", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Should not reach")
        ])

      # The first response (10 in, 5 out) costs 0.0105 cents at $3/$15 per M.
      assert {:error, result} =
               Alloy.run("Uppercase hi",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool],
                 middleware: [BudgetGuard],
                 context: %{max_budget_cents: 0.01}
               )

      assert result.status == :halted
      assert result.error == "Halted by middleware: budget of 0.01 cents reached"
      assert result.turns == 1
    end
  end

  describe "Alloy.run/2 usage tracking" do
    test "accumulates usage across turns" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t1", name: "uppercase", input: %{"text" => "hi"}}
          ]),
          TestProvider.text_response("Done")
        ])

      assert {:ok, result} =
               Alloy.run("Uppercase hi",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [UpperTool]
               )

      # TestProvider returns 10 input + 5 output per call, 2 calls
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 10
    end
  end

  describe "Alloy.run/2 sets :running status" do
    test "middleware sees :running status during execution" do
      test_pid = self()

      defmodule StatusMiddleware do
        @behaviour Alloy.Middleware

        def call(:before_completion, state) do
          send(state.config.context[:test_pid], {:status_during_run, state.status})
          state
        end

        def call(_hook, state), do: state
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("Done")
        ])

      assert {:ok, _result} =
               Alloy.run("Hi",
                 provider: {TestProvider, agent_pid: pid},
                 middleware: [StatusMiddleware],
                 context: %{test_pid: test_pid}
               )

      assert_received {:status_during_run, :running}
    end
  end
end
