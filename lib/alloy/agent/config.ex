defmodule Alloy.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Alloy.run/2`. Immutable for the
  duration of the run.
  """

  alias Alloy.ModelMetadata

  @type compaction :: %{
          reserve_tokens: pos_integer(),
          keep_recent_tokens: pos_integer(),
          fallback: :truncate
        }

  @typedoc """
  Memory store binding — `{store_module, opaque_store_term}`. The store
  module implements `Alloy.Memory`. The store term is whatever the
  module needs (keyword list, map, pid, struct) — Alloy passes it
  through verbatim.

  As of 0.12.0, memory is Anthropic-only. `Alloy.run/2` raises if
  `:memory` is set with any other provider.
  """
  @type memory :: {module(), term()} | nil

  @type t :: %__MODULE__{
          provider: module(),
          provider_config: map(),
          tools: [module()],
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
          on_shutdown: (Alloy.Session.t() -> any()) | nil,
          on_compaction: (list(), Alloy.Agent.State.t() -> any()) | nil,
          pubsub: module() | nil,
          subscribe: [String.t()],
          max_pending: non_neg_integer(),
          fallback_providers: [{module(), map()}],
          code_execution: boolean(),
          model_metadata_overrides: map(),
          max_budget_cents: number() | nil,
          until_tool: String.t() | nil,
          memory: memory()
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
    compaction: %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate},
    compaction_explicit: %{reserve_tokens: false, keep_recent_tokens: false},
    working_directory: ".",
    context: %{},
    on_shutdown: nil,
    on_compaction: nil,
    pubsub: nil,
    subscribe: [],
    max_pending: 0,
    fallback_providers: [],
    code_execution: false,
    model_metadata_overrides: %{},
    max_budget_cents: nil,
    until_tool: nil,
    memory: nil
  ]

  @doc """
  Builds a config from `Alloy.run/2` options.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    {provider_mod, provider_config} = parse_provider(opts[:provider])
    provider_config = normalize_provider_config(provider_config)
    model_metadata_overrides = normalize_model_metadata_overrides(opts[:model_metadata_overrides])
    max_tokens_explicit? = Keyword.has_key?(opts, :max_tokens)

    max_tokens =
      resolve_max_tokens(
        opts,
        provider_config,
        model_metadata_overrides,
        max_tokens_explicit?
      )

    {compaction, compaction_explicit} = resolve_compaction(opts[:compaction], max_tokens)

    %__MODULE__{
      provider: provider_mod,
      provider_config: provider_config,
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_turns: Keyword.get(opts, :max_turns, 25),
      max_tokens: max_tokens,
      max_tokens_explicit?: max_tokens_explicit?,
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      tool_timeout: Keyword.get(opts, :tool_timeout, 120_000),
      middleware: Keyword.get(opts, :middleware, []),
      compaction: compaction,
      compaction_explicit: compaction_explicit,
      working_directory: Keyword.get(opts, :working_directory, "."),
      context: Keyword.get(opts, :context, %{}),
      on_shutdown: Keyword.get(opts, :on_shutdown, nil),
      on_compaction: Keyword.get(opts, :on_compaction, nil),
      pubsub: Keyword.get(opts, :pubsub, nil),
      subscribe: Keyword.get(opts, :subscribe, []),
      max_pending: Keyword.get(opts, :max_pending, 0),
      fallback_providers:
        opts
        |> Keyword.get(:fallback_providers, [])
        |> Enum.map(&parse_fallback_provider/1),
      code_execution: Keyword.get(opts, :code_execution, false),
      model_metadata_overrides: model_metadata_overrides,
      max_budget_cents: Keyword.get(opts, :max_budget_cents),
      until_tool: Keyword.get(opts, :until_tool),
      memory: validate_memory(Keyword.get(opts, :memory), provider_mod)
    }
  end

  defp validate_memory(nil, _provider), do: nil

  defp validate_memory({module, _store} = memory, provider)
       when is_atom(module) do
    if provider == Alloy.Provider.Anthropic do
      memory
    else
      raise ArgumentError,
            "Alloy.Memory is Anthropic-only in 0.12.0. Got provider #{inspect(provider)} " <>
              "with memory store module #{inspect(module)}. " <>
              "Use Alloy.Provider.Anthropic or omit :memory."
    end
  end

  defp validate_memory(bad, _provider) do
    raise ArgumentError,
          ":memory must be a {module, store_opts} tuple where module implements " <>
            "Alloy.Memory. Got: #{inspect(bad)}"
  end

  @doc """
  Returns an updated config with a new provider while preserving unrelated options.

  If `max_tokens` was not set explicitly, the budget is re-derived from the new
  provider model and current `model_metadata_overrides`.
  """
  @spec with_provider(t(), module() | {module(), keyword() | map()}) :: t()
  def with_provider(%__MODULE__{} = config, provider) do
    {provider_mod, provider_config} = parse_provider(provider)
    provider_config = normalize_provider_config(provider_config)

    max_tokens =
      if config.max_tokens_explicit? do
        config.max_tokens
      else
        default_max_tokens(model_name(provider_config), config.model_metadata_overrides)
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
        fallback: config.compaction.fallback
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
    {module, normalize_provider_config(provider_config)}
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

  defp resolve_max_tokens(opts, provider_config, model_metadata_overrides, max_tokens_explicit?) do
    if max_tokens_explicit? do
      Keyword.fetch!(opts, :max_tokens)
    else
      provider_config
      |> model_name()
      |> default_max_tokens(model_metadata_overrides)
    end
  end

  defp model_name(provider_config) when is_map(provider_config) do
    Map.get(provider_config, :model) || Map.get(provider_config, "model")
  end

  defp default_max_tokens(model_name, model_metadata_overrides) when is_binary(model_name) do
    ModelMetadata.context_window(model_name, model_metadata_overrides) ||
      ModelMetadata.default_context_window()
  end

  defp default_max_tokens(_model_name, _model_metadata_overrides) do
    ModelMetadata.default_context_window()
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
      fallback: fallback
    }

    {resolved, explicit}
  end

  defp normalize_compaction(nil), do: %{}

  defp normalize_compaction(compaction) when is_map(compaction),
    do: normalize_compaction_map(compaction)

  defp normalize_compaction(compaction) when is_list(compaction),
    do: normalize_compaction_map(Map.new(compaction))

  defp normalize_compaction(other) do
    raise ArgumentError,
          "compaction must be a keyword list or map, got: #{inspect(other)}"
  end

  defp normalize_compaction_map(map) do
    Enum.reduce(map, %{}, fn
      {:reserve_tokens, value}, acc ->
        Map.put(acc, :reserve_tokens, value)

      {"reserve_tokens", value}, acc ->
        Map.put(acc, :reserve_tokens, value)

      {:keep_recent_tokens, value}, acc ->
        Map.put(acc, :keep_recent_tokens, value)

      {"keep_recent_tokens", value}, acc ->
        Map.put(acc, :keep_recent_tokens, value)

      {:fallback, value}, acc ->
        Map.put(acc, :fallback, value)

      {"fallback", value}, acc ->
        Map.put(acc, :fallback, value)

      {key, _value}, _acc ->
        raise ArgumentError, "unsupported compaction option: #{inspect(key)}"
    end)
  end

  defp resolve_compaction_field(current_value, true, _default_value), do: current_value
  defp resolve_compaction_field(_current_value, false, default_value), do: default_value

  defp validate_compaction_tokens!(value, _field) when is_integer(value) and value > 0, do: value

  defp validate_compaction_tokens!(value, field) do
    raise ArgumentError,
          "#{field} must be a positive integer, got: #{inspect(value)}"
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
