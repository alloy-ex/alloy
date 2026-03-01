# Alloy Roadmap

Last updated: 2026-02-26

## Current State

- **LOC**: ~5,400 (lib/) + ~5,500 (test/)
- **Tests**: 272, 0 failures
- **Providers**: Anthropic, Google (Gemini), OpenAI, Ollama (local), OpenRouter (100+ models), xAI (Grok), DeepSeek, Mistral
- **Tools**: read, write, edit, bash, scratchpad
- **Core**: Turn loop, GenServer wrapper, middleware pipeline, telemetry, context compaction, streaming, multi-agent teams
- **Async runtime**: `send_message/3` supports bounded queueing (`max_pending`) and cancellation by `request_id` (`cancel_request/2`)

### Completed (v0.1)

- [x] Context file auto-discovery (`.alloy/context/*.md`, 3-tier: global/git-root/cwd)
- [x] Richer extension events (`:before_tool_call` with blocking, `:session_start`, `:session_end`)
- [x] Skills system (frontmatter parsing, discovery, placeholder expansion, REPL integration)
- [x] Cron/heartbeat scheduler (GenServer + Task.Supervisor, overlap protection, dynamic jobs)

### Completed (v0.1.1 — Core UX + OTP Differentiator)

- [x] Streaming responses (optional `stream/4` callback, Anthropic SSE, Turn loop auto-detect)
- [x] Mid-session model switching (`Server.set_model/2`, `/model` REPL command)
- [x] REPL quality of life (`/help`, `/usage`, `/history`, `/reset`)
- [x] Multi-agent teams (`Alloy.Team` — delegate, broadcast, handoff, shared context, fault isolation)

---

## Phase 1: Core UX (Next)

### Streaming Responses
**Priority: HIGH | Effort: Medium | Status: DONE**

Token-by-token streaming from providers to REPL/callers.

- New `Provider` callback: `stream/3` returning a `Stream` or callback-based approach
- Turn loop adaptation for streaming mode
- REPL prints tokens as they arrive
- Server needs a streaming `chat/2` variant (or callback option)
- Middleware hooks: `:on_stream_chunk` (optional)

### Mid-Session Model Switching
**Priority: HIGH | Effort: Small | Status: DONE**

Switch provider/model without resetting conversation history.

- `Server.set_model(pid, {provider, config})` — swaps config, keeps messages
- REPL command: `/model gemini-flash` or `/model anthropic/claude-haiku-4-5-20251001`
- Validate new config before swapping

### REPL Quality of Life
**Priority: MEDIUM | Effort: Small | Status: DONE**

- `/history` — show conversation summary
- `/usage` — show token usage and estimated cost
- `/reset` — clear conversation
- `/help` — list available commands and skills
- Arrow key history (via `:io.get_line` or Owl library)

---

## Phase 2: OTP Differentiators

### Multi-Agent Teams
**Priority: HIGH | Effort: Medium | Status: DONE**

Supervisor trees of collaborating agents. The killer feature Pi can't replicate.

```elixir
Alloy.Team.start_link(
  agents: [
    researcher: [provider: gemini_flash, tools: [WebSearch], system_prompt: "..."],
    coder: [provider: claude, tools: [Read, Write, Edit, Bash]]
  ],
  strategy: :one_for_one
)
Alloy.Team.delegate(team, :researcher, "Find the latest Elixir release notes")
```

- `Alloy.Team` — Supervisor wrapper with named agent children
- Inter-agent messaging via Server.chat
- Shared session context (optional)
- Fault isolation: one agent crashes, others keep running

### Agent Pooling
**Priority: MEDIUM | Effort: Medium | Status: Planned — Separate package**

Rate-limited pool of agents for batch workloads.

- NimblePool or Poolboy-based
- Queue requests when all agents busy
- Per-pool rate limiting (e.g., max 10 API calls/min)
- Package: `alloy_pool`

---

## Phase 3: Provider Breadth

### Priority Providers to Add
**Effort: ~100 LOC each | Status: As needed**

