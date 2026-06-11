# Event envelope specification (v1)

Every event Alloy emits to an `:on_event` callback is wrapped in a
versioned envelope built by `Alloy.Events`. The envelope is part of
Alloy's **protocol surface**: anything documented here is something you
can build UIs and pipelines against, and changes to it follow semver.
Anything *not* documented here (raw payload internals beyond the listed
fields) may change between minor versions.

## Where you receive envelopes

- `Alloy.stream/3` — pass `:on_event` in opts; the callback receives
  every envelope for the run.
- `Alloy.Agent.Server` (until its move to `alloy_agent`) — envelopes are
  broadcast over Phoenix.PubSub.
- `Alloy.run/2` does **not** currently accept `:on_event` — use
  `Alloy.stream/3` when you need run events.

A lower-level analogue is fired for every envelope via `:telemetry` as
`[:alloy, :event]` with measurements `%{seq: seq}` and metadata
`%{v:, event:, correlation_id:, turn:}`.

## Envelope shape

```elixir
%{
  v: 1,                     # envelope version — always 1 for this spec
  seq: 42,                  # monotonically increasing within a run, starts at 1
  correlation_id: "req-x",  # identifies the run (see below)
  turn: 3,                  # agent-loop turn the event belongs to
  ts_ms: 1781234567890,     # System.system_time(:millisecond) at emission
  event: :text_delta,       # event type (atom, see catalog)
  payload: "Hello"          # event-specific payload (see catalog)
}
```

Field guarantees:

- **`v`** — version discriminator. Match on it: `%{v: 1} = envelope`.
- **`seq`** — strictly increasing within one run (atomics-backed). Use it
  to re-order events that arrive out of order (e.g., over PubSub). Do not
  assume contiguity across event types.
- **`correlation_id`** — stable for the whole run. Derived with this
  precedence: `context[:request_id]`, then `context[:correlation_id]`,
  then a generated `"<agent_id>:<random>"`. Set `:request_id` in the
  agent `context:` to correlate envelopes with your own request IDs.
- **`turn`** — the loop turn (1-based) the event was produced in.
- **`ts_ms`** — wall-clock emission time. For ordering, prefer `seq`.

## Event catalog

| `event` | `payload` | Emitted when |
|---|---|---|
| `:text_delta` | `String.t()` — text fragment | streaming providers emit assistant text |
| `:thinking_delta` | `String.t()` — reasoning fragment | providers with reasoning/thinking blocks stream them |
| `:tool_start` | `%{id:, name:, input:}` | a tool call begins executing |
| `:tool_end` | `%{id:, name:, input:, duration_ms:, error:, start_event_seq:}` | a tool call finishes; `error` is `nil` on success, a string otherwise; `start_event_seq` links back to the matching `:tool_start` envelope |
| `:runtime_event` | `term()` — the raw event | anything emitted that isn't a recognized tuple; a forward-compatibility escape hatch |

Consumers should match on the `event` atoms they know and ignore the
rest — new event types may be added in minor versions, and unknown raw
events arrive as `:runtime_event` rather than being dropped.

## Pass-through rule

If a payload handed to the event system is already a v1 envelope
(`%{v: 1, ...}`), it passes through unchanged — sequence numbers and
correlation IDs are not reassigned. This is how tool events keep the
`seq` allocated at execution time.

## Example: consuming events in a LiveView

```elixir
Alloy.stream(prompt, fn _chunk -> :ok end,
  provider: provider,
  context: %{request_id: socket.assigns.request_id},
  on_event: fn
    %{v: 1, event: :text_delta, payload: text} ->
      send(self(), {:append_text, text})

    %{v: 1, event: :tool_start, payload: %{name: name}} ->
      send(self(), {:tool_running, name})

    %{v: 1, event: :tool_end, payload: %{name: name, error: error}} ->
      send(self(), {:tool_done, name, error})

    %{v: 1} ->
      :ok
  end
)
```
