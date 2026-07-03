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
