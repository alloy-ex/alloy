# Using `llm_db` as an `Alloy.ModelCatalog`

Alloy's built-in `Alloy.ModelMetadata` catalog tracks the major native-provider
families with zero external dependencies, but any static table eventually lags
the model release treadmill and vendor pricing changes.

[`llm_db`](https://hex.pm/packages/llm_db) ships a regularly updated database
sourced from `models.dev` with context windows, output limits, capability flags,
and per-million-token pricing across hundreds of models. You can plug it into
Alloy with a small `Alloy.ModelCatalog` adapter — no changes to Alloy's core
dependencies required.

## 1. Add `:llm_db` to your application

```elixir
# mix.exs
defp deps do
  [
    {:alloy, "~> 0.16"},
    {:llm_db, "~> 2026.1"}
  ]
end
```

## 2. Implement `Alloy.ModelCatalog`

`Alloy.ModelCatalog` requires only `c:Alloy.ModelCatalog.context_window/1`.
Implementing the optional `c:Alloy.ModelCatalog.max_output_tokens/1`,
`c:Alloy.ModelCatalog.capabilities/1`, and `c:Alloy.ModelCatalog.pricing/1`
callbacks lets your host query full model metadata uniformly through
`Alloy.ModelCatalog.info/2`.

Two important details when adapting `LLMDB.Model`:

1. **Provider scoping:** Bare model IDs like `"claude-sonnet-4-6"` often appear
   under multiple providers in `llm_db` with different context windows and
   prices. Bind each Alloy provider run to a provider-scoped catalog module (for
   example `MyApp.LlmDbCatalog.Anthropic`), and reject ambiguous bare lookups on
   unscoped catalogs rather than silently picking another provider's limits.
2. **Struct/map safety:** `LLMDB.Model` structs may contain nested structs or
   maps (which do not implement `Access`), and `modalities` sits at the top
   level alongside `capabilities`. Using `Map.get/2`-based helpers keeps the
   adapter safe across structs, maps, and boolean flags alike.

```elixir
defmodule MyApp.LlmDbCatalog do
  @moduledoc """
  Shared `Alloy.ModelCatalog` adapter backed by `LLMDB`.

  Use directly with provider-qualified specs (`"anthropic:claude-sonnet-4-6"`),
  or define thin provider-scoped modules for bare model IDs passed to Alloy
  providers:

      defmodule MyApp.LlmDbCatalog.Anthropic do
        use MyApp.LlmDbCatalog, provider: :anthropic
      end
  """

  @behaviour Alloy.ModelCatalog

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Alloy.ModelCatalog
      @llm_db_provider Keyword.fetch!(opts, :provider)

      @impl true
      def context_window(model),
        do: MyApp.LlmDbCatalog.context_window_for(model, @llm_db_provider)

      @impl true
      def default_context_window, do: MyApp.LlmDbCatalog.default_context_window()

      @impl true
      def max_output_tokens(model),
        do: MyApp.LlmDbCatalog.max_output_tokens_for(model, @llm_db_provider)

      @impl true
      def capabilities(model),
        do: MyApp.LlmDbCatalog.capabilities_for(model, @llm_db_provider)

      @impl true
      def pricing(model),
        do: MyApp.LlmDbCatalog.pricing_for(model, @llm_db_provider)
    end
  end

  @impl true
  def context_window(model) when is_binary(model), do: context_window_for(model, nil)

  @impl true
  def default_context_window, do: 128_000

  @impl true
  def max_output_tokens(model) when is_binary(model), do: max_output_tokens_for(model, nil)

  @impl true
  def capabilities(model) when is_binary(model), do: capabilities_for(model, nil)

  @impl true
  def pricing(model) when is_binary(model), do: pricing_for(model, nil)

  @doc false
  def context_window_for(model, provider) when is_binary(model) do
    # Prefer the model's documented maximum input limit when LLMDB provides
    # `limits.input` separately from the combined `limits.context` window
    # (for example OpenAI's 400k total / 272k input split), falling back to
    # `limits.context` for entries that only publish a single context limit.
    entry = lookup(model, provider)

    positive_int(nested_get(entry, [:limits, :input])) ||
      positive_int(nested_get(entry, [:limits, :context]))
  end

  @doc false
  def max_output_tokens_for(model, provider) when is_binary(model) do
    positive_int(nested_get(lookup(model, provider), [:limits, :output]))
  end

  @doc false
  def capabilities_for(model, provider) when is_binary(model) do
    case lookup(model, provider) do
      entry when is_map(entry) ->
        caps = Map.get(entry, :capabilities)
        input_modalities = List.wrap(nested_get(entry, [:modalities, :input]))

        if is_map(caps) or input_modalities != [] do
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
        end

      _ ->
        nil
    end
  end

  @doc false
  def pricing_for(model, provider) when is_binary(model) do
    with entry when is_map(entry) <- lookup(model, provider),
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

  # When scoped to a provider, always query `LLMDB.model(provider, model)`
  # directly so colon-containing wire IDs (for example Ollama `"qwen3:32b"` or
  # OpenRouter `"deepseek/deepseek-r1:free"`) are never misparsed as cross-provider
  # specs.
  defp lookup(model, nil) do
    case LLMDB.model(model) do
      {:ok, entry} ->
        entry

      _ ->
        lookup_unambiguous_bare_model(model)
    end
  end

  defp lookup(model, provider) do
    case LLMDB.model(provider, model) do
      {:ok, entry} -> entry
      _ -> nil
    end
  end

  defp lookup_unambiguous_bare_model(model_id) do
    matches =
      LLMDB.providers()
      |> Enum.flat_map(fn provider ->
        provider_id = if is_map(provider), do: Map.get(provider, :id), else: provider

        case LLMDB.model(provider_id, model_id) do
          {:ok, entry} -> [entry]
          _ -> []
        end
      end)

    case matches do
      [single_entry] -> single_entry
      _none_or_ambiguous -> nil
    end
  end

  defp nested_get(nil, _keys), do: nil
  defp nested_get(value, []), do: value

  defp nested_get(map, [key | rest]) when is_map(map) do
    map |> Map.get(key) |> nested_get(rest)
  end

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
  defp maybe_put(map, _key, _other), do: map

  defp positive_int(limit) when is_integer(limit) and limit > 0, do: limit
  defp positive_int(_other), do: nil
end

defmodule MyApp.LlmDbCatalog.Anthropic do
  use MyApp.LlmDbCatalog, provider: :anthropic
end
```

## 3. Wire it into runs and cost estimation

Pass a provider-scoped catalog module to `Alloy.run/2` or `Alloy.stream/3` so
compaction context budgeting resolves bare model IDs unambiguously against the
provider you are actually calling:

```elixir
{:ok, result} =
  Alloy.run("Summarize the release notes",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
    model_catalog: MyApp.LlmDbCatalog.Anthropic
  )
```

Query the full normalized snapshot (context window, max output tokens,
capabilities, and pricing) via `Alloy.ModelCatalog.info/2` using either the
provider-scoped catalog with a bare model ID or the unscoped catalog with a
provider-qualified spec:

```elixir
info = Alloy.ModelCatalog.info(MyApp.LlmDbCatalog.Anthropic, "claude-sonnet-4-6")
# Equivalent with a provider-qualified spec:
# info = Alloy.ModelCatalog.info(MyApp.LlmDbCatalog, "anthropic:claude-sonnet-4-6")
# => %{
#   model: "claude-sonnet-4-6",
#   context_window: 1_000_000,
#   max_output_tokens: 128_000,
#   capabilities: %{reasoning?: true, vision?: true, documents?: true, ...},
#   pricing: %{input_per_million: 3.0, output_per_million: 15.0, ...}
# }
```

Combine `info.pricing` with `result.usage` (`%Alloy.Usage{}`) to compute
application-level run cost without coupling billing logic into Alloy core.
