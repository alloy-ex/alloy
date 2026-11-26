defmodule Alloy.ModelCatalog do
  @moduledoc """
  Behaviour for pluggable model-metadata catalogs.

  Alloy requires only one fact about a model for context budgeting: its context
  window (`c:context_window/1`). The built-in catalog (`Alloy.ModelMetadata`)
  ships a hand-curated set of entries for native-provider families — enough to
  work out of the box, while letting you swap in your own source of truth via
  `:model_catalog`.

  Catalogs may also implement optional callbacks for maximum output tokens
  (`c:max_output_tokens/1`), model capabilities (`c:capabilities/1`), and
  reference pricing (`c:pricing/1`). Callers can query all available metadata
  through `info/2` without assuming which optional callbacks a catalog exports.

  Pass the catalog module per run (or per agent) via `:model_catalog`:

      Alloy.run("...",
        provider: {Alloy.Provider.Anthropic, api_key: key, model: model},
        model_catalog: MyApp.ModelCatalog
      )

  Resolution order when deriving the token budget:

  1. an explicit `:max_tokens` option always wins
  2. `:model_metadata_overrides` (exact/family overrides, see
     `Alloy.ModelMetadata.context_window/2`)
  3. the `:model_catalog` module's `c:context_window/1`
  4. the catalog's `c:default_context_window/0` if exported, otherwise
     `Alloy.ModelMetadata.default_context_window/0`

  ## Example: minimal static map

      defmodule MyApp.ModelCatalog do
        @behaviour Alloy.ModelCatalog

        @windows %{
          "claude-opus-4-8" => 1_000_000,
          "internal-finetune-v3" => 32_768
        }

        @impl true
        def context_window(model), do: Map.get(@windows, model)
      end

  ## Example: backed by `llm_db`

  [`llm_db`](https://hex.pm/packages/llm_db) maintains a large model catalog
  sourced from models.dev. See `docs/recipes/llm-db-catalog.md` for a full
  adapter implementing context windows, output limits, capabilities, and
  pricing.

  Returning `nil` from `c:context_window/1` (or any optional metadata callback)
  means "unknown model" — it is not an error.
  """

  @typedoc """
  Capability flags for a model. All keys are optional so catalogs may populate
  only the capabilities they track.
  """
  @type capabilities :: %{
          optional(:reasoning?) => boolean(),
          optional(:vision?) => boolean(),
          optional(:documents?) => boolean(),
          optional(:tools?) => boolean(),
          optional(:structured_output?) => boolean(),
          optional(:prompt_caching?) => boolean()
        }

  @typedoc """
  Reference pricing in USD per million tokens.
  """
  @type pricing :: %{
          required(:input_per_million) => number(),
          required(:output_per_million) => number(),
          optional(:cache_read_per_million) => number(),
          optional(:cache_write_per_million) => number()
        }

  @typedoc """
  Normalized metadata snapshot returned by `info/2`.
  """
  @type model_info :: %{
          model: String.t(),
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          capabilities: capabilities() | nil,
          pricing: pricing() | nil
        }

  @doc """
  Returns the context window (in tokens) for `model`, or `nil` if unknown.
  """
  @callback context_window(model :: String.t()) :: pos_integer() | nil

  @doc """
  Returns the fallback context window used when `c:context_window/1`
  returns `nil`.

  Optional — when not exported, Alloy falls back to
  `Alloy.ModelMetadata.default_context_window/0`.
  """
  @callback default_context_window() :: pos_integer()

  @doc """
  Returns the maximum output token limit for `model`, or `nil` if unknown.
  """
  @callback max_output_tokens(model :: String.t()) :: pos_integer() | nil

  @doc """
  Returns the capability flags for `model`, or `nil` if unknown.
  """
  @callback capabilities(model :: String.t()) :: capabilities() | nil

  @doc """
  Returns reference pricing (USD per million tokens) for `model`, or `nil` if
  unknown.
  """
  @callback pricing(model :: String.t()) :: pricing() | nil

  @optional_callbacks default_context_window: 0,
                      max_output_tokens: 1,
                      capabilities: 1,
                      pricing: 1

  @doc """
  Returns a normalized metadata map for `model` from `catalog` (defaulting to
  `Alloy.ModelMetadata`).

  Optional callbacks (`c:max_output_tokens/1`, `c:capabilities/1`,
  `c:pricing/1`) are queried only when exported by `catalog`, returning `nil`
  otherwise so minimal catalogs implementing only `c:context_window/1` work
  unchanged.
  """
  @spec info(module(), String.t()) :: model_info()
  def info(catalog \\ Alloy.ModelMetadata, model) when is_binary(model) do
    validate!(catalog)

    %{
      model: model,
      context_window: catalog.context_window(model),
      max_output_tokens: call_optional(catalog, :max_output_tokens, model),
      capabilities: call_optional(catalog, :capabilities, model),
      pricing: call_optional(catalog, :pricing, model)
    }
  end

  @doc false
  @spec validate!(term()) :: module()
  def validate!(catalog) when is_atom(catalog) and not is_nil(catalog) do
    unless Code.ensure_loaded?(catalog) and function_exported?(catalog, :context_window, 1) do
      raise ArgumentError,
            ":model_catalog must be a module implementing Alloy.ModelCatalog " <>
              "(context_window/1). Got: #{inspect(catalog)}"
    end

    catalog
  end

  def validate!(bad) do
    raise ArgumentError,
          ":model_catalog must be a module implementing Alloy.ModelCatalog " <>
            "(context_window/1). Got: #{inspect(bad)}"
  end

  @doc false
  @spec default_window(module()) :: pos_integer()
  def default_window(catalog) do
    if Code.ensure_loaded?(catalog) and function_exported?(catalog, :default_context_window, 0) do
      catalog.default_context_window()
    else
      Alloy.ModelMetadata.default_context_window()
    end
  end

  defp call_optional(catalog, fun, model) do
    if function_exported?(catalog, fun, 1) do
      apply(catalog, fun, [model])
    else
      nil
    end
  end
end
