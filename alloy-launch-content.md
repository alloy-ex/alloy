# Alloy Launch Content — Channel-Specific Posts

## Posting Schedule (All times AEST / Brisbane)

### Option A: Post Today (Thursday 27 Feb)

| Order | Channel | Time (AEST) | Time (ET) | Notes |
|-------|---------|-------------|-----------|-------|
| 1 | **LinkedIn** | 6:00pm Thu | 3:00am → shows in US Fri morning feeds | Post first — longest dwell time |
| 2 | **X / Twitter** | 6:30pm Thu | 3:30am → US wakes up to it | Same evening, 30 min gap |
| 3 | **Elixir Forum** | 11:00pm Thu | 8:00am ET Fri morning | Peak forum activity |
| 4 | **r/elixir** | 11:00pm Fri | 8:00am ET Sat | 24h stagger from Forum |
| 5 | **Hacker News** | 5:00pm Sun | 2:00am ET → US wakes up | Low competition Sunday slot |

### Option B: Wait for Tuesday (optimal algo timing)

| Channel | Day | Time (AEST) | Time (ET) | Why |
|---------|-----|-------------|-----------|-----|
| **LinkedIn** | Tuesday | 6:00pm | 3:00am ET → shows in US morning feeds | LinkedIn algo favours Tue/Wed |
| **X / Twitter** | Tuesday | 11:30pm | 8:30am ET | Same day as Forum |
| **Elixir Forum** | Tuesday | 11:00pm | 8:00am ET | Peak mid-week |
| **r/elixir** | Wednesday | 11:00pm | 8:00am ET | 24h stagger |
| **Hacker News (Show HN)** | Sunday | 5:00pm | 2:00am ET | Low competition |

**Recommendation**: Post today. Momentum > algorithm timing. The content is strong enough to perform on any day. Save HN for Sunday regardless — that's the one where timing really matters.

---

## 1. ELIXIR FORUM — "Show" Post

**Title**: Alloy — a model-agnostic agent engine for Elixir

**Category**: Show & Tell

**Post**:

---

I've been building agents in Elixir for a while now and kept running into the same problem: every framework either locks you into one LLM provider, ships a dozen dependencies you don't need, or treats Elixir like a second-class citizen behind Python.

So I built Alloy. It's a pure agent loop — four tools (read, write, edit, bash), three dependencies (jason, req, telemetry), one behaviour per provider. You give it a prompt, a provider, and some tools, and it runs the completion/tool-call cycle until the job is done. Swap `Alloy.Provider.Anthropic` for `Alloy.Provider.OpenAI` and nothing else changes.

The philosophy is similar to pi-agent: what you leave out matters more than what you put in. If an agent needs a capability Alloy doesn't ship, the agent writes the code itself.

Here's the basic idea:

```elixir
{:ok, result} = Alloy.run("Read mix.exs and tell me the version",
  provider: {Alloy.Provider.Anthropic, api_key: System.get_env("ANTHROPIC_API_KEY"), model: "claude-sonnet-4-6"},
  tools: [Alloy.Tool.Core.Read]
)
```

What it does:

- **8 providers** — Anthropic, OpenAI, Gemini, Ollama, OpenRouter, xAI, DeepSeek, Mistral. Adding one is ~200 lines implementing a behaviour.
- **GenServer agents** — `Alloy.Agent.Server` wraps the loop in a supervised process. You get stateful, long-running agents with message-passing.
- **Multi-agent teams** — `Alloy.Team` gives you delegate, broadcast, and handoff between named agents with fault isolation.
- **Streaming** — token-by-token from any provider, same interface.
- **Middleware** — plug in telemetry, logging, tool blockers, or custom hooks before/after completions and tool calls.
- **Context compaction** — automatic summarization when conversations approach the token limit.

The part I'm most interested in feedback on is the Team abstraction. Right now you can delegate tasks to specific agents, broadcast to all of them, or hand off a conversation from one agent to another. Each agent is its own supervised GenServer, so if one crashes the others keep going.

```elixir
{:ok, team} = Alloy.Team.start_link(
  agents: [
    researcher: [
      provider: {Alloy.Provider.Google, api_key: "...", model: "gemini-2.5-flash"},
      system_prompt: "You are a research assistant."
    ],
    coder: [
      provider: {Alloy.Provider.Anthropic, api_key: "...", model: "claude-sonnet-4-6"},
      tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Write],
      system_prompt: "You are a senior developer."
    ]
  ]
)

{:ok, research} = Alloy.Team.delegate(team, :researcher, "Find the latest Elixir 1.18 changes")
{:ok, code} = Alloy.Team.delegate(team, :coder, "Update our code based on: #{research.text}")
```