| Provider | Why | Priority | Status |
|----------|-----|----------|--------|
| Ollama | Local models, no API key needed, great for dev | HIGH | **DONE** |
| OpenRouter | One API key → 100+ models (Qwen, MiniMax, etc.) | HIGH | **DONE** |
| xAI (Grok) | Real-time knowledge, strong reasoning | HIGH | **DONE** |
| DeepSeek | Cost-effective, strong coding (R1 reasoning) | HIGH | **DONE** |
| Mistral | European AI, strong multilingual, Codestral | HIGH | **DONE** |
| AWS Bedrock | Enterprise customers | MEDIUM | Planned |
| Azure OpenAI | Enterprise customers | MEDIUM | Planned |
| Groq | Fast inference, good for tools-heavy flows | LOW | Planned |

### Provider Architecture Note
Each provider is ~200 LOC implementing the `Provider` behaviour. Adding providers is
mechanical work — translate wire format to/from `Alloy.Message`. The behaviour already
handles the abstraction cleanly.

---

## Phase 4: Ecosystem (Separate Packages)

### Agent Pooling — `alloy_pool`
**Status: Planned | Deps: NimblePool or Poolboy | Priority: HIGH for production use**

Rate-limited pool of agents for batch/API workloads.

**What it does:**
- Pool of N agent processes, queues requests when all busy
- Per-pool rate limiting (e.g., max 60 API calls/min across all pooled agents)
- Checkout/checkin semantics — caller gets exclusive access to an agent for a request
- Dead agent replacement — pool auto-restarts crashed agents

**Why separate:** Introduces opinion about pool sizing strategy and adds a NimblePool
dependency. Not every Alloy user needs pooling — it's a production scaling concern.

**API sketch:**
```elixir
{:ok, pool} = Alloy.Pool.start_link(
  size: 5,
  agent_opts: [provider: {Anthropic, api_key: "..."}, tools: [Read, Bash]]
)
{:ok, result} = Alloy.Pool.run(pool, "Analyze this file")  # queues if all busy
Alloy.Pool.stats(pool)  # %{busy: 3, idle: 2, queued: 0}
```

**Estimated effort:** ~200 LOC wrapping NimblePool. 1-2 days.

---

### Distributed Agents — `alloy_distributed`
**Status: Future | Deps: libcluster (optional) | Priority: LOW**

Agents running across Erlang cluster nodes, coordinated via pg (process groups)
or distributed Registry.

**What it does:**
- Start agents on remote nodes in a cluster
- Route requests to the least-loaded node
- Failover: if a node goes down, agents restart on surviving nodes
- Shared session state via distributed ETS or CRDT

**Why separate:** Requires cluster infrastructure (libcluster), different deployment
model (releases, node naming). Most users run single-node.

**Use cases:**
- Fleet of 100+ agents across machines for batch processing
- Geographic distribution (agents near data sources)
- High availability (survive node failures)

**Estimated effort:** 500-800 LOC. Requires distributed Erlang expertise. 1-2 weeks.

---

### Broadway/GenStage Pipelines — `alloy_pipeline`
**Status: Future | Deps: Broadway or GenStage | Priority: MEDIUM**

Event-driven processing of work items through agent chains with backpressure.

**What it does:**
- Define multi-stage agent pipelines (e.g., classify → analyze → summarize)
- Broadway-style batching and rate limiting
- Backpressure: downstream stages slow down upstream when overloaded
- Dead letter queue for failed items
- Telemetry integration for pipeline observability

**Why separate:** Heavy dependency (Broadway), opinionated pipeline topology.
Only needed for high-volume batch processing scenarios.

**Use cases:**
- Process 10K support tickets through classify → route → respond pipeline
- Code review pipeline: parse → analyze → report → create issues
- Document processing: extract → transform → load

**API sketch:**
```elixir
Alloy.Pipeline.start_link(
  stages: [
    classifier: [provider: gemini_flash, system_prompt: "Classify..."],
    analyzer: [provider: claude, system_prompt: "Analyze...", tools: [Read]],
    reporter: [provider: gemini_flash, system_prompt: "Summarize..."]
  ],
  concurrency: [classifier: 10, analyzer: 5, reporter: 3]
)
Alloy.Pipeline.push(pipeline, "Review PR #1234")
```

**Estimated effort:** 400-600 LOC wrapping Broadway. 1 week.

---

