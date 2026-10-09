defmodule Alloy.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Config
  alias Alloy.Context.Compactor
  alias Alloy.ModelMetadata

  describe "max_tokens" do
    test "defaults to the provider model context window when known" do
      config = Config.from_opts(provider: {Alloy.Provider.OpenAI, [model: "gpt-5.4"]})

      assert config.max_tokens == ModelMetadata.context_window("gpt-5.4")
    end

    test "falls back to the default context window for unknown models" do
      config = Config.from_opts(provider: {Alloy.Provider.OpenAI, [model: "acme-reasoner"]})

      assert config.max_tokens == ModelMetadata.default_context_window()
    end

    test "respects explicit max_tokens overrides" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.OpenAI, [model: "gpt-5.4"]},
          max_tokens: 123_456
        )

      assert config.max_tokens == 123_456
    end

    test "uses model metadata overrides when deriving max_tokens" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.OpenAI, [model: "gpt-5.4-2026-03-05"]},
          model_metadata_overrides: %{"gpt-5.4" => 900_000}
        )

      assert config.max_tokens == 900_000
      assert config.model_metadata_overrides == %{"gpt-5.4" => 900_000}
    end

    test "accepts nested keyword-list override entries" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.OpenAI, [model: "acme-reasoner-2026.03"]},
          model_metadata_overrides: [
            {"acme-reasoner", [limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]]}
          ]
        )

      assert config.max_tokens == 640_000
    end
  end

  describe "option names" do
    test "an unknown option raises instead of being ignored" do
      assert_raise ArgumentError, ~r/unknown options \[:tols\]/, fn ->
        Config.from_opts(provider: {Alloy.Provider.Test, []}, tols: [])
      end
    end

    test "the removed :max_budget_cents points at the budget middleware" do
      assert_raise ArgumentError, ~r/:max_budget_cents was removed.*:before_completion/s, fn ->
        Config.from_opts(provider: {Alloy.Provider.Test, []}, max_budget_cents: 50)
      end
    end

    test "removed provider options raise at startup, for fallbacks too" do
      assert_raise ArgumentError, ~r/:extended_thinking was removed/, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Anthropic, extended_thinking: [budget_tokens: 1]}
        )
      end

      assert_raise ArgumentError, ~r/:auth_path was removed/, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          fallback_providers: [{Alloy.Provider.Codex, model: "m", auth_path: "/tmp/auth.json"}]
        )
      end

      assert_raise ArgumentError, ~r/:extended_thinking was removed/, fn ->
        [provider: {Alloy.Provider.Test, []}]
        |> Config.from_opts()
        |> Config.with_provider({Alloy.Provider.Anthropic, extended_thinking: [budget_tokens: 1]})
      end
    end

    test "a custom provider may use an option name a built-in one removed" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, auth_path: "/etc/sa.json"})
      assert config.provider_config.auth_path == "/etc/sa.json"
    end

    test "agent-server options point at alloy_agent" do
      assert_raise ArgumentError, ~r/\[:pubsub, :max_pending\].*alloy_agent/s, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          pubsub: MyApp.PubSub,
          max_pending: 2
        )
      end
    end
  end

  describe "with_provider/2" do
    setup do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.OpenAI, [model: "gpt-5.4"]},
          tools: [Alloy.Test.EchoTool],
          system_prompt: "Be brief.",
          max_turns: 7
        )

      %{config: config}
    end

    test "swaps the provider and keeps every other option", %{config: config} do
      updated =
        Config.with_provider(config, {Alloy.Provider.Anthropic, model: "claude-sonnet-5-5"})

      assert updated.provider == Alloy.Provider.Anthropic
      assert updated.provider_config == %{model: "claude-sonnet-5-5"}

      assert {updated.tools, updated.system_prompt, updated.max_turns} ==
               {config.tools, "Be brief.", 7}
    end

    test "accepts a bare provider module", %{config: config} do
      updated = Config.with_provider(config, Alloy.Provider.Test)

      assert updated.provider == Alloy.Provider.Test
      assert updated.provider_config == %{}
    end

    test "re-derives max_tokens unless it was set explicitly", %{config: config} do
      derived = Config.with_provider(config, {Alloy.Provider.OpenAI, model: "acme-reasoner"})
      assert derived.max_tokens == ModelMetadata.default_context_window()

      explicit =
        [provider: {Alloy.Provider.OpenAI, [model: "gpt-5.4"]}, max_tokens: 123_456]
        |> Config.from_opts()
        |> Config.with_provider({Alloy.Provider.OpenAI, model: "acme-reasoner"})

      assert explicit.max_tokens == 123_456
    end
  end

  describe "memory option" do
    test "is shorthand for adding the memory tool" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          memory: {Alloy.Test.MemoryStore, self()},
          tools: [Alloy.Test.EchoTool]
        )

      assert [Alloy.Test.EchoTool, %Alloy.Tool.Inline{name: "memory", concurrent?: false} = tool] =
               config.tools

      assert tool.native_types == %{anthropic: "memory_20250818"}
    end
  end

  describe "code_execution option" do
    test "defaults to false when not specified" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []})
      assert config.code_execution == false
    end

    test "accepts code_execution: true" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, code_execution: true)
      assert config.code_execution == true
    end

    test "accepts code_execution: false explicitly" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, code_execution: false)
      assert config.code_execution == false
    end
  end

  describe "compaction middleware" do
    defmodule Logging do
      @behaviour Alloy.Middleware
      @impl true
      def call(_hook, state), do: state
    end

    test "runs first by default" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, middleware: [Logging])
      assert config.middleware == [Compactor, Logging]
    end

    test "compaction: false leaves it out" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          middleware: [Logging],
          compaction: false
        )

      assert config.middleware == [Logging]
    end

    test "compaction: false alongside the compactor in :middleware is a conflict" do
      assert_raise ArgumentError, ~r/compaction: false conflicts/, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          middleware: [Compactor],
          compaction: false
        )
      end
    end

    test "listing it yourself sets its position" do
      config =
        Config.from_opts(provider: {Alloy.Provider.Test, []}, middleware: [Logging, Compactor])

      assert config.middleware == [Logging, Compactor]
    end
  end

  describe "compaction option" do
    test "derives reserve and keep_recent token defaults from max_tokens" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          max_tokens: 80
        )

      assert Map.take(config.compaction, [
               :reserve_tokens,
               :keep_recent_tokens,
               :fallback,
               :clear_tool_results,
               :keep_recent_tool_results
             ]) == %{
               reserve_tokens: 8,
               keep_recent_tokens: 10,
               fallback: :truncate,
               clear_tool_results: true,
               keep_recent_tool_results: 3
             }

      assert config.compaction.summary_system_prompt == Compactor.default_summary_system_prompt()

      assert config.compaction.summary_prompt == Compactor.default_summary_prompt()
    end

    test "accepts string keys for every compaction option" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          compaction: %{
            "reserve_tokens" => 111,
            "keep_recent_tokens" => 222,
            "fallback" => :truncate,
            "clear_tool_results" => false,
            "keep_recent_tool_results" => 1,
            "summary_system_prompt" => "system",
            "summary_prompt" => "prompt"
          }
        )

      assert config.compaction == %{
               reserve_tokens: 111,
               keep_recent_tokens: 222,
               fallback: :truncate,
               clear_tool_results: false,
               keep_recent_tool_results: 1,
               summary_system_prompt: "system",
               summary_prompt: "prompt"
             }

      assert config.compaction_explicit == %{reserve_tokens: true, keep_recent_tokens: true}
    end

    test "rejects unknown compaction options, atom or string" do
      for key <- [:reserve, "reserve", 42] do
        assert_raise ArgumentError, "unsupported compaction option: #{inspect(key)}", fn ->
          Config.from_opts(provider: {Alloy.Provider.Test, []}, compaction: [{key, 1}])
        end
      end
    end

    test "accepts explicit compaction overrides" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          max_tokens: 100,
          compaction: [reserve_tokens: 12, keep_recent_tokens: 34, fallback: :truncate]
        )

      assert Map.take(config.compaction, [
               :reserve_tokens,
               :keep_recent_tokens,
               :fallback,
               :clear_tool_results,
               :keep_recent_tool_results
             ]) == %{
               reserve_tokens: 12,
               keep_recent_tokens: 34,
               fallback: :truncate,
               clear_tool_results: true,
               keep_recent_tool_results: 3
             }
    end

    test "scales defaults safely for very small max_tokens" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          max_tokens: 5
        )

      assert Map.take(config.compaction, [
               :reserve_tokens,
               :keep_recent_tokens,
               :fallback,
               :clear_tool_results,
               :keep_recent_tool_results
             ]) == %{
               reserve_tokens: 1,
               keep_recent_tokens: 1,
               fallback: :truncate,
               clear_tool_results: true,
               keep_recent_tool_results: 3
             }
    end

    test "accepts tool-result clearing compaction options" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          compaction: [clear_tool_results: false, keep_recent_tool_results: 0]
        )

      assert config.compaction.clear_tool_results == false
      assert config.compaction.keep_recent_tool_results == 0
    end

    test "validates tool-result clearing compaction options" do
      assert_raise ArgumentError, ~r/clear_tool_results must be a boolean/, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          compaction: [clear_tool_results: "false"]
        )
      end

      assert_raise ArgumentError,
                   ~r/keep_recent_tool_results must be a non-negative integer/,
                   fn ->
                     Config.from_opts(
                       provider: {Alloy.Provider.Test, []},
                       compaction: [keep_recent_tool_results: -1]
                     )
                   end
    end

    test "accepts and validates custom compaction prompts" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          compaction: [
            summary_system_prompt: "Summarize like my app expects.",
            summary_prompt: "Return a compact handoff."
          ]
        )

      assert config.compaction.summary_system_prompt == "Summarize like my app expects."
      assert config.compaction.summary_prompt == "Return a compact handoff."

      assert_raise ArgumentError, ~r/summary_prompt must be a string/, fn ->
        Config.from_opts(
          provider: {Alloy.Provider.Test, []},
          compaction: [summary_prompt: :bad]
        )
      end
    end
  end
end
