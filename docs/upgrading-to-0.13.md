# Upgrading to Alloy 0.13

Alloy 0.13 makes the library what its README says it is: the agent loop
and nothing else. The supervised runtime moves to its own package,
memory and compaction become ordinary parts of the loop, and everything
0.12.5 deprecated is removed. Most apps that only call `Alloy.run/2` or
`Alloy.stream/3` upgrade without code changes. Compile with
`--warnings-as-errors` and run your tests: everything below fails loudly
rather than silently.

## 1. The agent server moved to `alloy_agent`

`Alloy.Agent.Server`, `Alloy.Session`, `Alloy.send_message`,
`Alloy.cancel_request` and the `config :alloy, :pubsub` setting are now
in the [`alloy_agent`](https://github.com/alloy-ex/alloy_agent) package,
along with in-memory and disk memory stores.

```elixir
def deps do
  [
    {:alloy, "~> 0.13"},
    {:alloy_agent, "~> 0.1"}
  ]
end
```

| Before | After |
|---|---|
| `Alloy.Agent.Server.start_link(opts)` | `AlloyAgent.start_link(opts)` |
| `Alloy.Agent.Server.chat/3`, `stream_chat/4` | `AlloyAgent.chat/3`, `AlloyAgent.stream_chat/4` |
| `Alloy.Agent.Server.send_message/3`, `Alloy.send_message` | `AlloyAgent.send_message/3` |
| `Alloy.Agent.Server.cancel_request/2`, `Alloy.cancel_request` | `AlloyAgent.cancel_request/2` |
| `Alloy.Agent.Server.export_session/1` | `AlloyAgent.export_session/1` |
| `%Alloy.Session{}`, `Alloy.Session.new/1` | `%AlloyAgent.Session{}`, `AlloyAgent.Session.new/1` |
| `alias Alloy.Agent.Events` | `alias Alloy.Events` (still in Alloy) |
| `config :alloy, pubsub: MyApp.PubSub` | start `Phoenix.PubSub` in your own supervision tree and pass `pubsub: MyApp.PubSub` to `AlloyAgent.start_link/1` |

Server options (`:pubsub`, `:subscribe`, `:max_pending`, `:on_shutdown`)
belong to `AlloyAgent.start_link/1`. Passing one to `Alloy.run/2` raises
an `ArgumentError` that points here.

You may not need the server at all: `Alloy.run/2` inside your own
`Task.Supervisor` or GenServer, with `messages: previous_result.messages`
to continue a conversation, is a complete supervised agent.

## 2. Unknown options raise

`Alloy.run/2`, `Alloy.stream/3` and `Alloy.Agent.Config.from_opts/1` used
to ignore options they did not know, so a typo such as `tols:` silently
ran with no tools. They now raise `ArgumentError` listing the valid
options.

## 3. Removed options and functions

| Removed | Replacement |
|---|---|
| `max_budget_cents:` and the `:budget_exceeded` status | `:before_completion` middleware that prices `state.usage` (see "Budget limits" in the README). No built-in provider reported a cost, so the option never fired with them. |
| Anthropic `extended_thinking:` | `extra_body: %{"thinking" => %{"type" => "adaptive"}}`. Setting it now raises, rather than silently turning thinking off. |
| Codex `auth_path:` | `codex_home:` pointing at the directory that holds `auth.json`. Setting it now returns an error, rather than silently running as the default account. |
| `Alloy.Agent.State.materialize`, `State.cleanup`, `state.messages_new` | Read `state.messages`; it always holds the full history. |
| `state.current_task`, `state.pending_requests` | Server state, now kept by `alloy_agent`. |
| `Alloy.ModelMetadata.catalog` | `Alloy.ModelMetadata.context_window/1`, or your own `Alloy.ModelCatalog`. |
| `Alloy.Message.server_tool_result_block` | None: providers run server tools themselves. |
| `Alloy.Memory.Router.dispatch_all/2`, `memory_call?/1`, `tool_name/0` | `Alloy.Memory.tool/1` (below). |

## 4. Memory is an ordinary tool

```elixir
# Still works: shorthand for the line below
memory: {MyApp.Memory.Disk, root: "/var/agent/memories"}

# The tool itself
tools: [Alloy.Memory.tool({MyApp.Memory.Disk, root: "/var/agent/memories"})]
```

What changes:

- Memory calls run through the tool executor, so `:before_tool_call`
  middleware sees them (it can block or edit them), `:tool_start` and
  `:tool_end` events fire, `:tool_timeout` applies, and they appear in
  `result.tool_calls`. They used to bypass all of these.
- Calls run one at a time, in the order the model made them.
- Memory works with every provider. Anthropic receives Claude's native
  `memory_20250818` tool; other providers receive a function tool with the
  same six commands.
- Two tools with the same name now raise at startup, for every tool, not
  only `memory`.

Your `Alloy.Memory` store needs no changes.

## 5. Compaction is middleware

`Alloy.Context.Compactor` implements `Alloy.Middleware`, and `Alloy.run/2`
puts it first in `:middleware`, so compaction behaves as before by default.

- `compaction: false` turns it off.
- Listing `Alloy.Context.Compactor` in `:middleware` yourself sets where it
  runs relative to your middleware.
- A `%Alloy.Agent.Config{}` built by hand (not through `from_opts/1`) has
  no compaction unless its `:middleware` lists the compactor.
- When the provider rejects a request as too long, the loop runs the new
  `:on_context_overflow` hook (the compactor forces a compaction there) and
  retries once **only if the messages changed**. 0.12 retried even when
  nothing could be removed.
- `:after_compaction` and `[:alloy, :compaction, :done]` now also fire
  after that forced compaction.

If your middleware matches hooks exhaustively, add a catch-all clause,
`def call(_hook, state), do: state`, for `:on_context_overflow`.

## 6. Messages record their provider

Assistant messages produced by the loop now carry `provider` and `model`
fields, and the loop uses them to rewrite one provider's reasoning before
sending it to another (see `Alloy.Message.normalize_for/2`). Pattern
matches are unaffected, but a test that compares whole messages with
`==` against `Message.assistant("...")` needs to match the fields it
cares about instead:

```elixir
assert [%Message{role: :assistant, content: "Hello"}] = result.messages
```

## 7. Smaller changes

- `Alloy.Agent.State` has a `deadline` field: the monotonic time by which
  the run's provider requests must finish. Middleware that makes its own
  provider request, like the compactor, should respect it.
- Tools can declare `native_types/0` (`:native_types` for inline tools): a
  provider's built-in schema for the tool. Anthropic reads `:anthropic`.
- `phoenix_pubsub` is no longer an optional dependency of Alloy.
