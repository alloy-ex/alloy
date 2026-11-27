defmodule Alloy.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Alloy.run/2`. Request inputs can be
  updated through `Alloy.Agent.State.prepare/2` in middleware.
  """

  alias Alloy.Cancel
  alias Alloy.Context.Compactor
  alias Alloy.Internal.Sanitize
  alias Alloy.ModelMetadata
  alias Alloy.OutputSchema

  @options [
    :tool_concurrency,
    :tool_validation,
    :stop_after_tool,
    :output_schema,
    :reasoning,
    :cancel_token,
    :steering,
    :follow_up,
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
          retry_backoff_ms: non_neg_integer(),
          timeout_ms: pos_integer() | :infinity,
          tool_timeout: pos_integer(),
          tool_concurrency: pos_integer() | nil,
          tool_validation: :required | :schema,
          stop_after_tool: String.t() | nil,
          output_schema: OutputSchema.t() | nil,
          reasoning: Alloy.Provider.normalized_reasoning() | nil,
          cancel_token: Cancel.t() | nil,
          steering: (Alloy.Agent.State.t() -> [Alloy.Message.t()]) | nil,
          follow_up: (Alloy.Agent.State.t() -> [Alloy.Message.t()]) | nil,
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

  @derive {Inspect, except: [:provider_config, :fallback_providers, :context]}
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
    tool_concurrency: nil,
    tool_validation: :required,
    stop_after_tool: nil,
    output_schema: nil,
    reasoning: nil,
    cancel_token: nil,
    steering: nil,
    follow_up: nil,
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
      provider_config
      |> normalize_provider_config()
      |> reject_removed!(provider_mod)
      |> validate_provider_auth!(provider_mod)
      |> validate_provider_reasoning!()

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

    system_prompt = opts[:system_prompt]
    tool_validation = Keyword.get(opts, :tool_validation, :required)
    context = Keyword.get(opts, :context, %{})
    on_compaction = opts[:on_compaction]
    cancel_token = opts[:cancel_token]
    steering = opts[:steering]
    follow_up = opts[:follow_up]
    code_execution = Keyword.get(opts, :code_execution, false)

    %__MODULE__{
      provider: provider_mod,
      provider_config: provider_config,
      tools: tools,
      system_prompt:
        require_opt_shape!(
          is_nil(system_prompt) or is_binary(system_prompt),
          system_prompt,
          "system_prompt must be a string or nil"
        ),
      max_turns: validate_pos_integer!(Keyword.get(opts, :max_turns, 25), :max_turns),
      max_tokens: max_tokens,
      max_tokens_explicit?: max_tokens_explicit?,
      max_retries: validate_non_neg_integer!(Keyword.get(opts, :max_retries, 3), :max_retries),
      retry_backoff_ms:
        validate_non_neg_integer!(Keyword.get(opts, :retry_backoff_ms, 1_000), :retry_backoff_ms),
      timeout_ms: validate_timeout_ms!(Keyword.get(opts, :timeout_ms, 120_000)),
      tool_timeout:
        validate_pos_integer!(Keyword.get(opts, :tool_timeout, 120_000), :tool_timeout),
      tool_concurrency: validate_tool_concurrency!(Keyword.get(opts, :tool_concurrency)),
      tool_validation:
        require_opt!(
          tool_validation in [:required, :schema],
          tool_validation,
          "tool_validation must be :required or :schema"
        ),
      stop_after_tool:
        validate_optional_non_empty_string!(
          Keyword.get(opts, :stop_after_tool),
          "stop_after_tool must be a nonempty tool name"
        ),
      output_schema: OutputSchema.normalize!(Keyword.get(opts, :output_schema)),
      reasoning: Alloy.Provider.normalize_reasoning!(Keyword.get(opts, :reasoning)),
      cancel_token:
        require_opt_shape!(
          is_nil(cancel_token) or Cancel.valid?(cancel_token),
          cancel_token,
          "cancel_token must be an Alloy.Cancel struct or nil"
        ),
      steering:
        require_opt_shape!(
          is_nil(steering) or is_function(steering, 1),
          steering,
          "steering must be a 1-arity function or nil"
        ),
      follow_up:
        require_opt_shape!(
          is_nil(follow_up) or is_function(follow_up, 1),
          follow_up,
          "follow_up must be a 1-arity function or nil"
        ),
      middleware:
        resolve_middleware(
          validate_middleware!(Keyword.get(opts, :middleware, [])),
          opts[:compaction]
        ),
      compaction: compaction,
      compaction_explicit: compaction_explicit,
      working_directory:
        validate_non_empty_string!(Keyword.get(opts, :working_directory, "."), :working_directory),
      context: require_opt_shape!(is_map(context), context, "context must be a map"),
      on_compaction:
        require_opt!(
          is_nil(on_compaction) or is_function(on_compaction, 2),
          on_compaction,
          "on_compaction must be a 2-arity function or nil"
        ),
      fallback_providers:
        opts
        |> Keyword.get(:fallback_providers, [])
        |> validate_fallback_providers!(),
      code_execution:
        require_opt!(
          is_boolean(code_execution),
          code_execution,
          "code_execution must be a boolean"
        ),
      model_metadata_overrides: model_metadata_overrides,
      model_catalog: model_catalog,
      until_tool:
        validate_optional_non_empty_string!(
          Keyword.get(opts, :until_tool),
          "until_tool must be a nonempty string or nil"
        )
    }
  end

  defp require_opt!(true, value, _msg), do: value

  defp require_opt!(false, value, msg),
    do: raise(ArgumentError, "#{msg}, got: #{Sanitize.inspect_bounded(value)}")

  defp require_opt_shape!(true, value, _msg), do: value

  defp require_opt_shape!(false, value, msg),
    do: raise(ArgumentError, "#{msg}, got: #{Sanitize.shape_summary(value)}")

  defp validate_timeout_ms!(:infinity), do: :infinity

  defp validate_timeout_ms!(value),
    do:
      require_opt!(
        is_integer(value) and value > 0,
        value,
        "timeout_ms must be a positive integer or :infinity"
      )

  defp validate_pos_integer!(value, field),
    do:
      require_opt!(is_integer(value) and value > 0, value, "#{field} must be a positive integer")

  defp validate_non_neg_integer!(value, field),
    do:
      require_opt!(
        is_integer(value) and value >= 0,
        value,
        "#{field} must be a non-negative integer"
      )

  defp validate_non_empty_string!(value, field),
    do:
      require_opt!(
        is_binary(value) and byte_size(value) > 0,
        value,
        "#{field} must be a nonempty string"
      )

  defp validate_optional_non_empty_string!(nil, _msg), do: nil

  defp validate_optional_non_empty_string!(value, msg),
    do: require_opt!(is_binary(value) and byte_size(value) > 0, value, msg)

  defp validate_tool_concurrency!(nil), do: nil

  defp validate_tool_concurrency!(value),
    do:
      require_opt!(
        is_integer(value) and value > 0,
        value,
        "tool_concurrency must be a positive integer"
      )

  defp validate_middleware!(value) do
    require_opt_shape!(
      is_list(value) and Enum.all?(value, &valid_module_atom?/1),
      value,
      "middleware must be a list of module atoms"
    )
  end

  defp validate_fallback_providers!(value) do
    require_opt_shape!(is_list(value), value, "fallback_providers must be a list")
    |> Enum.map(&parse_fallback_provider/1)
  end

  defp valid_module_atom?(mod), do: is_atom(mod) and not is_nil(mod) and not is_boolean(mod)

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

  # Default compaction budgets the inputs prepared by caller middleware.
  # Explicitly listing the compactor preserves the caller's chosen order.
  defp resolve_middleware(middleware, false) do
    if Compactor in middleware do
      raise ArgumentError,
            "compaction: false conflicts with Alloy.Context.Compactor in :middleware; " <>
              "remove one of them"
    end

    middleware
  end

  defp resolve_middleware(middleware, _compaction) do
    if Compactor in middleware, do: middleware, else: middleware ++ [Compactor]
  end

  defp reject_removed!(provider_config, provider) do
    if Map.has_key?(provider_config, :output_schema) or
         Map.has_key?(provider_config, "output_schema") do
      raise ArgumentError,
            "pass :output_schema as a top-level Alloy.run/2 option, not inside provider config"
    end

    case Map.get(@removed_provider_options, provider) do
      {key, message} when is_map_key(provider_config, key) -> raise ArgumentError, message
      _none -> provider_config
    end
  end

  defp validate_provider_auth!(provider_config, provider) do
    case Map.get(provider_config, :api_key) do
      fun when is_function(fun, 0) ->
        require_origin_key!(
          provider_config,
          provider,
          "uses a function :api_key and must also set a non-empty string :origin_key for account isolation"
        )

      fun when is_function(fun) ->
        raise ArgumentError,
              "provider #{inspect(provider)} :api_key callback must be a 0-arity function"

      _other ->
        if Map.get(provider_config, :auth_scheme) == :bearer do
          require_origin_key!(
            provider_config,
            provider,
            "uses auth_scheme: :bearer and must also set a non-empty string :origin_key so rotating bearer tokens preserve account provenance"
          )
        else
          validate_optional_origin_key!(provider_config, provider)
        end
    end
  end

  defp validate_optional_origin_key!(provider_config, provider) do
    case Map.fetch(provider_config, :origin_key) do
      :error ->
        provider_config

      {:ok, nil} ->
        provider_config

      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        provider_config

      {:ok, _invalid} ->
        raise ArgumentError,
              "provider #{inspect(provider)} :origin_key must be a non-empty string when set"
    end
  end

  defp validate_provider_reasoning!(provider_config) do
    case Map.fetch(provider_config, :reasoning) do
      :error ->
        provider_config

      {:ok, value} ->
        Map.put(provider_config, :reasoning, Alloy.Provider.normalize_reasoning!(value))
    end
  end

  defp require_origin_key!(provider_config, provider, detail) do
    origin_key = Map.get(provider_config, :origin_key)

    unless is_binary(origin_key) and byte_size(origin_key) > 0 do
      raise ArgumentError, "provider #{inspect(provider)} #{detail}"
    end

    provider_config
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
      provider_config
      |> normalize_provider_config()
      |> reject_removed!(provider_mod)
      |> validate_provider_auth!(provider_mod)
      |> validate_provider_reasoning!()

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
        summary_system_prompt:
          Map.get(
            config.compaction,
            :summary_system_prompt,
            Compactor.default_summary_system_prompt()
          ),
        summary_prompt:
          Map.get(config.compaction, :summary_prompt, Compactor.default_summary_prompt())
      }

    %{
      config
      | provider: provider_mod,
        provider_config: provider_config,
        max_tokens: max_tokens,
        compaction: compaction
    }
  end

  defp parse_provider(entry), do: parse_provider_entry(entry, "provider", [])

  defp parse_fallback_provider(entry) do
    {mod, cfg} = parse_provider_entry(entry, "fallback provider", %{})

    {mod,
     cfg
     |> normalize_provider_config()
     |> reject_removed!(mod)
     |> validate_provider_auth!(mod)
     |> validate_provider_reasoning!()}
  end

  defp parse_provider_entry({mod, cfg}, _label, _default)
       when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) and
              (is_list(cfg) or is_map(cfg)),
       do: {mod, cfg}

  defp parse_provider_entry(mod, _label, default)
       when is_atom(mod) and not is_nil(mod) and not is_boolean(mod),
       do: {mod, default}

  defp parse_provider_entry(other, label, _default) do
    raise ArgumentError,
          "#{label} must be a module or {module, config} tuple, got: #{format_invalid_provider(other)}"
  end

  defp format_invalid_provider({mod, _config}), do: "{#{Sanitize.shape_summary(mod)}, ...}"
  defp format_invalid_provider(other), do: Sanitize.shape_summary(other)

  defp normalize_provider_config(config) when is_map(config), do: config
  defp normalize_provider_config(config) when is_list(config), do: Map.new(config)

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
      opts |> Keyword.fetch!(:max_tokens) |> validate_pos_integer!(:max_tokens)
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
