defmodule Alloy.ModelMetadata do
  @moduledoc """
  Built-in model metadata catalog used for context budgeting.

  This is the default implementation of the `Alloy.ModelCatalog` behaviour.
  It covers the native-provider families (Claude, GPT-5 and GPT-6, Gemini
  2.5 and 3.x, and Grok) at the input limit each vendor documents. Anything
  else, including models served through `Alloy.Provider.OpenAICompat` such as
  Kimi, Qwen, GLM, Mistral or Gemma, and retired model ids, gets
  `default_context_window/0` (200,000 tokens).

  For other models, implement `Alloy.ModelCatalog` (a static map, your own
  service, or an adapter over [`llm_db`](https://hex.pm/packages/llm_db)) and
  pass the module via the `:model_catalog` option. Per-run tweaks that don't
  warrant a catalog module belong in `:model_metadata_overrides`; overrides
  always win over any catalog.
  """

  @behaviour Alloy.ModelCatalog

  @type model_entry :: {Regex.t(), pos_integer()}

  @type override_entry ::
          pos_integer()
          | %{
              required(:limit) => pos_integer(),
              optional(:suffix_patterns) => [String.t() | Regex.t()]
            }

  @type overrides ::
          %{optional(String.t()) => override_entry()} | [{String.t(), override_entry()}]

  @default_limit 200_000

  # Ordered family rows; the first match wins. A limit is the most input
  # tokens the vendor's API accepts. Overstating it is the dangerous mistake:
  # compaction would fire only after the API had started rejecting requests.
  # Retired ids are left out, so they get the smaller default.
  @families [
    # https://platform.claude.com/docs/en/build-with-claude/context-windows
    # and .../about-claude/model-deprecations, checked 2026-10-09. Ids from
    # 4.6 on are dateless; older ones carry a -YYYYMMDD snapshot.
    {~r/^claude-(opus-4-[678]|opus-5(-5)?|sonnet-4-6|sonnet-5(-5)?|haiku-5-5|fable-5(-1)?|mythos-5(-1)?|mythos-preview)$/,
     1_000_000},
    {~r/^claude-(opus|sonnet|haiku)-4-5(-\d{8})?$/, 200_000},
    # OpenAI's context window includes output, so these use the "Maximum
    # input tokens" on each model page, such as
    # https://developers.openai.com/api/docs/models/gpt-6-astra.md and
    # .../gpt-5.md, checked 2026-10-09. Pages that omit it share the window and
    # output limit of a sibling that states it; gpt-5-pro and o3 have no such
    # sibling, so they get the default.
    {~r/^gpt-(6-(astra|sol|luna)|6\.1-sol|5\.6-(sol|terra|luna)|5\.[45](-pro)?)(-\d{4}-\d{2}-\d{2})?$/,
     922_000},
    {~r/^gpt-5(-mini|-nano|\.1|\.2(-pro)?|\.3-codex|\.4-(mini|nano)|\.6-cyber)?(-\d{4}-\d{2}-\d{2})?$/,
     272_000},
    # Input token limit on each https://ai.google.dev/gemini-api/docs/models
    # page, checked 2026-10-09. 2.5 is limited to existing users but served.
    {~r/^gemini-(2\.5-(pro|flash|flash-lite)|3-flash-preview|3\.1-pro-preview(-customtools)?|3\.[15]-flash-lite|3\.[5-8]-flash|flash-latest)$/,
     1_048_576},
    # https://docs.x.ai/developers/pricing and the per-model pages, checked
    # 2026-10-09. The slugs retired in
    # https://docs.x.ai/developers/migration/may-15-retirement now redirect
    # to other models, so they are left out.
    {~r/^grok-4\.(3(-latest)?|20(-[a-z0-9-]+)?)$/, 1_000_000},
    {~r/^grok-(4\.[567](-latest)?|build-latest)$/, 500_000},
    {~r/^grok-build-0\.1$/, 256_000}
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
    Enum.find_value(@families, fn {pattern, limit} ->
      if Regex.match?(pattern, model_name), do: limit
    end)
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
  Returns the ordered family rows: a pattern over the full model id and the
  limit for ids it matches. The first matching row wins.
  """
  @spec catalog() :: [model_entry()]
  def catalog, do: @families

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