It's on Hex as `{:alloy, "~> 0.3.0"}` and the docs are at [hexdocs.pm/alloy](https://hexdocs.pm/alloy).

I've been using it in production for a few internal tools and it's been solid, but I'd love to hear what the community thinks — especially around the provider behaviour interface and whether the tool abstraction makes sense.

GitHub: [github.com/alloy-ex/alloy](https://github.com/alloy-ex/alloy)
Hex: [hex.pm/packages/alloy](https://hex.pm/packages/alloy)
Site: [alloylabs.dev](https://alloylabs.dev)

Happy to answer questions or take PRs.

---

## 2. REDDIT r/elixir

**Title**: Alloy — model-agnostic agent engine for Elixir (8 providers, GenServer agents, multi-agent teams)

**Post**:

---

I've been working on an agent engine for Elixir. Not a framework — an engine. It's called Alloy.

Three dependencies (jason, req, telemetry). Four tools (read, write, edit, bash). Eight providers out of the box. The design is deliberately minimal — similar to pi-agent's philosophy that what you leave out matters more than what you put in. If an agent needs a capability, it writes the code itself.

`Alloy.run/2` takes a prompt, a provider tuple, and a list of tools. It runs the completion → tool-call loop until done. Change the provider tuple and everything else stays the same.

The OTP angle: agents run as supervised GenServers via `Alloy.Agent.Server`. Multi-agent teams with `Alloy.Team` — each agent is its own process, fault-isolated, with delegate/broadcast/handoff. Also ships with streaming, middleware, context compaction, and a CLI REPL (`mix alloy`).

For comparison: Jido ships 14 dependencies and a prescribed architecture. LangChain is an integration layer without an agent loop. Alloy is the loop and nothing else.

v0.3.0 is on Hex: `{:alloy, "~> 0.3.0"}`

- [GitHub](https://github.com/alloy-ex/alloy)
- [Docs](https://hexdocs.pm/alloy)
- [Site](https://alloylabs.dev)

Would be interested to hear what people think about the approach — especially whether "minimal engine + self-extending agent" resonates vs the batteries-included approach.

---

## 3. HACKER NEWS — Show HN

**Title**: Show HN: Alloy – Model-agnostic AI agent engine for Elixir/OTP

**URL**: https://github.com/alloy-ex/alloy

**Comment** (post as first comment on your own submission):

---

I built this because I kept running into the same problem with AI agent runtimes: they're all single-process Python programs pretending to be infrastructure.

Look at what happens when an agent crashes in most frameworks. The whole runtime goes down — every agent, every conversation, every piece of state. Or look at multi-agent setups: they're async coroutines sharing memory, so one agent's bad tool call can corrupt another agent's context. OpenClaw has 225k stars and persistent RCE vulnerabilities because the architecture makes isolation almost impossible. These aren't bugs you can patch. They're consequences of building agents as scripts instead of processes.

Alloy runs on Erlang/OTP — the same runtime that handles 2 billion WhatsApp users with a team of 50 engineers. Here's what that means in practice:

**Each agent is its own process with its own memory.** Not a thread, not a coroutine — a lightweight isolated process. Agent A literally cannot read Agent B's state. There's no shared memory to corrupt. If one agent's tool call throws an exception, it crashes its own process and nothing else.

**Supervisors restart crashed agents automatically.** You define a restart strategy (one-for-one, rest-for-one, etc.) and the runtime handles recovery. An agent can crash at 3am and be back up in milliseconds without waking anyone up.

**Message passing replaces shared state.** Agents communicate through mailboxes. No locks, no mutexes, no race conditions. A team of 5 agents is 5 actual concurrent processes — not 5 coroutines taking turns on one thread.

The agent engine itself is minimal: four tools (read, write, edit, bash), three dependencies (jason, req, telemetry), eight providers (Anthropic, OpenAI, Gemini, Ollama, OpenRouter, xAI, DeepSeek, Mistral). Design philosophy is close to pi-agent — what you leave out matters more than what you put in. If the agent needs something Alloy doesn't ship, the agent writes the code itself.

On Hex as `{:alloy, "~> 0.3.0"}`.

---

## 4. LINKEDIN

**Post**:

---

I shipped something I've been working on for a while — an open-source agent engine for Elixir called Alloy.

Here's the problem it solves. Most AI agent frameworks are Python programs running as a single process. When one agent crashes, it takes everything down. When you run multiple agents, they share memory — so one agent's bad API call can corrupt another agent's state. This is why projects like OpenClaw keep having security incidents despite 225k stars. The architecture makes isolation nearly impossible.

Alloy runs on Erlang/OTP — the same runtime behind WhatsApp (2B users, 50 engineers) and Discord's real-time infrastructure. What that means in plain terms:

- Each agent runs in its own isolated process. It can't read another agent's memory or credentials. Not through sandboxing — through actual process isolation at the VM level.
- If an agent crashes, a supervisor restarts it in milliseconds. The other agents don't even notice. This happens automatically at 3am without paging anyone.
- Agents communicate through message passing, not shared state. No locks. No race conditions. A team of 5 agents is 5 truly concurrent processes, not 5 coroutines taking turns.

The engine itself is deliberately minimal — three dependencies, four tools (read, write, edit, bash), eight LLM providers. Swap Anthropic for OpenAI or Gemini in one line. If an agent needs a capability Alloy doesn't ship, the agent writes the code itself. No plugin marketplace. No dependency bloat.

GitHub: https://github.com/alloy-ex/alloy
Site: https://alloylabs.dev

We're also building AnvilOS — persistence, connectors, a dashboard, and a runtime for 24/7 agent hosting. Engine today, runtime tomorrow.

If you're working on AI agents in production and keep hitting infrastructure walls, I'd like to hear about it.

---

## 5. X / TWITTER

**Thread** (4 tweets):

---

**Tweet 1:**
Shipped Alloy — an open-source agent engine for Elixir.

3 dependencies. 4 tools. 8 LLM providers. The agent loop and nothing else.

If it needs a capability Alloy doesn't have, the agent writes the code itself.

https://github.com/alloy-ex/alloy

🧵

---

**Tweet 2:**
Most agent frameworks are one Python process. One agent crashes, everything goes down. Multiple agents share memory — one bad tool call corrupts another's state.

This is why OpenClaw keeps having RCE vulnerabilities despite 225k stars. The architecture makes isolation almost impossible.

---

**Tweet 3:**
Alloy runs on Erlang/OTP — same runtime as WhatsApp (2B users, 50 engineers).

Each agent = isolated process. Can't read another agent's memory. Crashes? Supervisor auto-restarts in ms. 50 agents = 50 real concurrent processes, not coroutines.

The BEAM VM has been solving this exact problem for telecom for 30 years.

---

**Tweet 4:**
What's in the box:
- Anthropic, OpenAI, Gemini, Ollama + 4 more
- Swap providers in one line
- Supervised agents (stateful, auto-healing)
- Multi-agent teams (delegate, broadcast, handoff)
- Streaming from any provider
- Context compaction

Docs: https://hexdocs.pm/alloy
Site: https://alloylabs.dev

---

## Writing Style Notes (Applied Above)

Based on Wikipedia's AI writing detection guide, these posts avoid:
- **Generic significance claims** — no "pivotal", "groundbreaking", "game-changing"
- **Trailing participles** — no "highlighting the importance of", "showcasing the power of"
- **Marketing superlatives** — no "revolutionary", "seamless", "cutting-edge"
- **Hedge-then-claim** — no "While X, it's worth noting that Y"
- **Bullet-point-only structure** — mixed prose and code, not just feature lists
- **Passive voice** — "I built this" not "This was built"

Instead uses:
- First person ("I built", "I've been")
- Specific technical details over vague claims
- Code examples that show real usage
- Honest framing ("I'd love feedback", "I'd like to hear what problems you're running into")
- Varied sentence structure and length
- Direct comparisons without disparaging alternatives

---

## Post-Launch Follow-up (Week 2)

After the initial posts, follow up with:

1. **Elixir Forum thread reply** — Share any early feedback, usage numbers, or interesting bugs found
2. **Blog post** — "Why Elixir is the best language for AI agents" (technical argument, not marketing)
3. **ElixirStatus.com** — Submit a link (gets tweeted by @elaborated)
4. **Tag on X** — @josevalim, @chris_mccord, @braborodrigo — they frequently boost Elixir projects. Don't ask for retweets, just tag naturally in a reply or quote tweet.
