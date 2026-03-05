defmodule Alloy.Agent.Events do
  @moduledoc """
  Event envelope construction and runtime opts normalization.

  Builds v1 event envelopes, manages sequence counters, and derives
  correlation IDs. Extracted from `Alloy.Agent.Turn` to separate
  event plumbing from agent loop control flow.
  """

  alias Alloy.Agent.State

  @doc """
  Normalize runtime opts for event emission.

  Ensures `:on_event`, `:event_seq_ref`, and `:event_correlation_id`
  are present in the opts keyword list.
  """
  @spec normalize_opts(State.t(), keyword()) :: keyword()
  def normalize_opts(%State{} = state, opts) do
    on_event = Keyword.get(opts, :on_event) || fn _event -> :ok end

    opts
    |> Keyword.put(:on_event, on_event)
    |> put_new_lazy(:event_seq_ref, fn -> :atomics.new(1, signed: false) end)
    |> put_new_lazy(:event_correlation_id, fn -> build_correlation_id(state) end)
  end

  @doc """
  Derive a correlation ID from the agent state's context.

  Precedence: `context[:request_id]` > `context[:correlation_id]` >
  generated from `agent_id`.
  """
  @spec build_correlation_id(State.t()) :: binary()
  def build_correlation_id(%State{} = state) do
    context = state.config.context

    cond do
      is_binary(Map.get(context, :request_id)) ->
        Map.get(context, :request_id)

      is_binary(Map.get(context, :correlation_id)) ->
        Map.get(context, :correlation_id)

      true ->
        state.agent_id <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    end
  end

  @doc """
  Emit an event envelope.

  Builds a v1 envelope from the raw event, calls the `on_event` callback,
  and fires a `:telemetry` event.
  """
  @spec emit(keyword(), non_neg_integer(), term()) :: :ok
  def emit(opts, turn, raw_event) do
    on_event = Keyword.get(opts, :on_event) || fn _event -> :ok end
    event_seq_ref = Keyword.get(opts, :event_seq_ref)
    correlation_id = Keyword.get(opts, :event_correlation_id)

    envelope = build_event_envelope(raw_event, event_seq_ref, correlation_id, turn)
    on_event.(envelope)

    :telemetry.execute(
      [:alloy, :event],
      %{seq: envelope.seq},
      %{
        v: envelope.v,
        event: envelope.event,
        correlation_id: envelope.correlation_id,
        turn: envelope.turn
      }
    )
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp build_event_envelope(%{v: 1} = envelope, _seq_ref, _correlation_id, _turn), do: envelope

  defp build_event_envelope({event, payload}, seq_ref, correlation_id, turn)
       when is_atom(event) do
    {seq, effective_correlation_id, normalized_payload} =
      normalize_event_fields(event, payload, seq_ref, correlation_id)

    %{
      v: 1,
      seq: seq,
      correlation_id: effective_correlation_id,
      turn: turn,
      ts_ms: System.system_time(:millisecond),
      event: event,
      payload: normalized_payload
    }
  end

  defp build_event_envelope(raw_event, seq_ref, correlation_id, turn) do
    %{
      v: 1,
      seq: next_event_seq(seq_ref),
      correlation_id: correlation_id,
      turn: turn,
      ts_ms: System.system_time(:millisecond),
      event: :runtime_event,
      payload: raw_event
    }
  end

  defp normalize_event_fields(event, payload, seq_ref, correlation_id)
       when event in [:tool_start, :tool_end] and is_map(payload) do
    seq = Map.get(payload, :event_seq) || next_event_seq(seq_ref)
    effective_correlation_id = Map.get(payload, :correlation_id) || correlation_id
    normalized_payload = Map.drop(payload, [:event_seq, :correlation_id])

    {seq, effective_correlation_id, normalized_payload}
  end

  defp normalize_event_fields(_event, payload, seq_ref, correlation_id) do
    {next_event_seq(seq_ref), correlation_id, payload}
  end

  defp next_event_seq(ref) do
    :atomics.add_get(ref, 1, 1)
  end

  defp put_new_lazy(opts, key, producer) when is_list(opts) and is_function(producer, 0) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      Keyword.put(opts, key, producer.())
    end
  end
end
