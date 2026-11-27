defmodule Alloy.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias Alloy.ModelMetadata

  defp windows(models), do: Map.new(models, &{&1, ModelMetadata.context_window(&1)})

  defp expect(models, limit), do: Map.new(models, &{&1, limit})

  describe "context_window/1 family rows" do
    test "Claude models with a 1M window" do
      models = ~w(
        claude-fable-5-1 claude-fable-5 claude-mythos-5-1 claude-mythos-5 claude-mythos-preview
        claude-opus-5-5 claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6
        claude-sonnet-5-5 claude-sonnet-5 claude-sonnet-4-6 claude-haiku-5-5
      )

      assert windows(models) == expect(models, 1_000_000)
    end

    test "Claude 4.5 models keep a 200k window, with or without their snapshot date" do
      models = ~w(
        claude-opus-4-5 claude-opus-4-5-20251101 claude-sonnet-4-5 claude-sonnet-4-5-20250929
        claude-haiku-4-5 claude-haiku-4-5-20251001
      )

      assert windows(models) == expect(models, 200_000)
    end

    test "OpenAI 1.05M-window models are capped at their 922k maximum input" do
      models = ~w(
        gpt-6-astra gpt-6-sol gpt-6-luna gpt-6.1-sol gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna
        gpt-5.5 gpt-5.5-2026-04-23 gpt-5.5-pro gpt-5.5-pro-2026-04-23
        gpt-5.4 gpt-5.4-2026-03-05 gpt-5.4-pro gpt-5.4-pro-2026-03-05
      )

      assert windows(models) == expect(models, 922_000)
    end

    test "OpenAI 400k-window models are capped at their 272k maximum input" do
      models = ~w(
        gpt-5 gpt-5-2025-08-07 gpt-5-mini gpt-5-mini-2025-08-07 gpt-5-nano gpt-5-nano-2025-08-07
        gpt-5.1 gpt-5.1-2025-11-13 gpt-5.2 gpt-5.2-2025-12-11 gpt-5.2-pro gpt-5.2-pro-2025-12-11
        gpt-5.3-codex gpt-5.4-mini gpt-5.4-mini-2026-03-17 gpt-5.4-nano gpt-5.4-nano-2026-03-17
        gpt-5.6-cyber
      )

      assert windows(models) == expect(models, 272_000)
    end

    test "Gemini 2.5 and 3.x text models" do
      models = ~w(
        gemini-3.8-flash gemini-3.7-flash gemini-3.6-flash gemini-3.5-flash gemini-3.5-flash-lite
        gemini-3.1-flash-lite gemini-3.1-pro-preview gemini-3.1-pro-preview-customtools
        gemini-3-flash-preview gemini-2.5-pro gemini-2.5-flash gemini-2.5-flash-lite
        gemini-flash-latest
      )

      assert windows(models) == expect(models, 1_048_576)
      assert ModelMetadata.context_window("models/gemini-3.8-flash") == 1_048_576
    end

    test "Grok 4.3 and the 4.20 family, including xAI's date-stamped ids and aliases" do
      models = ~w(
        grok-4.3 grok-4.3-latest grok-4.20 grok-4.20-0309-reasoning grok-4.20-0309-non-reasoning
        grok-4.20-multi-agent-0309 grok-4.20-multi-agent grok-4.20-reasoning-latest
      )

      assert windows(models) == expect(models, 1_000_000)
    end

    test "Grok 4.5 to 4.7" do
      models = ~w(grok-4.7 grok-4.6 grok-4.5 grok-4.5-latest grok-build-latest)

      assert windows(models) == expect(models, 500_000)
    end

    test "Grok Build" do
      assert ModelMetadata.context_window("grok-build-0.1") == 256_000
    end
  end

  describe "context_window/1 unknown and retired ids" do
    test "returns nil for unknown models" do
      assert ModelMetadata.context_window("unknown-model") == nil
    end

    test "retired ids do not match, so they fall back to the default window" do
      retired = ~w(
        grok-4 grok-4-0709 grok-4-fast-reasoning grok-4-fast-non-reasoning
        grok-4-1-fast-reasoning grok-4-1-fast-non-reasoning grok-4.1-fast grok-4.1-fast-reasoning
        grok-code-fast-1 grok-3 grok-3-mini
        gemini-3-pro-preview gemini-3-pro-preview-11-2025 gemini-3.1-flash-lite-preview
        gemini-2.5-flash-preview-09-2025 gemini-2.0-flash
        gpt-5-codex gpt-5.1-codex gpt-5.1-codex-max gpt-5.2-codex gpt-5-chat-latest
        gpt-5.1-chat-latest gpt-5.4-cyber
        claude-opus-4-1-20250805 claude-opus-4-20250514 claude-sonnet-4-20250514
        claude-3-7-sonnet-20250219
      )

      assert windows(retired) == expect(retired, nil)
    end

    test "long-tail OpenAI-compatible models are no longer listed" do
      models = ~w(
        kimi-k2.5 kimi-k2.6 qwen3-max qwen3-coder-plus glm-4.6 mistral-large-2512 gemma-4-31b-it
      )

      assert windows(models) == expect(models, nil)
    end

    test "family rows do not match lookalike ids" do
      models = ~w(
        claude-opus-4-9 claude-opus-5-6 claude-fable-5-1-20260901 gpt-5-pro gpt-5.4-mini-pro
        gpt-6-astra-mini gemini-3.8-flash-tts gemini-3.1-flash-image grok-4.8 grok-build-0.2
      )

      assert windows(models) == expect(models, nil)
    end
  end

  describe "context_window/2" do
    test "falls back to the catalog when no override matches" do
      assert ModelMetadata.context_window("gpt-5.5", %{"acme" => 1}) == 922_000
    end

    test "overrides win over the catalog" do
      assert ModelMetadata.context_window("claude-opus-4-8", %{"claude-opus-4-8" => 1}) == 1
    end

    test "allows exact-match overrides for custom models" do
      overrides = %{"acme-reasoner" => 512_000}

      assert ModelMetadata.context_window("acme-reasoner", overrides) == 512_000
      assert ModelMetadata.context_window("acme-reasoner-2026-03-05", overrides) == nil
    end

    test "a limit-only override on a known model also covers its dated snapshots" do
      assert ModelMetadata.context_window("gpt-5.4-2026-03-05", %{"gpt-5.4" => 900_000}) ==
               900_000

      assert ModelMetadata.context_window("claude-haiku-4-5-20251001", %{
               "claude-haiku-4-5" => %{limit: 150_000}
             }) == 150_000

      assert ModelMetadata.context_window("grok-4.20-0309-reasoning", %{"grok-4.20" => 600_000}) ==
               600_000
    end

    test "a limit-only override does not spread to sibling models" do
      overrides = %{"gpt-5" => 100_000, "claude-sonnet-5" => 100_000}

      assert ModelMetadata.context_window("gpt-5-mini", overrides) == 272_000
      assert ModelMetadata.context_window("gpt-5.4", overrides) == 922_000
      assert ModelMetadata.context_window("claude-sonnet-5-5", overrides) == 1_000_000
    end

    test "accepts custom suffix patterns for unknown families" do
      overrides = %{
        "acme-reasoner" => %{limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]}
      }

      assert ModelMetadata.context_window("acme-reasoner", overrides) == 640_000
      assert ModelMetadata.context_window("acme-reasoner-2026.03", overrides) == 640_000
      assert ModelMetadata.context_window("acme-reasoner-mini", overrides) == nil
    end

    test "custom suffix patterns replace the dated-snapshot default for known models" do
      overrides = %{"gpt-5" => %{limit: 100_000, suffix_patterns: ["-mini"]}}

      assert ModelMetadata.context_window("gpt-5-mini", overrides) == 100_000
      assert ModelMetadata.context_window("gpt-5", overrides) == 272_000
      assert ModelMetadata.context_window("gpt-5-2025-08-07", overrides) == 272_000
    end

    test "accepts keyword-list overrides and nested keyword-list entries" do
      overrides = [
        {"acme-reasoner", [limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]]},
        {"acme-small", 32_000}
      ]

      assert ModelMetadata.context_window("acme-reasoner-2026.03", overrides) == 640_000
      assert ModelMetadata.context_window("acme-small", overrides) == 32_000
    end

    test "ignores malformed override entries" do
      overrides = [
        {"acme-zero", 0},
        {"acme-float", 1.5},
        {:acme_atom, 1_000},
        {"acme-no-limit", %{suffix_patterns: [""]}},
        {"gpt-5.5", -1}
      ]

      assert ModelMetadata.context_window("acme-zero", overrides) == nil
      assert ModelMetadata.context_window("acme-float", overrides) == nil
      assert ModelMetadata.context_window("acme-no-limit", overrides) == nil
      assert ModelMetadata.context_window("gpt-5.5", overrides) == 922_000
    end
  end

  describe "override_window/2" do
    test "consults only the overrides" do
      assert ModelMetadata.override_window("gpt-5", %{}) == nil
      assert ModelMetadata.override_window("gpt-5", %{"gpt-5" => 123_456}) == 123_456
      assert ModelMetadata.override_window("gpt-5-2025-08-07", %{"gpt-5" => 123_456}) == 123_456
      assert ModelMetadata.override_window("acme", [{"acme", [limit: 7]}]) == 7
    end

    test "treats overrides that are neither a map nor a list as empty" do
      assert ModelMetadata.override_window("gpt-5", nil) == nil
      assert ModelMetadata.context_window("gpt-5", nil) == 272_000
    end
  end

  test "default_context_window/0 is 200k" do
    assert ModelMetadata.default_context_window() == 200_000
  end

  describe "max_output_tokens/1" do
    test "returns output token limits for built-in families and nil for unknown/retired" do
      assert ModelMetadata.max_output_tokens("claude-opus-4-6") == 128_000
      assert ModelMetadata.max_output_tokens("claude-opus-5-5") == 128_000
      assert ModelMetadata.max_output_tokens("claude-sonnet-4-5-20250929") == 64_000
      assert ModelMetadata.max_output_tokens("gpt-6-astra") == 128_000
      assert ModelMetadata.max_output_tokens("gpt-5.4-2026-03-05") == 128_000
      assert ModelMetadata.max_output_tokens("gpt-5-mini") == 128_000
      assert ModelMetadata.max_output_tokens("gemini-2.5-pro") == 65_536
      assert ModelMetadata.max_output_tokens("models/gemini-3.8-flash") == 65_536
      # xAI Grok models have no separate text output limit beyond context_window
      assert ModelMetadata.max_output_tokens("grok-4.7") == nil
      assert ModelMetadata.max_output_tokens("grok-4.6") == nil
      assert ModelMetadata.max_output_tokens("grok-build-0.1") == nil

      assert ModelMetadata.max_output_tokens("unknown-model") == nil
      assert ModelMetadata.max_output_tokens("claude-3-7-sonnet-20250219") == nil
    end
  end

  describe "capabilities/1" do
    test "returns capability maps for built-in families and distinguishes non-reasoning Grok" do
      for model <- ~w(
            claude-opus-4-6 claude-sonnet-4-5 gpt-6-astra gpt-5.4
            gemini-2.5-pro models/gemini-3.8-flash grok-4.20-0309-reasoning grok-4.7
          ) do
        caps = ModelMetadata.capabilities(model)
        assert caps.reasoning? == true
        assert caps.vision? == true
        assert caps.documents? == true
        assert caps.tools? == true
        assert caps.structured_output? == true
        assert caps.prompt_caching? == true
      end

      non_reasoning = ModelMetadata.capabilities("grok-4.20-0309-non-reasoning")
      assert non_reasoning.reasoning? == false
      assert non_reasoning.tools? == true

      non_reasoning_latest = ModelMetadata.capabilities("grok-4.20-non-reasoning-latest")
      assert non_reasoning_latest.reasoning? == false
      assert non_reasoning_latest.tools? == true

      assert ModelMetadata.capabilities("gpt-5.2").structured_output? == true
      assert ModelMetadata.capabilities("gpt-5.2-pro").structured_output? == false
      assert ModelMetadata.capabilities("gpt-5.2-pro-2025-12-11").structured_output? == false
      assert ModelMetadata.capabilities("gpt-5.4").structured_output? == true
      assert ModelMetadata.capabilities("gpt-5.4-pro").structured_output? == false
      assert ModelMetadata.capabilities("gpt-5.4-pro-2026-03-05").structured_output? == false
      assert ModelMetadata.capabilities("gpt-5.5-pro").structured_output? == true

      assert ModelMetadata.capabilities("grok-build-0.1") == nil

      assert Alloy.ModelCatalog.info("grok-build-0.1") == %{
               model: "grok-build-0.1",
               context_window: 256_000,
               max_output_tokens: nil,
               capabilities: nil,
               pricing: nil
             }

      assert ModelMetadata.capabilities("unknown-model") == nil
      assert ModelMetadata.capabilities("gpt-5-codex") == nil
    end
  end

  describe "pricing/1" do
    test "returns indicative reference pricing for bundled public models and nil otherwise" do
      assert %{input_per_million: 5.0, output_per_million: 25.0, cache_read_per_million: 0.5} =
               ModelMetadata.pricing("claude-opus-4-6")

      assert %{input_per_million: 3.0, output_per_million: 15.0} =
               ModelMetadata.pricing("claude-sonnet-4-5-20250929")

      assert %{input_per_million: 1.0, output_per_million: 5.0} =
               ModelMetadata.pricing("claude-haiku-4-5-20251001")

      assert %{input_per_million: 2.5, output_per_million: 15.0} =
               ModelMetadata.pricing("gpt-5.4-2026-03-05")

      assert %{input_per_million: 0.75, output_per_million: 4.5} =
               ModelMetadata.pricing("gpt-5.4-mini")

      assert %{input_per_million: 0.2, output_per_million: 1.25} =
               ModelMetadata.pricing("gpt-5.4-nano")

      assert %{input_per_million: 1.75, output_per_million: 14.0} =
               ModelMetadata.pricing("gpt-5.2")

      assert %{input_per_million: 1.25, output_per_million: 10.0} =
               ModelMetadata.pricing("gpt-5")

      assert %{input_per_million: 0.25, output_per_million: 2.0} =
               ModelMetadata.pricing("gpt-5-mini")

      assert %{input_per_million: 0.05, output_per_million: 0.4} =
               ModelMetadata.pricing("gpt-5-nano")

      assert %{
               input_per_million: 1.25,
               output_per_million: 10.0,
               cache_read_per_million: 0.125
             } =
               ModelMetadata.pricing("models/gemini-2.5-pro")

      assert %{
               input_per_million: 0.3,
               output_per_million: 2.5,
               cache_read_per_million: 0.03
             } =
               ModelMetadata.pricing("gemini-2.5-flash")

      assert %{
               input_per_million: 0.1,
               output_per_million: 0.4,
               cache_read_per_million: 0.01
             } =
               ModelMetadata.pricing("gemini-2.5-flash-lite")

      assert ModelMetadata.pricing("unknown-model") == nil
      assert ModelMetadata.pricing("claude-3-7-sonnet-20250219") == nil
    end
  end
end
