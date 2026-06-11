defmodule Alloy.ModelCatalog do
  @moduledoc """
  Behaviour for pluggable model-metadata catalogs.

  Alloy needs one fact about a model to do context budgeting: its context
  window. The built-in catalog (`Alloy.ModelMetadata`) ships a small,
  hand-curated set of entries — enough to work out of the box, but it will
  always lag the model release treadmill. This behaviour lets you swap in
  your own source of truth instead.

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

  ## Example: static map

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
  sourced from models.dev. An adapter is a few lines:

      defmodule MyApp.LlmDbCatalog do
        @behaviour Alloy.ModelCatalog

        @impl true
        def context_window(model) do
          case LLMDb.model(model) do
            %{context_window: limit} when is_integer(limit) -> limit
            _ -> nil
          end
        end
      end

  Returning `nil` from `c:context_window/1` means "unknown model" and falls
  through to the default window — it is not an error.
  """

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

  @optional_callbacks default_context_window: 0

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
    if function_exported?(catalog, :default_context_window, 0) do
      catalog.default_context_window()
    else
      Alloy.ModelMetadata.default_context_window()
    end
  end
end
