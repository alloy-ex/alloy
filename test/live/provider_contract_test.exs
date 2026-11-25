defmodule Alloy.Live.ProviderContractTest do
  @moduledoc """
  Opt-in live provider contract test suite.

  Excluded from `mix test` and `mix ci` by default. Run a specific provider
  slice (or all configured providers) with real API credentials:

      ANTHROPIC_API_KEY=... mix test --only live_anthropic
      OPENAI_API_KEY=... mix test --only live_openai
      GEMINI_API_KEY=... mix test --only live_gemini
      XAI_API_KEY=... mix test --only live_xai
      OPENAI_COMPAT_API_KEY=... OPENAI_COMPAT_BASE_URL=... OPENAI_COMPAT_MODEL=... mix test --only live_openai_compat
      ALLOY_LIVE_CODEX=1 mix test --only live_codex

  Optional model overrides:
  - `ALLOY_LIVE_ANTHROPIC_MODEL` (default: `"claude-haiku-4-5"`)
  - `ALLOY_LIVE_OPENAI_MODEL` (default: `"gpt-5-mini"`)
  - `ALLOY_LIVE_GEMINI_MODEL` (default: `"gemini-3.8-flash"`)
  - `ALLOY_LIVE_XAI_MODEL` (default: `"grok-4.3"`)
  - `ALLOY_LIVE_CODEX_MODEL` (default: `"gpt-5.4"`)
  """

  use ExUnit.Case, async: true

  alias Alloy.Provider.{Anthropic, Codex, Gemini, OpenAI, OpenAICompat, XAI}
  alias Alloy.{Result, Tool}

  @moduletag :live
  @moduletag timeout: 120_000

  @sum_schema %{
    type: "object",
    properties: %{sum: %{type: "integer"}},
    required: ["sum"],
    additionalProperties: false
  }

  @tag :live_anthropic
  test "Anthropic contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    api_key = require_env!("ANTHROPIC_API_KEY", :live_anthropic)
    model = env_or_default("ALLOY_LIVE_ANTHROPIC_MODEL", "claude-haiku-4-5")
    assert_provider_contract({Anthropic, api_key: api_key, model: model})
  end

  @tag :live_openai
  test "OpenAI contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    api_key = require_env!("OPENAI_API_KEY", :live_openai)
    model = env_or_default("ALLOY_LIVE_OPENAI_MODEL", "gpt-5-mini")
    assert_provider_contract({OpenAI, api_key: api_key, model: model})
  end

  @tag :live_gemini
  test "Gemini contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    api_key = require_env!("GEMINI_API_KEY", :live_gemini)
    model = env_or_default("ALLOY_LIVE_GEMINI_MODEL", "gemini-3.8-flash")
    assert_provider_contract({Gemini, api_key: api_key, model: model})
  end

  @tag :live_xai
  test "xAI contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    api_key = require_env!("XAI_API_KEY", :live_xai)
    model = env_or_default("ALLOY_LIVE_XAI_MODEL", "grok-4.3")
    assert_provider_contract({XAI, api_key: api_key, model: model})
  end

  @tag :live_openai_compat
  test "OpenAICompat contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    api_key = require_env!("OPENAI_COMPAT_API_KEY", :live_openai_compat)
    base_url = require_env!("OPENAI_COMPAT_BASE_URL", :live_openai_compat)
    model = require_env!("OPENAI_COMPAT_MODEL", :live_openai_compat)

    assert_provider_contract({OpenAICompat, api_key: api_key, api_url: base_url, model: model})
  end

  @tag :live_codex
  test "Codex CLI contract: complete, stream, tool use, output_schema, and tools + output_schema" do
    unless System.get_env("ALLOY_LIVE_CODEX") in ["1", "true"] do
      flunk("Set ALLOY_LIVE_CODEX=1 to run :live_codex tests (or filter with --only live_<name>)")
    end

    model = env_or_default("ALLOY_LIVE_CODEX_MODEL", "gpt-5.4")
    assert_provider_contract({Codex, model: model})
  end

  defp assert_provider_contract(provider) do
    add_tool = build_add_tool()

    # 1. Non-streaming completion + usage
    assert {:ok, %Result{status: :completed, text: text, usage: usage}} =
             Alloy.run("Reply with exactly the word: PONG",
               provider: provider,
               max_turns: 2,
               timeout_ms: 45_000
             )

    assert is_binary(text) and String.contains?(String.upcase(text), "PONG")
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0

    # 2. Streaming chunks match final result.text
    test_pid = self()

    assert {:ok, %Result{status: :completed, text: streamed_text, usage: stream_usage}} =
             Alloy.stream(
               "Reply with exactly: STREAM_OK",
               fn chunk -> send(test_pid, {:chunk, chunk}) end,
               provider: provider,
               max_turns: 2,
               timeout_ms: 45_000
             )

    chunks = drain_chunks([])
    assert Enum.join(chunks) == streamed_text
    assert stream_usage.output_tokens > 0

    # 3. Single-turn tool calling round-trip
    assert {:ok, %Result{status: :completed, text: tool_text, tool_calls: calls}} =
             Alloy.run("Use the add_numbers tool to compute 19 + 23, then state the result.",
               provider: provider,
               tools: [add_tool],
               max_turns: 4,
               timeout_ms: 45_000
             )

    assert Enum.any?(calls, &(&1.name == "add_numbers" and is_nil(&1.error)))
    assert tool_text =~ "42"

    # 4. Portable :output_schema structured output (without tools)
    assert {:ok, %Result{status: :completed, output: %{"sum" => 7}}} =
             Alloy.run("Compute 3 + 4 and return the result as JSON.",
               provider: provider,
               output_schema: @sum_schema,
               max_turns: 2,
               timeout_ms: 45_000
             )

    # 5. Tools combined with :output_schema
    assert {:ok, %Result{status: :completed, output: %{"sum" => 42}, tool_calls: schema_calls}} =
             Alloy.run(
               "Use add_numbers to compute 19 + 23, then return the sum as JSON.",
               provider: provider,
               tools: [add_tool],
               output_schema: @sum_schema,
               max_turns: 4,
               timeout_ms: 45_000
             )

    assert Enum.any?(schema_calls, &(&1.name == "add_numbers" and is_nil(&1.error)))
  end

  defp build_add_tool do
    Tool.inline(
      name: "add_numbers",
      description: "Adds two integers a and b and returns their sum.",
      input_schema: %{
        type: "object",
        properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
        required: ["a", "b"],
        additionalProperties: false
      },
      execute: fn %{"a" => a, "b" => b}, _ctx -> {:ok, Integer.to_string(a + b)} end
    )
  end

  defp require_env!(env_var, tag) do
    case System.get_env(env_var) do
      val when is_binary(val) and val != "" ->
        val

      _missing ->
        flunk(
          "Set #{env_var} to run :#{tag} contract tests (or filter with --only live_<provider>)"
        )
    end
  end

  defp env_or_default(env_var, default) do
    case System.get_env(env_var) do
      val when is_binary(val) and val != "" -> val
      _missing -> default
    end
  end

  defp drain_chunks(acc) do
    receive do
      {:chunk, chunk} -> drain_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
