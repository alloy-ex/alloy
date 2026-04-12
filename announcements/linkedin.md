Alloy 0.8.0 is out — the agent engine for Elixir.

If you're building AI agents, you've probably noticed most frameworks lock you into one model provider. Switch to a better model next month? Rewrite your agent.

Alloy takes a different approach: one agent loop that works with any LLM. Anthropic, OpenAI, Gemini, Grok, Ollama, DeepSeek — swap providers by changing one line of config. Your agent logic stays the same.

What's new in 0.8.0:

- Cost guard — set a budget cap and the agent stops before it overspends. No more surprise API bills from a runaway agent.

- Smart context compaction — when conversations get long, Alloy summarises older context instead of just chopping it off. Your agent keeps working on complex tasks without losing track.

- One-shot streaming — simpler API for getting token-by-token responses without the overhead of managing a process.

Built on Elixir/OTP, so you get real fault tolerance: if an agent crashes, its supervisor restarts it. Tools execute in parallel. Agents run as supervised processes alongside the rest of your app.

~5,000 lines of code. Deliberately minimal. Inspired by Pi Agent's philosophy: 4 tools, a good prompt, and a loop. That's the whole framework.

https://hex.pm/packages/alloy
https://github.com/alloy-ex/alloy
