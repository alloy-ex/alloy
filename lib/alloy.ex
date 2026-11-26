defmodule Alloy do
  @moduledoc """
  Model-agnostic agent harness for Elixir.

  Alloy provides the minimal agent loop: send messages to any LLM,
  execute tool calls, loop until done. Zero framework dependencies.

  ## Quick Start

      {:ok, result} = Alloy.run("What is 2+2?",
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-..."},
        system_prompt: "You are helpful."
      )
      result.text #=> "4"

  ## With Tools

      {:ok, result} = Alloy.run("Read mix.exs and tell me the version",
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-..."},
        tools: [Alloy.Tool.Core.Read],
        max_turns: 10
      )

  ## Continuing a Conversation

      {:ok, result} = Alloy.run("Now edit that file",
        provider: {Alloy.Provider.OpenAI, api_key: "sk-..."},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Edit],
        messages: previous_result.messages
      )

  ## One-Shot Streaming

      {:ok, result} = Alloy.stream("Explain OTP", fn chunk ->
        IO.write(chunk)
      end,
        provider: {Alloy.Provider.OpenAI, api_key: "sk-...", model: "gpt-5.4"}
      )

  ## Options

  - `:provider` - `{module, config_keyword_list}` or just `module` (required)
  - `:tools` - list of modules implementing `Alloy.Tool` and/or `Alloy.Tool.Inline` structs built with `Alloy.Tool.inline/1` (default: `[]`)
  - `:system_prompt` - system prompt string (default: `nil`)
  - `:messages` - existing conversation history (default: `[]`)
  - `:max_turns` - maximum agent loop iterations (default: `25`)
  - `:max_tokens` - context window budget for compaction (default: provider model window when known, otherwise `200_000`)
  - `:max_retries` - maximum retries on transient provider errors (default: `3`)
  - `:retry_backoff_ms` - base exponential backoff in milliseconds before jitter (default: `1_000`)
  - `:timeout_ms` - run deadline in milliseconds, or `:infinity` to disable the run-level deadline (per-tool `:tool_timeout` still applies, and HTTP requests default to `receive_timeout: :infinity` unless overridden in `req_options`). When set to a positive integer, bounds HTTP/SSE requests, retries, tool execution, and starting new turns (already-finished answers are not discarded). Retries stop 5 seconds before `:timeout_ms`; non-streaming requests reserve that 5-second headroom in `receive_timeout` once `:timeout_ms > 8_000` (3-second floor clamped to remaining budget), while streaming requests receive the full remaining run budget up to `:timeout_ms`. Hosts wrapping a run in `Task.await/2` should add buffer above `:timeout_ms` for worker/subprocess teardown (default: `120_000`)
  - `:tool_timeout` - per-tool execution timeout in milliseconds, further bounded by the remaining `:timeout_ms` run budget (default: `120_000`)
  - `:compaction` - grouped compaction settings like `reserve_tokens`, `keep_recent_tokens`, and `fallback`, or `false` to disable (default: derived from `:max_tokens`)
  - `:on_compaction` - optional 2-arity callback `(messages_to_summarize, state -> any())` invoked before summary compaction (default: `nil`)
  - `:middleware` - list of `Alloy.Middleware` modules (default: `[]`)
  - `:fallback_providers` - ordered list of fallback `module` or `{module, config}` providers tried when the primary fails before emitting output. During `stream/3`, a fallback provider that does not implement `stream/4` falls back to `complete/3` without emitting `on_chunk` or `:text_delta` callbacks; the full reply is still returned in `result.text` and `result.messages` (default: `[]`)
  - `:memory` - `{store_module, store}` shorthand for adding `Alloy.Memory.tool/1` to `:tools` (default: `nil`)
  - `:tool_validation` - `:required` for object/required-key checks (default), or `:schema` for optional JSON Schema validation (accepts only local `#`-prefixed `$ref`s — rejecting external and absolute self-references — verified against `ex_json_schema` `0.11.x` so the remote schema resolver is never invoked; invalid tool schemas fail fast by raising `ArgumentError` / `InvalidSchemaError` / `Jason.EncodeError` during turn-0 preflight on all configured tools before `:before_completion` middleware runs, and whenever middleware changes tools)
  - `:tool_concurrency` - positive integer limiting parallel tool execution (default: scheduler count). Passing `tool_concurrency: 1` explicitly runs each tool call as its own singleton batch so `:tool_start` and `:tool_end` events alternate per call
  - `:stop_after_tool` - complete successfully after this tool succeeds; settle the whole round and return its output (default: `nil`)
  - `:output_schema` - portable JSON Schema map (or `%{name: ..., schema: ..., strict: ...}`) for structured outputs across Anthropic, OpenAI, xAI, OpenAICompat, Gemini, and Codex. Decodes and validates the final assistant response into `result.output` before `:after_completion`, failing terminally with `result.metadata.run.output_error` on invalid/truncated/refused/non-conforming output. See `Alloy.OutputSchema` for full provider, validation-tier, and failure semantics (default: `nil`)
  - `:reasoning` - portable reasoning effort (`nil | :off | :low | :medium | :high | :xhigh | %{effort: ..., display?: :summarized | :omitted}`), translated across Anthropic, OpenAI, xAI, Gemini, OpenAICompat, and Codex, forwarded to fallback providers (unless overridden per provider), updatable via `Alloy.Agent.State.prepare/2`, and stripped on compaction summaries (default: `nil`)
  - `:working_directory` - base path for file tools (default: `"."`)
  - `:context` - arbitrary map passed to tools and middleware (default: `%{}`)
  - `:model_metadata_overrides` - overrides for model context windows used to derive `:max_tokens` when not set explicitly (default: `%{}`)
  - `:model_catalog` - module implementing `Alloy.ModelCatalog`, consulted for model context windows after `:model_metadata_overrides` (default: `Alloy.ModelMetadata`)
  - `:code_execution` - `true` enables Anthropic's server-side code execution tool when running on Anthropic (ignored on Gemini, which uses provider-config `code_execution: true` for its native `codeExecution` tool) (default: `false`)
  - `:on_event` - 1-arity function called with each `Alloy.Events` envelope (tool events, plus text and thinking deltas when streaming) (default: `nil`)
  - `:until_tool` - tool name (string) that must be called successfully before the loop completes. If the model signals `:end_turn` without a call to this tool that succeeded (a failed, blocked or unknown call does not count), the loop continues with a prompt to call it. Useful for structured output enforcement. (default: `nil`)

  ## Budget limits

  Price the accumulated usage yourself in `:before_completion` middleware,
  which runs before every provider request, and halt when the run reaches
  its limit:

      defmodule MyApp.BudgetGuard do
        @behaviour Alloy.Middleware

        # USD per million tokens for the model you run.
        @input_per_m 3.0
        @output_per_m 15.0

        @impl true
        def call(:before_completion, state) do
          limit = Map.fetch!(state.config.context, :max_budget_cents)
          usage = Alloy.Usage.estimate_cost(state.usage, @input_per_m, @output_per_m)

          if usage.estimated_cost_cents >= limit do
            {:halt, "budget of \#{limit} cents reached"}
          else
            state
          end
        end

        def call(_hook, state), do: state
      end

      Alloy.run(prompt,
        provider: provider,
        middleware: [MyApp.BudgetGuard],
        context: %{max_budget_cents: 50}
      )

  A halted run returns `{:error, result}` with `status: :halted` and
  `error: "Halted by middleware: budget of 50 cents reached"`.
  `Alloy.Usage.estimate_cost/3` prices input and output tokens only; add
  your provider's cache read and write prices if you use prompt caching.
  """

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.{Message, Result}

  @type result :: Result.t()

  @doc """
  Run the agent loop with a message and options.

  The first argument can be a string (converted to a user message)
  or ignored if `:messages` option provides conversation history.

  Accepts `:on_event` like `stream/3`. Without streaming, the callback
  receives the tool events (`:tool_start`, `:tool_end`) but no text deltas.

  Built-in HTTP/SSE providers (when `:timeout_ms` is finite), Codex, and tool
  execution require the `:alloy` application (and its `Alloy.TaskSupervisor`)
  to be started.

  Returns `{:ok, result}` on completion or `{:error, result}` on failure.
  """
  @spec run(String.t() | nil, keyword()) :: {:ok, result()} | {:error, result()}
  def run(message \\ nil, opts) do
    do_run(message, opts, maybe_put([], :on_event, validate_on_event(opts[:on_event])))
  end

  @doc """
  Run the agent loop and stream text deltas as they arrive.

  It returns the same result shape as `run/2`.

  The first argument can be a string (converted to a user message)
  or `nil` if the `:messages` option provides conversation history.

  ## Options

  Accepts the same options as `run/2`, plus:

  - `:on_event` - function called with normalized event envelopes during the run
  """
  @spec stream(String.t() | nil, (String.t() -> any), keyword()) ::
          {:ok, result()} | {:error, result()}
  def stream(message, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    on_event = validate_on_event(Keyword.get(opts, :on_event))

    turn_opts =
      [streaming: true, on_chunk: on_chunk]
      |> maybe_put(:on_event, on_event)

    do_run(message, opts, turn_opts)
  end

  defp do_run(message, opts, turn_opts) do
    {run_opts, config_opts} = Keyword.split(opts, [:messages, :on_event])
    config = Config.from_opts(config_opts)
    messages = build_messages(message, run_opts)

    State.init(config, messages)
    |> Turn.run_loop(turn_opts)
    |> Result.from_state()
    |> Result.wrap()
  end

  defp build_messages(nil, opts) do
    Keyword.get(opts, :messages, [])
  end

  defp build_messages(text, opts) when is_binary(text) do
    existing = Keyword.get(opts, :messages, [])
    existing ++ [Message.user(text)]
  end

  defp validate_on_event(nil), do: nil
  defp validate_on_event(on_event) when is_function(on_event, 1), do: on_event

  defp validate_on_event(bad) do
    raise ArgumentError, "on_event must be a 1-arity function, got: #{inspect(bad)}"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
