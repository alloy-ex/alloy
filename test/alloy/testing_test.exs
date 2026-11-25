defmodule Alloy.TestingTest do
  use ExUnit.Case, async: true

  use Alloy.Testing

  alias Alloy.Message

  defmodule SentinelProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_m, _t, config) do
      send(config.owner, :sentinel_called)
      {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("sentinel")], usage: %{}}}
    end
  end

  describe "run_with_responses/2" do
    test "runs agent with scripted text response" do
      result =
        run_with_responses("Hello", [
          text_response("Hi there!")
        ])

      assert result.status == :completed
      assert last_text(result) == "Hi there!"
    end

    test "runs agent with tool use then text response" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{text: "test"}),
          text_response("Done!")
        ])

      assert result.status == :completed
      assert last_text(result) == "Done!"
    end

    test "accepts opts for custom configuration" do
      result =
        run_with_responses("Hi", [text_response("ok")],
          max_turns: 1,
          system_prompt: "Be brief."
        )

      assert result.status == :completed
    end

    test "passes :context through to tools" do
      test_pid = self()

      spy =
        Alloy.Tool.inline(
          name: "spy",
          description: "Reports the context it receives",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _input, context ->
            send(test_pid, {:ctx, context})
            {:ok, "ok"}
          end
        )

      result =
        run_with_responses("Use spy", [tool_response("spy", %{}), text_response("Done")],
          tools: [spy],
          context: %{tenant: "acme"}
        )

      assert result.status == :completed
      assert_received {:ctx, %{tenant: "acme"}}
    end

    test "default tools are shipped with the application" do
      app_modules = Application.spec(:alloy, :modules)

      assert Enum.all?(Alloy.Testing.default_tools(), fn
               %Alloy.Tool.Inline{} -> true
               module when is_atom(module) -> module in app_modules
             end)
    end

    test "routes through Config.from_opts/1, enforces scripted provider, and rejects unknown options" do
      test_pid = self()

      state =
        run_with_responses(
          "hi",
          [
            tool_response("echo", %{text: "hi"}),
            text_response("ignored")
          ],
          stop_after_tool: "echo"
        )

      assert state.status == :completed
      assert state.turn == 1
      assert state.config.middleware == []

      scripted =
        run_with_responses(
          "hi",
          [text_response("from scripted")],
          provider: {SentinelProvider, owner: test_pid}
        )

      assert scripted.status == :completed
      assert Message.text(List.last(scripted.messages)) == "from scripted"
      refute_received :sentinel_called

      links_before = Process.info(self(), :links)

      assert_raise ArgumentError, ~r/unknown options/, fn ->
        run_with_responses("hi", [], bogus_opt: true)
      end

      assert Process.info(self(), :links) == links_before

      assert_raise ArgumentError, fn ->
        run_with_responses("hi", [], tools: [123])
      end

      assert Process.info(self(), :links) == links_before

      _ = run_with_responses("hi", [text_response("tidy")])
      assert Process.info(self(), :links) == links_before
    end

    test "clears fallback_providers so scripted errors or exhausted queues never invoke live fallbacks" do
      test_pid = self()

      errored =
        run_with_responses(
          "hi",
          [error_response(%Alloy.Provider.Error{kind: :overloaded, message: "busy"})],
          max_retries: 0,
          fallback_providers: [{SentinelProvider, owner: test_pid}]
        )

      assert errored.status == :error
      assert errored.error =~ "busy"
      refute_received :sentinel_called

      exhausted =
        run_with_responses(
          "hi",
          [],
          max_retries: 0,
          fallback_providers: [{SentinelProvider, owner: test_pid}]
        )

      assert exhausted.status == :error
      refute_received :sentinel_called
    end
  end

  describe "tool_response/2" do
    test "delivers string keys, as providers do, so string-key tools work" do
      # The moduledoc's weather example: atom keys in the script, a tool
      # that matches on string keys.
      weather =
        Alloy.Tool.inline(
          name: "get_weather",
          description: "Weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          execute: fn %{"location" => loc}, _ctx -> {:ok, "22°C in " <> loc} end
        )

      result =
        run_with_responses(
          "What's the weather?",
          [tool_response("get_weather", %{location: "Sydney"}), text_response("Sunny")],
          tools: [weather]
        )

      assert [%{name: "get_weather", error: nil}] = result.tool_calls
      assert [%{input: %{"location" => "Sydney"}}] = tool_calls(result)
    end
  end

  describe "assert_tool_called/2" do
    test "passes when the tool was called" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{text: "hello"}),
          text_response("Done")
        ])

      assert_tool_called(result, "echo")
    end

    test "raises when the tool was not called" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        assert_tool_called(result, "nonexistent")
      end
    end
  end

  describe "assert_tool_called/3 with input match" do
    test "passes when tool was called with matching input" do
      result =
        run_with_responses("Echo hello", [
          tool_response("echo", %{text: "hello"}),
          text_response("Done")
        ])

      assert_tool_called(result, "echo", %{"text" => "hello"})
    end

    test "raises when input doesn't match" do
      result =
        run_with_responses("Echo hello", [
          tool_response("echo", %{text: "hello"}),
          text_response("Done")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        assert_tool_called(result, "echo", %{"text" => "wrong"})
      end
    end
  end

  describe "refute_tool_called/2" do
    test "passes when the tool was not called" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      refute_tool_called(result, "bash")
    end

    test "raises when the tool was called" do
      result =
        run_with_responses("Use echo", [
          tool_response("echo", %{text: "test"}),
          text_response("Done")
        ])

      assert_raise ExUnit.AssertionError, fn ->
        refute_tool_called(result, "echo")
      end
    end
  end

  describe "last_text/1" do
    test "extracts text from last assistant message" do
      result =
        run_with_responses("Hi", [
          text_response("Final answer")
        ])

      assert last_text(result) == "Final answer"
    end

    test "returns nil when no assistant messages" do
      assert last_text(%{messages: []}) == nil
    end
  end

  describe "tool_calls/1" do
    test "extracts all tool calls from conversation" do
      result =
        run_with_responses("Do both", [
          tool_response("echo", %{text: "first"}),
          tool_response("echo", %{text: "second"}),
          text_response("Done")
        ])

      calls = tool_calls(result)
      assert length(calls) >= 2
      assert Enum.all?(calls, &(&1.name == "echo"))
    end

    test "returns empty list when no tool calls" do
      result =
        run_with_responses("Hi", [
          text_response("Hello!")
        ])

      assert tool_calls(result) == []
    end
  end
end
