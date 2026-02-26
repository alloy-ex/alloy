defmodule AlloyTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Message

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
end
