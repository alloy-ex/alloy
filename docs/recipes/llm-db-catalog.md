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

```elixir
defmodule MyApp.LlmDbCatalog do
  @behaviour Alloy.ModelCatalog

  @impl true
  def context_window(model) when is_binary(model) do
    with %{limits: %{context: limit}} when is_integer(limit) and limit > 0 <- lookup(model) do
      limit
    else
      _ -> nil
    end
  end

  @impl true
  def default_context_window, do: 128_000

  @impl true
  def max_output_tokens(model) when is_binary(model) do
    with %{limits: %{output: limit}} when is_integer(limit) and limit > 0 <- lookup(model) do
      limit
    else
      _ -> nil
    end
  end

  @impl true
  def capabilities(model) when is_binary(model) do
    with %{capabilities: caps} when is_map(caps) <- lookup(model) do
      %{
        reasoning?: truthy?(get_in(caps, [:reasoning, :enabled]) || caps[:reasoning]),
        vision?: :image in List.wrap(get_in(caps, [:modalities, :input])),
        documents?: :pdf in List.wrap(get_in(caps, [:modalities, :input])),
        tools?: truthy?(get_in(caps, [:tools, :enabled]) || caps[:tools]),
        structured_output?: truthy?(get_in(caps, [:json, :schema]) || caps[:structured_output]),
        prompt_caching?: truthy?(caps[:prompt_caching])
      }
    else
      _ -> nil
    end
  end

  @impl true
  def pricing(model) when is_binary(model) do
    with %{cost: %{input: input, output: output} = cost}
         when is_number(input) and is_number(output) <- lookup(model) do
      %{input_per_million: input, output_per_million: output}
      |> maybe_put(:cache_read_per_million, cost[:cache_read])
      |> maybe_put(:cache_write_per_million, cost[:cache_write])
    else
      _ -> nil
    end
  end

  # Supports either provider-qualified specs ("anthropic:claude-sonnet-4-6") or
  # bare model IDs ("claude-sonnet-4-6") as passed in Alloy provider configs.
  defp lookup(model) do
    case LLMDb.model(model) do
      {:ok, entry} ->
        entry

      _ ->
        find_by_model_id(model)
    end
  end

  defp find_by_model_id(model_id) do
    Enum.find_value(LLMDb.providers(), fn provider ->
      case LLMDb.model(provider.id, model_id) do
        {:ok, entry} -> entry
        _ -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val) when is_number(val), do: Map.put(map, key, val)
  defp maybe_put(map, _key, _other), do: map

  defp truthy?(val), do: val == true
end
```

> Note: Check the exact struct field names for your installed `:llm_db` version
> (for example `LLMDb.Model` fields under `:limits`, `:capabilities`, and
> `:cost`).

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
