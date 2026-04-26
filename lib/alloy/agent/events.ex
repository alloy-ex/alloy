defmodule Alloy.Agent.Events do
  @moduledoc """
  Deprecated alias for `Alloy.Events`.

  > #### Renamed to `Alloy.Events` {: .warning}
  >
  > The v1 event envelope module has been promoted to the top-level
  > namespace as `Alloy.Events`. It is part of Alloy's protocol surface
  > — `Alloy.Agent.Turn` calls it directly, so it is **not** moving to
  > the `alloy_agent` runtime package.
  >
  > This shim will be removed in Alloy 0.13.0. Update `alias` lines from
  > `Alloy.Agent.Events` to `Alloy.Events`.
  >
  > Note: Alloy 0.12.1 incorrectly listed this module as moving to
  > `AlloyAgent.Events`. That guidance was wrong and is retracted in
  > 0.12.2 — see `docs/MIGRATION-alloy_agent.md` for the corrected table.
  """

  alias Alloy.Agent.State

  @deprecated "Use Alloy.Events.normalize_opts/2 instead. Will be removed in Alloy 0.13.0."
  @spec normalize_opts(State.t(), keyword()) :: keyword()
  defdelegate normalize_opts(state, opts), to: Alloy.Events

  @deprecated "Use Alloy.Events.build_correlation_id/1 instead. Will be removed in Alloy 0.13.0."
  @spec build_correlation_id(State.t()) :: binary()
  defdelegate build_correlation_id(state), to: Alloy.Events

  @deprecated "Use Alloy.Events.emit/3 instead. Will be removed in Alloy 0.13.0."
  @spec emit(keyword(), non_neg_integer(), term()) :: :ok
  defdelegate emit(opts, turn, raw_event), to: Alloy.Events
end
