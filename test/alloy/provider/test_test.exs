defmodule Alloy.Provider.TestTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  describe "text_response/1" do
    test "builds an end_turn completion response with text" do
      response = TestProvider.text_response("Hello!")

      assert {:ok,
              %{
                stop_reason: :end_turn,
                messages: [%Message{role: :assistant, content: "Hello!"}],
                usage: %{input_tokens: 10, output_tokens: 5}
              }} = response
    end

    test "text_response/2 attaches provider_state to the text response" do
      response = TestProvider.text_response("Hello!", %{cursor: "c1"})

      assert {:ok,
              %{
                stop_reason: :end_turn,
                messages: [%Message{role: :assistant, content: "Hello!"}],
                usage: %{input_tokens: 10, output_tokens: 5},
                provider_state: %{cursor: "c1"}
              }} = response
    end
  end

  describe "slow_text_response/1,2" do
    test "defaults to a 200ms delay tuple and sleeps before returning in complete/3 and stream/4" do
      assert {:with_delay, 200,
              {:ok, %{stop_reason: :end_turn, messages: [%Message{content: "Default"}]}}} =
               TestProvider.slow_text_response("Default")

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.slow_text_response("Slow complete", 5),
          TestProvider.slow_text_response("Hi", 5)
        ])

      config = %{agent_pid: pid}

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{stop_reason: :end_turn, messages: [%Message{content: "Slow complete"}]}} =
               TestProvider.complete([Message.user("go")], [], config)

      assert System.monotonic_time(:millisecond) - started >= 5

      test_pid = self()

      assert {:ok, %{stop_reason: :end_turn, messages: [%Message{content: "Hi"}]}} =
               TestProvider.stream([Message.user("go")], [], config, fn chunk ->
                 send(test_pid, {:chunk, chunk})
                 :ok
               end)

      assert_received {:chunk, "H"}
      assert_received {:chunk, "i"}
    end
  end

  describe "tool_use_response/1" do
    test "builds a tool_use completion response" do
      tool_calls = [
        %{type: "tool_use", id: "call_1", name: "read_file", input: %{"path" => "/tmp/a.txt"}}
      ]

      response = TestProvider.tool_use_response(tool_calls)

      assert {:ok,
              %{
                stop_reason: :tool_use,
                messages: [%Message{role: :assistant, content: ^tool_calls}],
                usage: %{input_tokens: 10, output_tokens: 5}
              }} = response
    end
  end

  describe "error_response/1" do
    test "builds an error tuple" do
      response = TestProvider.error_response(:rate_limited)
      assert {:error, :rate_limited} = response
    end
  end

  describe "complete/3" do
    test "returns scripted text responses in order" do
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.text_response("First"),
          TestProvider.text_response("Second")
        ])

      config = %{agent_pid: pid}
      messages = [Message.user("Hi")]

      assert {:ok, %{stop_reason: :end_turn, messages: [%Message{content: "First"}]}} =
               TestProvider.complete(messages, [], config)

      assert {:ok, %{stop_reason: :end_turn, messages: [%Message{content: "Second"}]}} =
               TestProvider.complete(messages, [], config)
    end

    test "returns scripted tool_use responses" do
      tool_calls = [
        %{type: "tool_use", id: "call_1", name: "search", input: %{"q" => "elixir"}}
      ]

      {:ok, pid} = TestProvider.start_link([TestProvider.tool_use_response(tool_calls)])
      config = %{agent_pid: pid}

      assert {:ok, %{stop_reason: :tool_use, messages: [%Message{content: ^tool_calls}]}} =
               TestProvider.complete([Message.user("search for elixir")], [], config)
    end

    test "returns error when responses are exhausted" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Only one")])
      config = %{agent_pid: pid}

      assert {:ok, _} = TestProvider.complete([Message.user("Hi")], [], config)

      assert {:error, :no_more_responses} =
               TestProvider.complete([Message.user("Hi")], [], config)
    end

    test "returns scripted error responses" do
      {:ok, pid} = TestProvider.start_link([TestProvider.error_response(:timeout)])
      config = %{agent_pid: pid}

      assert {:error, :timeout} = TestProvider.complete([Message.user("Hi")], [], config)
    end

    test "works with Message structs in the input" do
      {:ok, pid} = TestProvider.start_link([TestProvider.text_response("Got it")])
      config = %{agent_pid: pid}

      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("Do something")
      ]

      assert {:ok, %{messages: [%Message{content: "Got it"}]}} =
               TestProvider.complete(messages, [], config)
    end
  end
end
