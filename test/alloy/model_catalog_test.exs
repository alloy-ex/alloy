defmodule Alloy.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Config

  defmodule StaticCatalog do
    @behaviour Alloy.ModelCatalog

    @impl true
    def context_window("my-finetune-v3"), do: 32_768
    def context_window("huge-context"), do: 5_000_000
    def context_window(_), do: nil
  end

  defmodule CatalogWithDefault do
    @behaviour Alloy.ModelCatalog

    @impl true
    def context_window(_), do: nil

    @impl true
    def default_context_window, do: 8_192
  end

  defp opts(extra) do
    Keyword.merge(
      [provider: {Alloy.Provider.Test, model: "my-finetune-v3"}],
      extra
    )
  end

  describe ":model_catalog option" do
    test "defaults to Alloy.ModelMetadata" do
      config = Config.from_opts(opts([]))
      assert config.model_catalog == Alloy.ModelMetadata
    end

    test "custom catalog drives max_tokens derivation" do
      config = Config.from_opts(opts(model_catalog: StaticCatalog))
      assert config.max_tokens == 32_768
    end

    test "unknown model falls back to ModelMetadata default window" do
      config =
        Config.from_opts(
          [provider: {Alloy.Provider.Test, model: "unknown-model"}] ++
            [model_catalog: StaticCatalog]
        )

      assert config.max_tokens == Alloy.ModelMetadata.default_context_window()
    end

    test "catalog's own default_context_window/0 is used when exported" do
      config =
        Config.from_opts(
          provider: {Alloy.Provider.Test, model: "unknown-model"},
          model_catalog: CatalogWithDefault
        )

      assert config.max_tokens == 8_192
    end

    test "explicit :max_tokens beats the catalog" do
      config = Config.from_opts(opts(model_catalog: StaticCatalog, max_tokens: 1_000))
      assert config.max_tokens == 1_000
    end

    test ":model_metadata_overrides beat the catalog" do
      config =
        Config.from_opts(
          opts(
            model_catalog: StaticCatalog,
            model_metadata_overrides: %{"my-finetune-v3" => 64_000}
          )
        )

      assert config.max_tokens == 64_000
    end

    test "with_provider/2 re-derives max_tokens through the catalog" do
      config = Config.from_opts(opts(model_catalog: StaticCatalog))
      assert config.max_tokens == 32_768

      updated = Config.with_provider(config, {Alloy.Provider.Test, model: "huge-context"})
      assert updated.max_tokens == 5_000_000
      assert updated.model_catalog == StaticCatalog
    end

    test "rejects a module that does not implement the behaviour" do
      assert_raise ArgumentError, ~r/:model_catalog must be a module/, fn ->
        Config.from_opts(opts(model_catalog: Enum))
      end
    end

    test "rejects non-module values" do
      assert_raise ArgumentError, ~r/:model_catalog must be a module/, fn ->
        Config.from_opts(opts(model_catalog: "llm_db"))
      end
    end
  end

  describe "Alloy.ModelMetadata as the default Alloy.ModelCatalog" do
    test "context_window/1 matches catalog entries" do
      assert Alloy.ModelMetadata.context_window("gpt-5") == 400_000
      assert Alloy.ModelMetadata.context_window("totally-unknown") == nil
    end

    test "override_window/2 consults only the overrides" do
      assert Alloy.ModelMetadata.override_window("gpt-5", %{}) == nil
      assert Alloy.ModelMetadata.override_window("gpt-5", %{"gpt-5" => 123_456}) == 123_456

      # Overrides reuse built-in suffix patterns for known families
      assert Alloy.ModelMetadata.override_window("gpt-5-2026-01-01", %{"gpt-5" => 123_456}) ==
               123_456
    end
  end
end
