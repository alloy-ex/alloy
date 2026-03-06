defmodule Alloy.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias Alloy.ModelMetadata

  describe "context_window/1" do
    test "returns exact model matches" do
      assert ModelMetadata.context_window("claude-opus-4-6") == 200_000
      assert ModelMetadata.context_window("gpt-5.4") == 1_050_000
      assert ModelMetadata.context_window("grok-4-fast-reasoning") == 2_000_000
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

  describe "catalog/0" do
    test "exposes the current model catalog" do
      assert Enum.any?(ModelMetadata.catalog(), &(&1.name == "claude-sonnet-4-6"))
      assert Enum.any?(ModelMetadata.catalog(), &(&1.name == "grok-code-fast-1"))
    end
  end
end
