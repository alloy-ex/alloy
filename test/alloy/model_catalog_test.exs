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

  defmodule FullCatalog do
    @behaviour Alloy.ModelCatalog

    @impl true
    def context_window("custom-pro"), do: 512_000
    def context_window(_), do: nil

    @impl true
    def max_output_tokens("custom-pro"), do: 32_768
    def max_output_tokens(_), do: nil

    @impl true
    def capabilities("custom-pro") do
      %{reasoning?: true, vision?: true, documents?: false, tools?: true}
    end

    def capabilities(_), do: nil

    @impl true
    def pricing("custom-pro") do
      %{input_per_million: 2.0, output_per_million: 8.0, cache_read_per_million: 0.2}
    end

    def pricing(_), do: nil
  end

  defmodule FakeLlmDbModel do
    defstruct [:limits, :capabilities, :modalities, :cost]
  end

  defmodule FakeLlmDbLimits do
    defstruct [:context, :input, :output]
  end

  defmodule FakeLlmDbCost do
    defstruct [:input, :output, :cache_read, :cache_write]
  end

  defmodule StructBackedLlmDbCatalog do
    @behaviour Alloy.ModelCatalog

    @entries %{
      "nested-multimodal" => %FakeLlmDbModel{
        limits: %FakeLlmDbLimits{context: 400_000, input: 272_000, output: 128_000},
        modalities: %{input: [:text, :image, :pdf], output: [:text]},
        capabilities: %{
          reasoning: %{enabled: true},
          tools: %{enabled: true},
          json: %{schema: true},
          caching: %{type: "explicit"}
        },
        cost: %FakeLlmDbCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}
      },
      "implicit-caching" => %FakeLlmDbModel{
        limits: %FakeLlmDbLimits{context: 200_000, input: nil, output: 64_000},
        modalities: %{input: [:text, :image], output: [:text]},
        capabilities: %{
          reasoning: true,
          tools: true,
          json: %{schema: true},
          caching: %{type: "implicit"}
        },
        cost: %FakeLlmDbCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: nil}
      },
      "flat-booleans" => %FakeLlmDbModel{
        limits: %FakeLlmDbLimits{context: 200_000, input: nil, output: 64_000},
        modalities: %{input: [:text, :image], output: [:text]},
        capabilities: %{
          reasoning: false,
          tools: true,
          structured_output: true
        },
        cost: %FakeLlmDbCost{input: 1.0, output: 5.0, cache_read: nil, cache_write: nil}
      }
    }

    @impl true
    def context_window(model) do
      entry = Map.get(@entries, model)

      positive_int(nested_get(entry, [:limits, :input])) ||
        positive_int(nested_get(entry, [:limits, :context]))
    end

    @impl true
    def max_output_tokens(model) do
      positive_int(nested_get(Map.get(@entries, model), [:limits, :output]))
    end

    @impl true
    def capabilities(model) do
      case Map.get(@entries, model) do
        entry when is_map(entry) ->
          caps = Map.get(entry, :capabilities)
          input_modalities = List.wrap(nested_get(entry, [:modalities, :input]))

          %{
            reasoning?: capability_enabled?(caps, :reasoning, :enabled),
            vision?: :image in input_modalities,
            documents?: :pdf in input_modalities,
            tools?: capability_enabled?(caps, :tools, :enabled),
            structured_output?:
              capability_enabled?(caps, :json, :schema) or
                capability_enabled?(caps, :structured_output, :enabled),
            prompt_caching?: prompt_caching_enabled?(caps)
          }

        _ ->
          nil
      end
    end

    @impl true
    def pricing(model) do
      with entry when is_map(entry) <- Map.get(@entries, model),
           cost when is_map(cost) <- Map.get(entry, :cost),
           input when is_number(input) <- Map.get(cost, :input),
           output when is_number(output) <- Map.get(cost, :output) do
        %{input_per_million: input, output_per_million: output}
        |> maybe_put(:cache_read_per_million, Map.get(cost, :cache_read))
        |> maybe_put(:cache_write_per_million, Map.get(cost, :cache_write))
      else
        _ -> nil
      end
    end

    defp nested_get(nil, _keys), do: nil
    defp nested_get(value, []), do: value

    defp nested_get(map, [key | rest]) when is_map(map),
      do: map |> Map.get(key) |> nested_get(rest)

    defp nested_get(_other, _keys), do: nil

    defp capability_enabled?(caps, key, nested_key) when is_map(caps) do
      case Map.get(caps, key) do
        true -> true
        nested when is_map(nested) -> Map.get(nested, nested_key) == true
        _ -> false
      end
    end

    defp capability_enabled?(_caps, _key, _nested_key), do: false

    defp prompt_caching_enabled?(caps) when is_map(caps) do
      case Map.get(caps, :caching) do
        caching when is_map(caching) ->
          Map.get(caching, :type) in ["implicit", "explicit", :implicit, :explicit] or
            Map.get(caching, :enabled) == true

        _ ->
          false
      end
    end

    defp prompt_caching_enabled?(_caps), do: false

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, val) when is_number(val), do: Map.put(map, key, val)

    defp positive_int(limit) when is_integer(limit) and limit > 0, do: limit
    defp positive_int(_other), do: nil
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
      assert Alloy.ModelMetadata.context_window("gpt-5") == 272_000
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

  describe "Alloy.ModelCatalog.info/1,2" do
    test "defaults to Alloy.ModelMetadata" do
      info = Alloy.ModelCatalog.info("claude-sonnet-4-6")

      assert info.model == "claude-sonnet-4-6"
      assert info.context_window == 1_000_000
      assert info.max_output_tokens == 128_000
      assert info.capabilities.reasoning? == true
      assert info.capabilities.documents? == true
      assert info.pricing.input_per_million == 3.0
    end

    test "returns nil for unimplemented optional callbacks on minimal catalogs" do
      info = Alloy.ModelCatalog.info(StaticCatalog, "my-finetune-v3")

      assert info == %{
               model: "my-finetune-v3",
               context_window: 32_768,
               max_output_tokens: nil,
               capabilities: nil,
               pricing: nil
             }
    end

    test "returns all optional metadata when exported by a custom catalog" do
      info = Alloy.ModelCatalog.info(FullCatalog, "custom-pro")

      assert info == %{
               model: "custom-pro",
               context_window: 512_000,
               max_output_tokens: 32_768,
               capabilities: %{reasoning?: true, vision?: true, documents?: false, tools?: true},
               pricing: %{
                 input_per_million: 2.0,
                 output_per_million: 8.0,
                 cache_read_per_million: 0.2
               }
             }

      unknown = Alloy.ModelCatalog.info(FullCatalog, "missing")
      assert unknown.context_window == nil
      assert unknown.max_output_tokens == nil
      assert unknown.capabilities == nil
      assert unknown.pricing == nil
    end

    test "rejects invalid catalog modules" do
      assert_raise ArgumentError, ~r/:model_catalog must be a module/, fn ->
        Alloy.ModelCatalog.info(Enum, "gpt-5")
      end
    end

    test "struct-backed LLMDB-style adapter handles sibling modalities and boolean capability flags" do
      nested = Alloy.ModelCatalog.info(StructBackedLlmDbCatalog, "nested-multimodal")

      assert nested == %{
               model: "nested-multimodal",
               context_window: 272_000,
               max_output_tokens: 128_000,
               capabilities: %{
                 reasoning?: true,
                 vision?: true,
                 documents?: true,
                 tools?: true,
                 structured_output?: true,
                 prompt_caching?: true
               },
               pricing: %{
                 input_per_million: 3.0,
                 output_per_million: 15.0,
                 cache_read_per_million: 0.3,
                 cache_write_per_million: 3.75
               }
             }

      implicit = Alloy.ModelCatalog.info(StructBackedLlmDbCatalog, "implicit-caching")
      assert implicit.context_window == 200_000
      assert implicit.capabilities.prompt_caching? == true

      flat = Alloy.ModelCatalog.info(StructBackedLlmDbCatalog, "flat-booleans")

      assert flat == %{
               model: "flat-booleans",
               context_window: 200_000,
               max_output_tokens: 64_000,
               capabilities: %{
                 reasoning?: false,
                 vision?: true,
                 documents?: false,
                 tools?: true,
                 structured_output?: true,
                 prompt_caching?: false
               },
               pricing: %{
                 input_per_million: 1.0,
                 output_per_million: 5.0
               }
             }
    end
  end
end
