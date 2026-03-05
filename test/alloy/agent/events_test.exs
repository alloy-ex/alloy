defmodule Alloy.Agent.EventsTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, Events, State}

  defp build_state(context \\ %{}) do
    config = %Config{
      provider: Alloy.Provider.Test,
      provider_config: %{},
      context: context
    }

    State.init(config, [])
  end

  describe "normalize_opts/2" do
    test "sets default on_event when missing" do
      state = build_state()
      opts = Events.normalize_opts(state, [])

      assert is_function(Keyword.get(opts, :on_event), 1)
    end

    test "preserves provided on_event" do
      state = build_state()
      custom = fn _event -> :custom end
      opts = Events.normalize_opts(state, on_event: custom)

      assert Keyword.get(opts, :on_event) == custom
    end

    test "creates event_seq_ref atomics reference" do
      state = build_state()
      opts = Events.normalize_opts(state, [])

      ref = Keyword.get(opts, :event_seq_ref)
      assert is_reference(ref)
    end

    test "preserves provided event_seq_ref" do
      state = build_state()
      existing_ref = :atomics.new(1, signed: false)
      opts = Events.normalize_opts(state, event_seq_ref: existing_ref)

      assert Keyword.get(opts, :event_seq_ref) == existing_ref
    end

    test "creates event_correlation_id" do
      state = build_state()
      opts = Events.normalize_opts(state, [])

      assert is_binary(Keyword.get(opts, :event_correlation_id))
    end

    test "preserves provided event_correlation_id" do
      state = build_state()
      opts = Events.normalize_opts(state, event_correlation_id: "my-id")

      assert Keyword.get(opts, :event_correlation_id) == "my-id"
    end
  end

  describe "build_correlation_id/1" do
    test "uses context request_id when present" do
      state = build_state(%{request_id: "req-123"})
      assert Events.build_correlation_id(state) == "req-123"
    end

    test "uses context correlation_id as fallback" do
      state = build_state(%{correlation_id: "corr-456"})
      assert Events.build_correlation_id(state) == "corr-456"
    end

    test "prefers request_id over correlation_id" do
      state = build_state(%{request_id: "req-123", correlation_id: "corr-456"})
      assert Events.build_correlation_id(state) == "req-123"
    end

    test "generates agent_id-based ID when no context IDs" do
      state = build_state()
      id = Events.build_correlation_id(state)

      assert is_binary(id)
      assert String.starts_with?(id, state.agent_id <> ":")
    end
  end

  describe "emit/3" do
    test "calls on_event with v1 envelope for tuple events" do
      test_pid = self()
      seq_ref = :atomics.new(1, signed: false)

      opts = [
        on_event: fn envelope -> send(test_pid, {:event, envelope}) end,
        event_seq_ref: seq_ref,
        event_correlation_id: "test-corr"
      ]

      Events.emit(opts, 1, {:text_delta, "hello"})

      assert_received {:event, envelope}
      assert envelope.v == 1
      assert envelope.seq == 1
      assert envelope.correlation_id == "test-corr"
      assert envelope.turn == 1
      assert envelope.event == :text_delta
      assert envelope.payload == "hello"
      assert is_integer(envelope.ts_ms)
    end

    test "passes through pre-built v1 envelopes unchanged" do
      test_pid = self()
      seq_ref = :atomics.new(1, signed: false)

      pre_built = %{
        v: 1,
        seq: 42,
        correlation_id: "pre",
        turn: 3,
        ts_ms: 0,
        event: :foo,
        payload: :bar
      }

      opts = [
        on_event: fn envelope -> send(test_pid, {:event, envelope}) end,
        event_seq_ref: seq_ref,
        event_correlation_id: "ignored"
      ]

      Events.emit(opts, 1, pre_built)

      assert_received {:event, ^pre_built}
    end

    test "wraps raw (non-tuple, non-v1) events as :runtime_event" do
      test_pid = self()
      seq_ref = :atomics.new(1, signed: false)

      opts = [
        on_event: fn envelope -> send(test_pid, {:event, envelope}) end,
        event_seq_ref: seq_ref,
        event_correlation_id: "test-corr"
      ]

      Events.emit(opts, 2, "some raw string")

      assert_received {:event, envelope}
      assert envelope.event == :runtime_event
      assert envelope.payload == "some raw string"
      assert envelope.turn == 2
    end

    test "increments sequence numbers across calls" do
      test_pid = self()
      seq_ref = :atomics.new(1, signed: false)

      opts = [
        on_event: fn envelope -> send(test_pid, {:event, envelope}) end,
        event_seq_ref: seq_ref,
        event_correlation_id: "test-corr"
      ]

      Events.emit(opts, 1, {:a, "first"})
      Events.emit(opts, 1, {:b, "second"})

      assert_received {:event, %{seq: 1}}
      assert_received {:event, %{seq: 2}}
    end

    test "tool_start events extract seq and correlation_id from payload" do
      test_pid = self()
      seq_ref = :atomics.new(1, signed: false)

      opts = [
        on_event: fn envelope -> send(test_pid, {:event, envelope}) end,
        event_seq_ref: seq_ref,
        event_correlation_id: "default-corr"
      ]

      Events.emit(
        opts,
        1,
        {:tool_start, %{event_seq: 99, correlation_id: "tool-corr", name: "read"}}
      )

      assert_received {:event, envelope}
      assert envelope.seq == 99
      assert envelope.correlation_id == "tool-corr"
      # The extracted fields should not appear in payload
      refute Map.has_key?(envelope.payload, :event_seq)
      refute Map.has_key?(envelope.payload, :correlation_id)
      assert envelope.payload.name == "read"
    end
  end
end
