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

Note that `LLMDB.Model` structs may contain nested structs or maps (which do
not implement the `Access` behaviour), and `modalities` lives at the top level
of the model entry alongside `capabilities`. Using `Map.get/2`-based helpers
keeps the adapter safe across structs, maps, and boolean flags alike.

```elixir
defmodule MyApp.LlmDbCatalog do
  @behaviour Alloy.ModelCatalog

  @impl true
  def context_window(model) when is_binary(model) do
    # Prefer the model's documented maximum input limit when LLMDB provides
    # `limits.input` separately from the combined `limits.context` window
    # (for example OpenAI's 400k total / 272k input split), falling back to
    # `limits.context` for entries that only publish a single context limit.
    entry = lookup(model)

    positive_int(nested_get(entry, [:limits, :input])) ||
      positive_int(nested_get(entry, [:limits, :context]))
  end

  @impl true
  def default_context_window, do: 128_000

  @impl true
  def max_output_tokens(model) when is_binary(model) do
    positive_int(nested_get(lookup(model), [:limits, :output]))
  end

  @impl true
  def capabilities(model) when is_binary(model) do
    case lookup(model) do
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

  @impl true
  def pricing(model) when is_binary(model) do
    with entry when is_map(entry) <- lookup(model),
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

  # Resolves provider-qualified specs ("anthropic:claude-sonnet-4-6") directly.
  # For bare model IDs ("claude-sonnet-4-6"), returns a match only when it is
  # unambiguous across LLMDB providers (or when scoped to a single provider via
  # `@provider`). Ambiguous bare IDs return `nil` so Alloy falls back to
  # `default_context_window/0` rather than risking another provider's larger
  # context window or billing rates.
  #
  # If your app knows which provider a run targets, define a provider-scoped
  # catalog module (or set `@provider :anthropic`) and call
  # `LLMDB.model(@provider, model)` directly.
  @provider nil

  defp lookup(model) do
    case LLMDB.model(model) do
      {:ok, entry} ->
        entry

      _ ->
        lookup_bare_model(model, @provider)
    end
  end

  defp lookup_bare_model(model_id, provider_id) when not is_nil(provider_id) do
    case LLMDB.model(provider_id, model_id) do
      {:ok, entry} -> entry
      _ -> nil
    end
  end

  defp lookup_bare_model(model_id, nil) do
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
```

## 3. Wire it into runs and cost estimation

Pass `:model_catalog` to `Alloy.run/2` or `Alloy.stream/3` so compaction
context budgeting uses your catalog:

```elixir
{:ok, result} =
  Alloy.run("Summarize the release notes",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
    model_catalog: MyApp.LlmDbCatalog
  )
```

Query the full normalized snapshot (context window, max output tokens,
capabilities, and pricing) via `Alloy.ModelCatalog.info/2`:

```elixir
info = Alloy.ModelCatalog.info(MyApp.LlmDbCatalog, "claude-sonnet-4-6")
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
