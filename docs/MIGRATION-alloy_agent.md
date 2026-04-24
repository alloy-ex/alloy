# Migrating runtime concerns to `alloy_agent`

Alloy 0.12.1 marks `Alloy.Agent.Server`, `Alloy.Session`, and
`Alloy.Agent.Events` as moved to the new
[`alloy_agent`](https://hex.pm/packages/alloy_agent) package. These
modules continue to work in 0.12.x but will be **removed in Alloy 0.13.0**.

This doc is the migration you want to run now — once, mechanically,
across your codebase — rather than hit the hard break in 0.13.

## Why the split

Alloy is refocusing as a protocol library: the loop
(`Alloy.run/2`, `Alloy.stream/3`), the provider behaviour, the tool
behaviour, the memory behaviour, the message types. Everything that
speaks the wire.

Runtime concerns — supervised processes, sessions, async dispatch,
PubSub broadcast, backpressure queues, cost guards, fallback provider
chains, default memory stores — belong above the protocol. They lived
in Alloy because the split wasn't clean yet; they now live in their
own package so you can opt in.

The Elixir-specific argument: OTP *is* the runtime. `Phoenix.PubSub`,
`Task.Supervisor`, `Registry`, `GenStage` are primitives every Elixir
developer already knows. A protocol library that composes *with* OTP
is more valuable here than a runtime library that competes with it.

## Who needs to migrate

If your code touches any of these, yes:

- `alias Alloy.Agent.Server`
- `%Alloy.Session{}` as a struct
- `Alloy.Session.new/1` or `Alloy.Session.update_from_result/2`
- `Alloy.Agent.Events` (module rarely used directly)
- `Alloy.send_message/3`, `Alloy.cancel_request/2` (delegates)

If you only use `Alloy.run/2`, `Alloy.stream/3`, tools, providers,
messages, results, or the memory behaviour — no changes needed.

## The migration

### 1. Add the dep

```elixir
# mix.exs
def deps do
  [
    {:alloy, "~> 0.12"},
    {:alloy_agent, "~> 0.1"}
  ]
end
```

Then `mix deps.get`.

### 2. Mechanical find/replace

| Before | After |
|---|---|
| `alias Alloy.Agent.Server` | `alias AlloyAgent.Server` (or `alias AlloyAgent`) |
| `Alloy.Agent.Server.start_link(...)` | `AlloyAgent.start_link(...)` |
| `Alloy.Agent.Server.chat(pid, msg)` | `AlloyAgent.chat(pid, msg)` |
| `Alloy.Agent.Server.stream_chat(...)` | `AlloyAgent.stream_chat(...)` |
| `Alloy.Agent.Server.send_message(...)` | `AlloyAgent.send_message(...)` |
| `Alloy.Agent.Server.cancel_request(...)` | `AlloyAgent.cancel_request(...)` |
| `Alloy.Agent.Server.export_session(pid)` | `AlloyAgent.export_session(pid)` |
| `Alloy.send_message/3` | `AlloyAgent.send_message/3` |
| `Alloy.cancel_request/2` | `AlloyAgent.cancel_request/2` |
| `%Alloy.Session{...}` | `%AlloyAgent.Session{...}` |
| `Alloy.Session.new/1` | `AlloyAgent.Session.new/1` |
| `Alloy.Session.update_from_result/2` | `AlloyAgent.Session.update_from_result/2` |
| `Alloy.Session.t()` (typespec) | `AlloyAgent.Session.t()` |
| `alias Alloy.Agent.Events` (rare) | `alias AlloyAgent.Events` |

The `Alloy.Agent.{Config, State, Turn}` modules are **internal** loop
mechanics and stay in Alloy — don't rename those. You're unlikely to
import them directly anyway.

### 3. Default memory stores (new in alloy_agent 0.1.0)

If you're using Anthropic's memory tool (added in Alloy 0.12.0) and
writing your own store, `alloy_agent` ships two reference
implementations:

```elixir
# Process-local, dies with the store process
{:ok, mem_pid} = AlloyAgent.Memory.InMemory.start_link()
memory = {AlloyAgent.Memory.InMemory, mem_pid}

# Filesystem-backed, survives restarts, session-scoped
memory = AlloyAgent.Memory.Disk.new(
  root: "/var/agent/memories",
  session_id: "acct-42"
)

# Either works with both Alloy.run/2 and AlloyAgent.start_link/1:
Alloy.run("Remember my preferences",
  provider: {Alloy.Provider.Anthropic, ...},
  memory: memory
)
```

For production-grade storage (Postgres via Ecto, S3, Redis, encrypted
at rest), implement `Alloy.Memory` yourself — the behaviour is six
callbacks.

## What happens if I don't migrate

Your code keeps working through the entire Alloy 0.12.x line. When
Alloy 0.13.0 lands, the `Alloy.Agent.Server`, `Alloy.Session`, and
`Alloy.Agent.Events` modules will be removed — imports referencing
them will fail to compile. Plan your upgrade window accordingly.

## Questions worth asking after migrating

- **Do you still need the GenServer wrapper?** Some use cases
  (LiveView streaming, Phoenix controllers) suit `Alloy.run/2` + your
  own supervision better than `AlloyAgent.Server`. The wrapper is
  there when you want it — it's not the default.
- **Is there runtime policy in your app that should be middleware?**
  `max_budget_cents`, `fallback_providers`, and session lifecycle
  hooks are supported in `AlloyAgent.Server` but could also be
  expressed as `Alloy.Middleware` implementations — sometimes cleaner.
- **Do you have your own memory store that duplicates
  `AlloyAgent.Memory.Disk`?** Worth checking — using the shipped one
  saves code, unless you have requirements (encryption, multi-tenant
  paths, audit logs) it doesn't meet.

## Reporting issues

File against [alloy](https://github.com/alloy-ex/alloy/issues) if the
question is about the protocol, or
[alloy_agent](https://github.com/alloy-ex/alloy_agent/issues) if it's
about the runtime.
