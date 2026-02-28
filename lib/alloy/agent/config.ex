defmodule Alloy.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  Built from the options passed to `Alloy.run/2`. Immutable for the
  duration of the run.
  """

  @type t :: %__MODULE__{
          provider: module(),
          provider_config: map(),
          tools: [module()],
          system_prompt: String.t() | nil,
          max_turns: pos_integer(),
          max_tokens: pos_integer(),
          max_retries: non_neg_integer(),
          retry_backoff_ms: pos_integer(),
          timeout_ms: pos_integer(),
          tool_timeout: pos_integer(),
          middleware: [module()],
          working_directory: String.t(),
          context: map(),
          context_discovery: boolean(),
          on_shutdown: (Alloy.Session.t() -> any()) | nil,
          pubsub: module() | nil,
          subscribe: [String.t()]
        }

  @enforce_keys [:provider, :provider_config]
  defstruct [
    :provider,
    :provider_config,
    tools: [],
    system_prompt: nil,
    max_turns: 25,
    max_tokens: 200_000,
    max_retries: 3,
    retry_backoff_ms: 1_000,
    timeout_ms: 120_000,
    tool_timeout: 120_000,
    middleware: [],
    working_directory: ".",
    context: %{},
    context_discovery: false,
    on_shutdown: nil,
    pubsub: nil,
    subscribe: []
  ]

  @doc """
  Builds a config from `Alloy.run/2` options.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    {provider_mod, provider_config} = parse_provider(opts[:provider])
    context_discovery = Keyword.get(opts, :context_discovery, false)
    context = Keyword.get(opts, :context, %{})
    working_directory = Keyword.get(opts, :working_directory, ".")
    base_prompt = Keyword.get(opts, :system_prompt)

    system_prompt =
      if context_discovery do
        discovery_opts = [
          home: Map.get(context, :home, System.user_home!()),
          working_directory: working_directory
        ]

        sections = Alloy.Context.Discovery.discover(discovery_opts)
        Alloy.Context.SystemPrompt.build(base_prompt || "", sections)
      else
        base_prompt
      end

    %__MODULE__{
      provider: provider_mod,
      provider_config: Map.new(provider_config),
      tools: Keyword.get(opts, :tools, []),
      system_prompt: system_prompt,
      max_turns: Keyword.get(opts, :max_turns, 25),
      max_tokens: Keyword.get(opts, :max_tokens, 200_000),
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
      tool_timeout: Keyword.get(opts, :tool_timeout, 120_000),
      middleware: Keyword.get(opts, :middleware, []),
      working_directory: working_directory,
      context: context,
      context_discovery: context_discovery,
      on_shutdown: Keyword.get(opts, :on_shutdown, nil),
      pubsub: Keyword.get(opts, :pubsub, nil),
      subscribe: Keyword.get(opts, :subscribe, [])
    }
  end

  defp parse_provider({module, config}) when is_atom(module) and is_list(config) do
    {module, config}
  end

  defp parse_provider(module) when is_atom(module) do
    {module, []}
  end
end