### Phoenix LiveView Integration — `alloy_live`
**Status: Future | Deps: Phoenix, Phoenix.LiveView | Priority: MEDIUM**

Real-time agent UI in Phoenix. Streaming tokens push to browser via LiveView.

**What it does:**
- `AlloyLive.ChatComponent` — drop-in LiveView component for agent chat
- Streaming tokens push via LiveView socket (no WebSocket boilerplate)
- Tool execution progress indicators
- Conversation history with collapsible tool results
- Multi-agent dashboard showing all running agents

**Why separate:** Phoenix is a framework dependency. Most Alloy users won't
use Phoenix. Those who do get first-class integration.

**API sketch:**
```elixir
# In your LiveView
def mount(_params, _session, socket) do
  {:ok, agent} = Alloy.Agent.Server.start_link(agent_opts)
  {:ok, assign(socket, agent: agent, messages: [])}
end

def handle_event("send", %{"message" => msg}, socket) do
  # AlloyLive handles streaming tokens to the browser
  AlloyLive.stream_chat(socket, socket.assigns.agent, msg)
end
```

**Estimated effort:** 300-500 LOC. 3-5 days. Requires Phoenix knowledge.

---

### Rich TUI — `alloy_tui`
**Status: Future | Deps: Owl or Ratatouille | Priority: LOW**

Full terminal UI with panels, scrollback, syntax highlighting, split panes.

**What it does:**
- Multi-pane layout (chat, tool output, status bar)
- Syntax-highlighted code blocks in responses
- Scrollback buffer with search
- Progress indicators for tool execution
- Mouse support (click to expand tool results)

**Why separate:** TUI libraries are heavy dependencies with platform-specific
concerns. The basic IO.gets REPL in core is sufficient for most use cases.

**Estimated effort:** 500-1000 LOC. 1-2 weeks. Depends on TUI library maturity.

---

### Tree-Structured Sessions — `alloy_sessions`
**Status: Future | Deps: none | Priority: MEDIUM**

Rewind, branch, and explore alternative conversation paths.

**What it does:**
- Save conversation state at any point (checkpoint)
- Rewind to a previous checkpoint
- Branch: create parallel conversation paths from a checkpoint
- Compare: diff two conversation branches
- Persist to disk or database

**Why separate:** Adds complexity to the Session struct. Current linear session
model is simpler and sufficient for most use cases. Tree sessions add storage
and UI concerns.

**Estimated effort:** 200-300 LOC for the data structure. UI integration adds more.

---

## Why Elixir / OTP?

Alloy's moat is the **production runtime**. Most agent frameworks target the single-developer
CLI experience. Alloy targets what happens after — when you need agents running in production
with supervision, fault isolation, concurrency, and multi-agent orchestration.

### What OTP gives us for free
- Multi-agent teams (delegate, broadcast, handoff, fault isolation, shared context)
- Supervision trees (auto-restart crashed agents)
- Real parallel tool execution (BEAM processes, not threads or event loops)
- GenServer agent wrapping (stateful, supervisable, message-passing)
- Zero-dependency cron scheduling (Process.send_after)
- Hot code reloading (update agents without stopping conversations)
- Deterministic test provider (scripted responses for full TDD)
- Built-in telemetry and observability
- Path to pooling and distributed agents — architecturally native to the BEAM

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-25 | Skills parser stays in core | 100 LOC, no dependencies, skill files are external |
| 2026-02-25 | Scheduler stays in core | OTP-native, zero dependencies, ~250 LOC |
| 2026-02-25 | Streaming is next priority | Biggest single UX gap for interactive use |
| 2026-02-25 | Agent pooling → separate package | Opinionated about pool sizing, adds NimblePool dep |
| 2026-02-25 | Distributed agents → separate package | Advanced use case, different deployment model |
| 2026-02-25 | Phoenix integration → separate package | Framework dependency |
| 2026-02-26 | Team uses GenServer + DynamicSupervisor | Needs mutable state (agent registry), `:temporary` children so Team handles restarts |
| 2026-02-26 | Async GenServer.reply for delegate/broadcast/handoff | Keeps Team responsive during long-running agent chats |
| 2026-02-26 | Crashed agents are removed, not restarted | Simplest correct behaviour; users can add back or use supervision |
