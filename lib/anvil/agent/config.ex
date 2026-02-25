defmodule Anvil.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Anvil.run/2`. Immutable for the
  duration of the run.
  """

  @type t :: %__MODULE__{
          provider: module(),
          provider_config: map(),
          tools: [module()],
          system_prompt: String.t() | nil,
          max_turns: pos_integer(),
          max_tokens: pos_integer(),
          middleware: [module()],
          working_directory: String.t(),
          context: map()
        }

  @enforce_keys [:provider, :provider_config]
  defstruct [
    :provider,
    :provider_config,
    tools: [],
    system_prompt: nil,
    max_turns: 25,
    max_tokens: 200_000,
    middleware: [],
    working_directory: ".",
    context: %{}
  ]

  @doc """
  Builds a config from `Anvil.run/2` options.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    {provider_mod, provider_config} = parse_provider(opts[:provider])

    %__MODULE__{
      provider: provider_mod,
      provider_config: Map.new(provider_config),
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_turns: Keyword.get(opts, :max_turns, 25),
      max_tokens: Keyword.get(opts, :max_tokens, 200_000),
      middleware: Keyword.get(opts, :middleware, []),
      working_directory: Keyword.get(opts, :working_directory, "."),
      context: Keyword.get(opts, :context, %{})
    }
  end

  defp parse_provider({module, config}) when is_atom(module) and is_list(config) do
    {module, config}
  end

  defp parse_provider(module) when is_atom(module) do
    {module, []}
  end
end
