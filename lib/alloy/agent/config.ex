defmodule Alloy.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Alloy.run/2`. Immutable for the
  duration of the run.
  """

  alias Alloy.Context.Compactor
  alias Alloy.ModelMetadata

  @options [
    :provider,
    :tools,
    :system_prompt,
    :max_turns,
    :max_tokens,
    :max_retries,
    :retry_backoff_ms,
    :timeout_ms,
    :tool_timeout,
    :middleware,
    :compaction,
    :working_directory,
    :context,
    :on_compaction,
    :fallback_providers,
    :code_execution,
    :model_metadata_overrides,
    :model_catalog,
    :until_tool,
    :memory
  ]

  @runtime_options [:pubsub, :subscribe, :max_pending, :on_shutdown]

  # Built-in provider options removed in 0.13, checked for the primary and
  # every fallback provider at startup: a fallback is first used during an
  # outage, which is the wrong moment to find a config error. Keyed by the
  # provider that had the option, since a custom provider may use the name.
  @removed_provider_options %{
    Alloy.Provider.Anthropic =>
      {:extended_thinking,
       ":extended_thinking was removed in Alloy 0.13; configure thinking through " <>
         ~s(:extra_body, for example %{"thinking" => %{"type" => "adaptive"}})},
    Alloy.Provider.Codex =>
      {:auth_path,
       ":auth_path was removed in Alloy 0.13; set :codex_home to the directory " <>
         "holding auth.json"}
  }

  # The summary prompts are optional because a bare `%Config{}` omits them;
  # `from_opts/1` always fills them and the Compactor falls back to its
  # defaults when they are absent.
  @compaction_keys [
    :reserve_tokens,
    :keep_recent_tokens,
    :fallback,
    :clear_tool_results,
    :keep_recent_tool_results,
    :summary_system_prompt,
    :summary_prompt
  ]
  @compaction_keys_by_name Map.new(@compaction_keys, &{Atom.to_string(&1), &1})

  @type compaction :: %{
          optional(:summary_system_prompt) => String.t(),
          optional(:summary_prompt) => String.t(),
          reserve_tokens: pos_integer(),
          keep_recent_tokens: pos_integer(),
          fallback: :truncate,
          clear_tool_results: boolean(),
          keep_recent_tool_results: non_neg_integer()
        }

  @type t :: %__MODULE__{
          provider: module(),
          provider_config: map(),
          tools: [module() | Alloy.Tool.Inline.t()],
          system_prompt: String.t() | nil,
          max_turns: pos_integer(),
          max_tokens: pos_integer(),
          max_tokens_explicit?: boolean(),
          max_retries: non_neg_integer(),
          retry_backoff_ms: pos_integer(),
          timeout_ms: pos_integer(),
          tool_timeout: pos_integer(),
          middleware: [module()],
          compaction: compaction(),
          compaction_explicit: %{
            reserve_tokens: boolean(),
            keep_recent_tokens: boolean()
          },
          working_directory: String.t(),
          context: map(),
          on_compaction: (list(), Alloy.Agent.State.t() -> any()) | nil,
          fallback_providers: [{module(), map()}],
          code_execution: boolean(),
          model_metadata_overrides: map(),
          model_catalog: module(),
          until_tool: String.t() | nil
        }

  @enforce_keys [:provider, :provider_config]
  defstruct [
    :provider,
    :provider_config,
    tools: [],
    system_prompt: nil,
    max_turns: 25,
    max_tokens: 200_000,
    max_tokens_explicit?: false,
    max_retries: 3,
    retry_backoff_ms: 1_000,
    timeout_ms: 120_000,
    tool_timeout: 120_000,
    middleware: [],
    compaction: %{
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
      fallback: :truncate,
      clear_tool_results: true,
      # Summary prompts are filled in at runtime by `resolve_compaction/2`;
      # calling Compactor here would make Config compile-depend on it.
      keep_recent_tool_results: 3
    },
    compaction_explicit: %{reserve_tokens: false, keep_recent_tokens: false},
    working_directory: ".",
    context: %{},
    on_compaction: nil,
    fallback_providers: [],
    code_execution: false,
    model_metadata_overrides: %{},
    model_catalog: ModelMetadata,
    until_tool: nil
  ]

  @doc """
  Builds a config from `Alloy.run/2` options.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    validate_option_names!(opts)
    {provider_mod, provider_config} = parse_provider(opts[:provider])

    provider_config =
      provider_config |> normalize_provider_config() |> reject_removed!(provider_mod)

    model_metadata_overrides = normalize_model_metadata_overrides(opts[:model_metadata_overrides])

    model_catalog =
      Alloy.ModelCatalog.validate!(Keyword.get(opts, :model_catalog, ModelMetadata))

    max_tokens_explicit? = Keyword.has_key?(opts, :max_tokens)

    max_tokens =
      resolve_max_tokens(
        opts,
        provider_config,
        model_metadata_overrides,
        model_catalog,
        max_tokens_explicit?
      )

    {compaction, compaction_explicit} = resolve_compaction(opts[:compaction], max_tokens)
    tools = Keyword.get(opts, :tools, []) ++ memory_tools(Keyword.get(opts, :memory))

    %__MODULE__{
      provider: provider_mod,
      provider_config: provider_config,
      tools: tools,
      system_prompt: Keyword.get(opts, :system_prompt),
      max_turns: Keyword.get(opts, :max_turns, 25),
      max_tokens: max_tokens,
      max_tokens_explicit?: max_tokens_explicit?,
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      tool_timeout: Keyword.get(opts, :tool_timeout, 120_000),
      middleware: resolve_middleware(Keyword.get(opts, :middleware, []), opts[:compaction]),
      compaction: compaction,
      compaction_explicit: compaction_explicit,
      working_directory: Keyword.get(opts, :working_directory, "."),
      context: Keyword.get(opts, :context, %{}),
      on_compaction: Keyword.get(opts, :on_compaction, nil),
      fallback_providers:
        opts
        |> Keyword.get(:fallback_providers, [])
        |> Enum.map(&parse_fallback_provider/1),
      code_execution: Keyword.get(opts, :code_execution, false),
      model_metadata_overrides: model_metadata_overrides,
      model_catalog: model_catalog,
      until_tool: Keyword.get(opts, :until_tool)
    }
  end

  # A misspelt or removed option used to be ignored silently, which hides
  # mistakes such as a budget or tool list that never applies.
  defp validate_option_names!(opts) do
    case opts |> Keyword.drop(@options) |> Keyword.keys() |> Enum.uniq() do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_options_message(unknown)
    end
  end

  defp unknown_options_message([:max_budget_cents]) do
    ":max_budget_cents was removed in Alloy 0.13. Enforce a budget with " <>
      ":before_completion middleware instead (see \"Budget limits\" in the Alloy docs)."
  end

  defp unknown_options_message(unknown) do
    case Enum.filter(unknown, &(&1 in @runtime_options)) do
      [] ->
        "unknown options #{inspect(unknown)}. Valid options: #{inspect(@options)} " <>
          "(Alloy.run/2 and Alloy.stream/3 also take :messages and :on_event). " <>
          "See docs/upgrading-to-0.13.md for options removed in 0.13."

      runtime ->
        "#{inspect(runtime)} belong to the agent server, which moved to the " <>
          "alloy_agent package in Alloy 0.13; pass them to AlloyAgent.start_link/1. " <>
          "All unknown options: #{inspect(unknown)}"
    end
  end

  # Compaction is middleware, on by default and first, so it runs before the
  # caller's :before_completion middleware as it did when the loop called it
  # directly. Listing it yourself sets its position instead.
  defp resolve_middleware(middleware, false) do
    if Compactor in middleware do
      raise ArgumentError,
            "compaction: false conflicts with Alloy.Context.Compactor in :middleware; " <>
              "remove one of them"
    end

    middleware
  end

  defp resolve_middleware(middleware, _compaction) do
    if Compactor in middleware, do: middleware, else: [Compactor | middleware]
  end

  defp reject_removed!(provider_config, provider) do
    case Map.get(@removed_provider_options, provider) do
      {key, message} when is_map_key(provider_config, key) -> raise ArgumentError, message
      _none -> provider_config
    end
  end

  # `memory: binding` is shorthand for `tools: [Alloy.Memory.tool(binding)]`.
  defp memory_tools(nil), do: []
  defp memory_tools(binding), do: [Alloy.Memory.tool(binding)]

  @doc """
  Returns an updated config with a new provider while preserving unrelated options.

  If `max_tokens` was not set explicitly, the budget is re-derived from the new
  provider model, current `model_metadata_overrides`, and `model_catalog`.
  """
  @spec with_provider(t(), module() | {module(), keyword() | map()}) :: t()
  def with_provider(%__MODULE__{} = config, provider) do
    {provider_mod, provider_config} = parse_provider(provider)

    provider_config =
      provider_config |> normalize_provider_config() |> reject_removed!(provider_mod)

    max_tokens =
      if config.max_tokens_explicit? do
        config.max_tokens
      else
        default_max_tokens(
          model_name(provider_config),
          config.model_metadata_overrides,
          config.model_catalog
        )
      end

    compaction =
      %{
        reserve_tokens:
          resolve_compaction_field(
            config.compaction.reserve_tokens,
            config.compaction_explicit.reserve_tokens,
            default_reserve_tokens(max_tokens)
          ),
        keep_recent_tokens:
          resolve_compaction_field(
            config.compaction.keep_recent_tokens,
            config.compaction_explicit.keep_recent_tokens,
            default_keep_recent_tokens(max_tokens)
          ),
        fallback: config.compaction.fallback,
        clear_tool_results: config.compaction.clear_tool_results,
        keep_recent_tool_results: config.compaction.keep_recent_tool_results,
        summary_system_prompt: config.compaction.summary_system_prompt,
        summary_prompt: config.compaction.summary_prompt
      }

    %{
      config
      | provider: provider_mod,
        provider_config: provider_config,
        max_tokens: max_tokens,
        compaction: compaction
    }
  end

  defp parse_provider({module, config})
       when is_atom(module) and (is_list(config) or is_map(config)) do
    {module, config}
  end

  defp parse_provider(module) when is_atom(module) do
    {module, []}
  end

  defp parse_fallback_provider({module, provider_config}) when is_atom(module) do
    {module, provider_config |> normalize_provider_config() |> reject_removed!(module)}
  end

  defp parse_fallback_provider(module) when is_atom(module) do
    {module, %{}}
  end

  defp normalize_provider_config(config) when is_map(config), do: config
  defp normalize_provider_config(config) when is_list(config), do: Map.new(config)
  defp normalize_provider_config(nil), do: %{}

  defp normalize_model_metadata_overrides(overrides) when is_map(overrides), do: overrides

  defp normalize_model_metadata_overrides(overrides) when is_list(overrides),
    do: Map.new(overrides)

  defp normalize_model_metadata_overrides(nil), do: %{}
  defp normalize_model_metadata_overrides(_), do: %{}

  defp resolve_max_tokens(
         opts,
         provider_config,
         model_metadata_overrides,
         model_catalog,
         max_tokens_explicit?
       ) do
    if max_tokens_explicit? do
      Keyword.fetch!(opts, :max_tokens)
    else
      provider_config
      |> model_name()
      |> default_max_tokens(model_metadata_overrides, model_catalog)
    end
  end

  defp model_name(provider_config) when is_map(provider_config) do
    Map.get(provider_config, :model) || Map.get(provider_config, "model")
  end

  # Resolution order: :model_metadata_overrides beat any catalog; the
  # catalog (built-in or user-supplied via :model_catalog) is consulted
  # next; unknown models fall back to the catalog's default window.
  defp default_max_tokens(model_name, model_metadata_overrides, model_catalog)
       when is_binary(model_name) do
    ModelMetadata.override_window(model_name, model_metadata_overrides) ||
      model_catalog.context_window(model_name) ||
      Alloy.ModelCatalog.default_window(model_catalog)
  end

  defp default_max_tokens(_model_name, _model_metadata_overrides, model_catalog) do
    Alloy.ModelCatalog.default_window(model_catalog)
  end

  defp resolve_compaction(raw_compaction, max_tokens) do
    compaction = normalize_compaction(raw_compaction)

    explicit = %{
      reserve_tokens: Map.has_key?(compaction, :reserve_tokens),
      keep_recent_tokens: Map.has_key?(compaction, :keep_recent_tokens)
    }

    fallback =
      compaction
      |> Map.get(:fallback, :truncate)
      |> validate_compaction_fallback()

    resolved = %{
      reserve_tokens:
        if(explicit.reserve_tokens,
          do: validate_compaction_tokens!(compaction.reserve_tokens, :reserve_tokens),
          else: default_reserve_tokens(max_tokens)
        ),
      keep_recent_tokens:
        if(explicit.keep_recent_tokens,
          do: validate_compaction_tokens!(compaction.keep_recent_tokens, :keep_recent_tokens),
          else: default_keep_recent_tokens(max_tokens)
        ),
      fallback: fallback,
      clear_tool_results:
        compaction
        |> Map.get(:clear_tool_results, true)
        |> validate_clear_tool_results!(),
      keep_recent_tool_results:
        compaction
        |> Map.get(:keep_recent_tool_results, 3)
        |> validate_keep_recent_tool_results!(),
      summary_system_prompt:
        compaction
        |> Map.get(
          :summary_system_prompt,
          Compactor.default_summary_system_prompt()
        )
        |> validate_compaction_prompt!(:summary_system_prompt),
      summary_prompt:
        compaction
        |> Map.get(:summary_prompt, Compactor.default_summary_prompt())
        |> validate_compaction_prompt!(:summary_prompt)
    }

    {resolved, explicit}
  end

  defp normalize_compaction(nil), do: %{}
  defp normalize_compaction(false), do: %{}

  defp normalize_compaction(compaction) when is_map(compaction),
    do: normalize_compaction_map(compaction)

  defp normalize_compaction(compaction) when is_list(compaction),
    do: normalize_compaction_map(Map.new(compaction))

  defp normalize_compaction(other) do
    raise ArgumentError,
          "compaction must be a keyword list or map, got: #{inspect(other)}"
  end

  defp normalize_compaction_map(map) do
    Map.new(map, fn {key, value} -> {compaction_key!(key), value} end)
  end

  # String keys are matched against the whitelist instead of converted, so
  # untrusted config cannot create atoms.
  defp compaction_key!(key) when key in @compaction_keys, do: key

  defp compaction_key!(key) do
    case Map.fetch(@compaction_keys_by_name, key) do
      {:ok, known} -> known
      :error -> raise ArgumentError, "unsupported compaction option: #{inspect(key)}"
    end
  end

  defp resolve_compaction_field(current_value, true, _default_value), do: current_value
  defp resolve_compaction_field(_current_value, false, default_value), do: default_value

  defp validate_compaction_tokens!(value, _field) when is_integer(value) and value > 0, do: value

  defp validate_compaction_tokens!(value, field) do
    raise ArgumentError,
          "#{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_keep_recent_tool_results!(value) when is_integer(value) and value >= 0, do: value

  defp validate_keep_recent_tool_results!(value) do
    raise ArgumentError,
          "keep_recent_tool_results must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_clear_tool_results!(value) when is_boolean(value), do: value

  defp validate_clear_tool_results!(value) do
    raise ArgumentError,
          "clear_tool_results must be a boolean, got: #{inspect(value)}"
  end

  defp validate_compaction_prompt!(value, _field) when is_binary(value), do: value

  defp validate_compaction_prompt!(value, field) do
    raise ArgumentError,
          "#{field} must be a string, got: #{inspect(value)}"
  end

  defp validate_compaction_fallback(:truncate), do: :truncate

  defp validate_compaction_fallback(other) do
    raise ArgumentError,
          "compaction fallback must be :truncate, got: #{inspect(other)}"
  end

  defp default_reserve_tokens(max_tokens) do
    min(16_384, max(1, div(max_tokens, 10)))
  end

  defp default_keep_recent_tokens(max_tokens) do
    min(20_000, max(1, div(max_tokens, 8)))
  end
end
