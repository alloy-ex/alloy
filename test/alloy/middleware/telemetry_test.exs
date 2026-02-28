defmodule Alloy.Middleware.TelemetryTest do
  use ExUnit.Case, async: false

  alias Alloy.Agent.{Config, State}
  alias Alloy.Middleware.Telemetry
  alias Alloy.Usage

  defp build_state(attrs \\ []) do
    config = %Config{
      provider: Alloy.Provider.Test,
      provider_config: %{}
    }

    struct!(
      State,
      Keyword.merge(
        [config: config, turn: 1, usage: %Usage{input_tokens: 100, output_tokens: 50}],
        attrs
      )
    )
  end

  setup do
    # Detach any leftover handlers from previous tests
    :ok
  end

  describe "before_completion hook" do
    test "emits [:alloy, :completion, :start] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-completion-start-#{inspect(ref)}",
        [:alloy, :completion, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state()
      result = Telemetry.call(:before_completion, state)

      assert_receive {:telemetry_event, [:alloy, :completion, :start], %{turn: 1}, %{}}
      assert result == state

      :telemetry.detach("test-completion-start-#{inspect(ref)}")
    end
  end

  describe "after_completion hook" do
    test "emits [:alloy, :completion, :stop] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-completion-stop-#{inspect(ref)}",
        [:alloy, :completion, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state(status: :running)
      result = Telemetry.call(:after_completion, state)

      assert_receive {:telemetry_event, [:alloy, :completion, :stop], %{turn: 1, tokens: 150},
                      %{status: :running}}

      assert result == state

      :telemetry.detach("test-completion-stop-#{inspect(ref)}")
    end
  end

  describe "after_tool_execution hook" do
    test "emits [:alloy, :tool_execution, :stop] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-tool-exec-#{inspect(ref)}",
        [:alloy, :tool_execution, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state()
      result = Telemetry.call(:after_tool_execution, state)

      assert_receive {:telemetry_event, [:alloy, :tool_execution, :stop], %{turn: 1, tokens: 150},
                      %{status: :idle}}

      assert result == state

      :telemetry.detach("test-tool-exec-#{inspect(ref)}")
    end
  end

  describe "on_error hook" do
    test "emits [:alloy, :error] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-error-#{inspect(ref)}",
        [:alloy, :error],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state(status: :error, error: "something broke")
      result = Telemetry.call(:on_error, state)

      assert_receive {:telemetry_event, [:alloy, :error], %{turn: 1},
                      %{status: :error, error: "something broke"}}

      assert result == state

      :telemetry.detach("test-error-#{inspect(ref)}")
    end
  end
end
