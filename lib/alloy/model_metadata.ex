defmodule Alloy.ModelMetadata do
  @moduledoc """
  Built-in model metadata catalog used for context budgeting and capability
  discovery.

  This is the default implementation of the `Alloy.ModelCatalog` behaviour.
  It covers the native-provider families (Claude, GPT-5 and GPT-6, Gemini
  2.5 and 3.x, and Grok) at the input limit each vendor documents, along with
  optional `max_output_tokens/1`, `capabilities/1`, and indicative `pricing/1`
  metadata. Anything else, including models served through
  `Alloy.Provider.OpenAICompat` such as Kimi, Qwen, GLM, Mistral or Gemma,
  and retired model ids, gets `default_context_window/0` (200,000 tokens) and
  `nil` for optional metadata.

  For other models or live billing tables, implement `Alloy.ModelCatalog` (a
  static map, your own service, or an adapter over
  [`llm_db`](https://hex.pm/packages/llm_db) — see
  `docs/recipes/llm-db-catalog.md`) and pass the module via the
  `:model_catalog` option. Per-run context-window tweaks that don't warrant a
  catalog module belong in `:model_metadata_overrides`; overrides always win
  over any catalog.
  """

  @behaviour Alloy.ModelCatalog

  @type override_entry ::
          pos_integer()
          | %{
              required(:limit) => pos_integer(),
              optional(:suffix_patterns) => [String.t() | Regex.t()]
            }

  @type overrides ::
          %{optional(String.t()) => override_entry()} | [{String.t(), override_entry()}]

  @default_limit 200_000

  @full_capabilities %{
    reasoning?: true,
    vision?: true,
    documents?: true,
    tools?: true,
    structured_output?: true,
    prompt_caching?: true
  }

  @grok_non_reasoning_capabilities %{
    reasoning?: false,
    vision?: true,
    documents?: true,
    tools?: true,
    structured_output?: true,
    prompt_caching?: true
  }

  # Ordered family rows; the first match wins. A limit is the most input
  # tokens the vendor's API accepts. Overstating it is the dangerous mistake:
  # compaction would fire only after the API had started rejecting requests.
  # Retired ids are left out, so they get the smaller default.
  @families [
    # https://platform.claude.com/docs/en/build-with-claude/context-windows
    # and .../about-claude/model-deprecations, checked 2026-10-09. Ids from
    # 4.6 on are dateless; older ones carry a -YYYYMMDD snapshot.
    {~r/^claude-(opus-4-[678]|opus-5(-5)?|sonnet-4-6|sonnet-5(-5)?|haiku-5-5|fable-5(-1)?|mythos-5(-1)?|mythos-preview)$/,
     %{
       context_window: 1_000_000,
       max_output_tokens: 128_000,
       capabilities: @full_capabilities
     }},
    {~r/^claude-(opus|sonnet|haiku)-4-5(-\d{8})?$/,
     %{
       context_window: 200_000,
       max_output_tokens: 64_000,
       capabilities: @full_capabilities
     }},
    # OpenAI's context window includes output, so these use the "Maximum
    # input tokens" on each model page, such as
    # https://developers.openai.com/api/docs/models/gpt-6-astra.md and
    # .../gpt-5.md, checked 2026-10-09. Pages that omit it share the window and
    # output limit of a sibling that states it; gpt-5-pro and o3 have no such
    # sibling, so they get the default.
    {~r/^gpt-(6-(astra|sol|luna)|6\.1-sol|5\.6-(sol|terra|luna)|5\.[45](-pro)?)(-\d{4}-\d{2}-\d{2})?$/,
     %{
       context_window: 922_000,
       max_output_tokens: 128_000,
       capabilities: @full_capabilities
     }},
    {~r/^gpt-5\.2-pro(-\d{4}-\d{2}-\d{2})?$/,
     %{
       context_window: 272_000,
       max_output_tokens: 128_000,
       capabilities: Map.put(@full_capabilities, :structured_output?, false)
     }},
    {~r/^gpt-5(-mini|-nano|\.1|\.2(-pro)?|\.3-codex|\.4-(mini|nano)|\.6-cyber)?(-\d{4}-\d{2}-\d{2})?$/,
     %{
       context_window: 272_000,
       max_output_tokens: 128_000,
       capabilities: @full_capabilities
     }},
    # Input token limit on each https://ai.google.dev/gemini-api/docs/models
    # page, checked 2026-10-09. 2.5 is limited to existing users but served.
    {~r/^(?:models\/)?gemini-(2\.5-(pro|flash|flash-lite)|3-flash-preview|3\.1-pro-preview(-customtools)?|3\.[15]-flash-lite|3\.[5-8]-flash|flash-latest)$/,
     %{
       context_window: 1_048_576,
       max_output_tokens: 65_536,
       capabilities: @full_capabilities
     }},
    # https://docs.x.ai/developers/pricing and the per-model pages, checked
    # 2026-10-09. The slugs retired in
    # https://docs.x.ai/developers/migration/may-15-retirement now redirect
    # to other models, so they are left out.
    {~r/^grok-4\.20-[a-z0-9-]*non-reasoning(-[a-z0-9-]+)?$/,
     %{
       context_window: 1_000_000,
       max_output_tokens: 131_072,
       capabilities: @grok_non_reasoning_capabilities
     }},
    {~r/^grok-4\.(3(-latest)?|20(-[a-z0-9-]+)?)$/,
     %{
       context_window: 1_000_000,
       max_output_tokens: 131_072,
       capabilities: @full_capabilities
     }},
    {~r/^grok-(4\.[567](-latest)?|build-latest)$/,
     %{
       context_window: 500_000,
       max_output_tokens: 131_072,
       capabilities: @full_capabilities
     }},
    {~r/^grok-build-0\.1$/,
     %{
       context_window: 256_000,
       max_output_tokens: 131_072,
       capabilities: @full_capabilities
     }}
  ]

  # Indicative base-tier reference pricing (USD per 1M tokens) for selected
  # public models. Models without bundled reference rates return nil; use a
  # live Alloy.ModelCatalog (such as llm_db) for authoritative billing data.
  @pricing_entries [
    {~r/^claude-opus-4-5(-\d{8})?$|^claude-opus-4-6$/,
     %{
       input_per_million: 5.0,
       output_per_million: 25.0,
       cache_read_per_million: 0.5,
       cache_write_per_million: 6.25
     }},
    {~r/^claude-sonnet-4-5(-\d{8})?$|^claude-sonnet-4-6$/,
     %{
       input_per_million: 3.0,
       output_per_million: 15.0,
       cache_read_per_million: 0.3,
       cache_write_per_million: 3.75
     }},
    {~r/^claude-haiku-4-5(-\d{8})?$/,
     %{
       input_per_million: 1.0,
       output_per_million: 5.0,
       cache_read_per_million: 0.1,
       cache_write_per_million: 1.25
     }},
    {~r/^gpt-5\.4(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 2.5,
       output_per_million: 15.0,
       cache_read_per_million: 0.25
     }},
    {~r/^gpt-5\.4-mini(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 0.75,
       output_per_million: 4.5,
       cache_read_per_million: 0.075
     }},
    {~r/^gpt-5\.4-nano(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 0.2,
       output_per_million: 1.25,
       cache_read_per_million: 0.02
     }},
    {~r/^gpt-5\.2(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 1.75,
       output_per_million: 14.0,
       cache_read_per_million: 0.175
     }},
    {~r/^gpt-5(\.1)?(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 1.25,
       output_per_million: 10.0,
       cache_read_per_million: 0.125
     }},
    {~r/^gpt-5-mini(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 0.25,
       output_per_million: 2.0,
       cache_read_per_million: 0.025
     }},
    {~r/^gpt-5-nano(-\d{4}-\d{2}-\d{2})?$/,
     %{
       input_per_million: 0.05,
       output_per_million: 0.4,
       cache_read_per_million: 0.005
     }},
    {~r/^(?:models\/)?gemini-2\.5-pro$/,
     %{
       input_per_million: 1.25,
       output_per_million: 10.0,
       cache_read_per_million: 0.125
     }},
    {~r/^(?:models\/)?gemini-2\.5-flash$/,
     %{
       input_per_million: 0.3,
       output_per_million: 2.5,
       cache_read_per_million: 0.03
     }},
    {~r/^(?:models\/)?gemini-2\.5-flash-lite$/,
     %{
       input_per_million: 0.1,
       output_per_million: 0.4,
       cache_read_per_million: 0.01
     }}
  ]

  # A limit-only override on a model the catalog knows also covers that
  # model's snapshots, which every vendor stamps after the name: -20251001,
  # -2025-08-07 or -0309-reasoning.
  @snapshot_suffix ~r/^-\d{4}/

  @doc """
  Returns the known context window limit for a model name
  (`Alloy.ModelCatalog` callback).

  Returns `nil` when the model is not in the built-in catalog.
  """
  @impl Alloy.ModelCatalog
  @spec context_window(String.t()) :: pos_integer() | nil
  def context_window(model_name) when is_binary(model_name) do
    case match_family(model_name) do
      %{context_window: limit} -> limit
      nil -> nil
    end
  end

  @doc """
  Returns the known context window limit for a model name, consulting
  `overrides` ahead of the built-in catalog.

  `overrides` may provide exact-model or family overrides as either:

  - `%{"model-name" => 1_000_000}`
  - `%{"model-name" => %{limit: 1_000_000, suffix_patterns: ["", ~r/^-\d+$/]}}`

  An override without `:suffix_patterns` on a model the catalog knows also
  covers that model's dated snapshots (a suffix starting with a four-digit
  stamp, such as `-2026-03-05` or `-20251001`); on an unknown model it is
  exact-match only.

  Returns `nil` when the model is not in the current catalog or overrides.
  """
  @spec context_window(String.t(), overrides()) :: pos_integer() | nil
  def context_window(model_name, overrides) when is_binary(model_name) do
    override_window(model_name, overrides) || context_window(model_name)
  end

  @doc """
  Returns the context window for `model_name` from `overrides` alone,
  ignoring the built-in catalog.

  Used to apply `:model_metadata_overrides` ahead of any
  `Alloy.ModelCatalog` implementation. Returns `nil` when no override
  matches.
  """
  @spec override_window(String.t(), overrides()) :: pos_integer() | nil
  def override_window(model_name, overrides)
      when is_binary(model_name) and (is_map(overrides) or is_list(overrides)) do
    Enum.find_value(overrides, &override_limit(&1, model_name))
  end

  def override_window(model_name, _overrides) when is_binary(model_name), do: nil

  @doc """
  Returns the default fallback context window for unknown models.
  """
  @impl Alloy.ModelCatalog
  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_limit

  @doc """
  Returns the known maximum output tokens for a built-in model family
  (`Alloy.ModelCatalog` optional callback), or `nil` if unknown.
  """
  @impl Alloy.ModelCatalog
  @spec max_output_tokens(String.t()) :: pos_integer() | nil
  def max_output_tokens(model_name) when is_binary(model_name) do
    case match_family(model_name) do
      %{max_output_tokens: limit} -> limit
      nil -> nil
    end
  end

  @doc """
  Returns capability flags for a built-in model family
  (`Alloy.ModelCatalog` optional callback), or `nil` if unknown.
  """
  @impl Alloy.ModelCatalog
  @spec capabilities(String.t()) :: Alloy.ModelCatalog.capabilities() | nil
  def capabilities(model_name) when is_binary(model_name) do
    case match_family(model_name) do
      %{capabilities: caps} -> caps
      nil -> nil
    end
  end

  @doc """
  Returns indicative base-tier reference pricing (USD per million tokens) for
  selected built-in public models (`Alloy.ModelCatalog` optional callback), or
  `nil` when pricing is unbundled or the model is unknown.

  Vendor pricing changes frequently and may vary by context tier (for example
  above 200k input tokens) or region. For authoritative cost accounting,
  implement `Alloy.ModelCatalog` backed by `llm_db` or your billing config
  (see `docs/recipes/llm-db-catalog.md`).
  """
  @impl Alloy.ModelCatalog
  @spec pricing(String.t()) :: Alloy.ModelCatalog.pricing() | nil
  def pricing(model_name) when is_binary(model_name) do
    Enum.find_value(@pricing_entries, fn {pattern, rates} ->
      if Regex.match?(pattern, model_name), do: rates
    end)
  end

  defp match_family(model_name) do
    Enum.find_value(@families, fn {pattern, entry} ->
      if Regex.match?(pattern, model_name), do: entry
    end)
  end

  defp override_limit({name, limit}, model_name) when is_integer(limit) do
    override_limit({name, %{limit: limit}}, model_name)
  end

  defp override_limit({name, override}, model_name) when is_binary(name) and is_list(override) do
    override_limit({name, Map.new(override)}, model_name)
  end

  defp override_limit({name, %{limit: limit} = override}, model_name)
       when is_binary(name) and is_integer(limit) and limit > 0 do
    if override_matches?(name, suffix_patterns(name, override), model_name), do: limit
  end

  defp override_limit(_entry, _model_name), do: nil

  defp suffix_patterns(_name, %{suffix_patterns: patterns}) when is_list(patterns), do: patterns

  defp suffix_patterns(name, _override) do
    if context_window(name), do: ["", @snapshot_suffix], else: [""]
  end

  defp override_matches?(name, suffixes, model_name) do
    size = byte_size(name)

    case model_name do
      <<^name::binary-size(^size), suffix::binary>> ->
        Enum.any?(suffixes, &suffix_matches?(&1, suffix))

      _ ->
        false
    end
  end

  defp suffix_matches?(pattern, suffix) when is_binary(pattern), do: pattern == suffix
  defp suffix_matches?(%Regex{} = pattern, suffix), do: Regex.match?(pattern, suffix)
end
