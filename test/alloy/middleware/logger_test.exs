defmodule Alloy.Middleware.LoggerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Alloy.Agent.{Config, State}
  alias Alloy.Middleware.Logger, as: AlloyLogger
  alias Alloy.Usage

  defp build_state(attrs \\ []) do
    config = %Config{
      provider: Alloy.Provider.Test,
      provider_config: %{}
    }

    struct!(
      State,
      Keyword.merge(
        [config: config, turn: 3, usage: %Usage{input_tokens: 200, output_tokens: 100}],
        attrs
      )
    )
  end

  describe "before_completion hook" do
    test "logs debug message with turn number" do
      state = build_state()

      log =
        capture_log(fn ->
          result = AlloyLogger.call(:before_completion, state)
          assert result == state
        end)

      assert log =~ "turn 3"
      assert log =~ "completion request"
    end
  end

  describe "after_completion hook" do
    test "logs info message with status" do
      state = build_state(status: :running)

      log =
        capture_log(fn ->
          result = AlloyLogger.call(:after_completion, state)
          assert result == state
        end)

      assert log =~ "turn 3"
      assert log =~ "running"
    end
  end

  describe "after_tool_execution hook" do
    test "logs debug message about tool execution" do
      state = build_state()

      log =
        capture_log(fn ->
          result = AlloyLogger.call(:after_tool_execution, state)
          assert result == state
        end)

      assert log =~ "turn 3"
      assert log =~ "tool execution"
    end
  end

  describe "on_error hook" do
    test "logs error message with error details" do
      state = build_state(status: :error, error: "provider timeout")

      log =
        capture_log(fn ->
          result = AlloyLogger.call(:on_error, state)
          assert result == state
        end)

      assert log =~ "error"
      assert log =~ "provider timeout"
    end
  end
end
