defmodule Anvil.Middleware.TelemetryTest do
  use ExUnit.Case, async: false

  alias Anvil.Middleware.Telemetry
  alias Anvil.Agent.{Config, State}
  alias Anvil.Usage

  defp build_state(attrs \\ []) do
    config = %Config{
      provider: Anvil.Provider.Test,
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
    test "emits [:anvil, :completion, :start] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-completion-start-#{inspect(ref)}",
        [:anvil, :completion, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state()
      result = Telemetry.call(:before_completion, state)

      assert_receive {:telemetry_event, [:anvil, :completion, :start], %{turn: 1}, %{}}
      assert result == state

      :telemetry.detach("test-completion-start-#{inspect(ref)}")
    end
  end

  describe "after_completion hook" do
    test "emits [:anvil, :completion, :stop] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-completion-stop-#{inspect(ref)}",
        [:anvil, :completion, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state(status: :running)
      result = Telemetry.call(:after_completion, state)

      assert_receive {:telemetry_event, [:anvil, :completion, :stop], %{turn: 1, tokens: 150},
                      %{status: :running}}

      assert result == state

      :telemetry.detach("test-completion-stop-#{inspect(ref)}")
    end
  end

  describe "after_tool_execution hook" do
    test "emits [:anvil, :tool_execution, :stop] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-tool-exec-#{inspect(ref)}",
        [:anvil, :tool_execution, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state()
      result = Telemetry.call(:after_tool_execution, state)

      assert_receive {:telemetry_event, [:anvil, :tool_execution, :stop], %{turn: 1, tokens: 150},
                      %{status: :running}}

      assert result == state

      :telemetry.detach("test-tool-exec-#{inspect(ref)}")
    end
  end

  describe "on_error hook" do
    test "emits [:anvil, :error] event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-error-#{inspect(ref)}",
        [:anvil, :error],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      state = build_state(status: :error, error: "something broke")
      result = Telemetry.call(:on_error, state)

      assert_receive {:telemetry_event, [:anvil, :error], %{turn: 1},
                      %{status: :error, error: "something broke"}}

      assert result == state

      :telemetry.detach("test-error-#{inspect(ref)}")
    end
  end
end
