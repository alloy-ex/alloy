defmodule Alloy.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Alloy.run/2`. Immutable for the
  duration of the run.
  """

  alias Alloy.ModelMetadata

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
          working_directory: String.t(),
          context: map(),
          on_shutdown: (Alloy.Session.t() -> any()) | nil,
          on_compaction: (list(), Alloy.Agent.State.t() -> any()) | nil,
          pubsub: module() | nil,
          subscribe: [String.t()],
          max_pending: non_neg_integer(),
          fallback_providers: [{module(), map()}],
          code_execution: boolean(),
          model_metadata_overrides: map()
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
    working_directory: ".",
    context: %{},
    on_shutdown: nil,
    on_compaction: nil,
    pubsub: nil,
    subscribe: [],
    max_pending: 0,
    fallback_providers: [],
    code_execution: false,
    model_metadata_overrides: %{}
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

    %__MODULE__{
      provider: provider_mod,
      provider_config: provider_config,
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_turns: Keyword.get(opts, :max_turns, 25),
      max_tokens:
        resolve_max_tokens(
          opts,
          provider_config,
          model_metadata_overrides,
          max_tokens_explicit?
        ),
      max_tokens_explicit?: max_tokens_explicit?,
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      tool_timeout: Keyword.get(opts, :tool_timeout, 120_000),
      middleware: Keyword.get(opts, :middleware, []),
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
      model_metadata_overrides: model_metadata_overrides
    }
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

    %{config | provider: provider_mod, provider_config: provider_config, max_tokens: max_tokens}
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
end
