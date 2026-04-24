defmodule Alloy.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias Alloy.ModelMetadata

  describe "context_window/1" do
    test "returns exact model matches" do
      assert ModelMetadata.context_window("claude-opus-4-6") == 200_000
      assert ModelMetadata.context_window("gpt-5.4") == 1_050_000
      assert ModelMetadata.context_window("grok-4-fast-reasoning") == 2_000_000
      # grok-4 is 2M (not 256K) per xAI docs
      assert ModelMetadata.context_window("grok-4") == 2_000_000
      # grok-4.1-fast models (dot notation)
      assert ModelMetadata.context_window("grok-4.1-fast") == 2_000_000
      assert ModelMetadata.context_window("grok-4.1-fast-reasoning") == 2_000_000
      # grok-4.20 family — current xAI frontier API models
      assert ModelMetadata.context_window("grok-4.20-0309-reasoning") == 2_000_000
      assert ModelMetadata.context_window("grok-4.20-0309-non-reasoning") == 2_000_000
      assert ModelMetadata.context_window("grok-4.20-multi-agent-0309") == 2_000_000
      # Kimi (Moonshot AI)
      assert ModelMetadata.context_window("kimi-k2.5") == 256_000
      assert ModelMetadata.context_window("kimi-k2.6") == 256_000
      # Gemma 4 variants
      assert ModelMetadata.context_window("gemma-4-26b-a4b-it") == 256_000
      assert ModelMetadata.context_window("gemma-4-31b-it") == 256_000
      # GLM 4.6
      assert ModelMetadata.context_window("glm-4.6") == 200_000
      # Qwen 3 family — qwen3-coder-plus has a 1M window
      assert ModelMetadata.context_window("qwen3-max") == 256_000
      assert ModelMetadata.context_window("qwen3-max-preview") == 256_000
      assert ModelMetadata.context_window("qwen3-coder-plus") == 1_000_000
      assert ModelMetadata.context_window("qwen3.5-397b-a17b") == 1_000_000
      # Mistral Large 3
      assert ModelMetadata.context_window("mistral-large-2512") == 256_000
      assert ModelMetadata.context_window("mistral-large-latest") == 256_000
    end

    test "returns dated snapshot matches" do
      assert ModelMetadata.context_window("claude-haiku-4-5-20251015") == 200_000
      assert ModelMetadata.context_window("gpt-5.2-2025-12-11") == 400_000
      assert ModelMetadata.context_window("gemini-3-pro-preview-11-2025") == 1_048_576
    end

    test "returns nil for unknown models" do
      assert ModelMetadata.context_window("unknown-model") == nil
    end
  end

  describe "context_window/2" do
    test "allows exact-match overrides for custom models" do
      overrides = %{"acme-reasoner" => 512_000}

      assert ModelMetadata.context_window("acme-reasoner", overrides) == 512_000
    end

    test "reuses existing suffix patterns for known model overrides" do
      overrides = %{"gpt-5.4" => 900_000}

      assert ModelMetadata.context_window("gpt-5.4-2026-03-05", overrides) == 900_000
    end

    test "accepts custom suffix patterns for unknown families" do
      overrides = %{
        "acme-reasoner" => %{limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]}
      }

      assert ModelMetadata.context_window("acme-reasoner-2026.03", overrides) == 640_000
    end

    test "accepts nested keyword-list override entries" do
      overrides = [
        {"acme-reasoner", [limit: 640_000, suffix_patterns: ["", ~r/^-\d{4}\.\d{2}$/]]}
      ]

      assert ModelMetadata.context_window("acme-reasoner-2026.03", overrides) == 640_000
    end
  end

  describe "catalog/0" do
    test "exposes the current model catalog" do
      assert Enum.any?(ModelMetadata.catalog(), &(&1.name == "claude-sonnet-4-6"))
      assert Enum.any?(ModelMetadata.catalog(), &(&1.name == "grok-code-fast-1"))
    end
  end
end
