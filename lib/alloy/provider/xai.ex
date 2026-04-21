defmodule Alloy.Provider.XAI do
  @moduledoc """
  Provider for xAI's Grok models.

  Thin wrapper around `Alloy.Provider.OpenAI` that sets xAI defaults.
  xAI implements the OpenAI Responses API at `https://api.x.ai`.

  ## Config

  Required:
  - `:api_key` - xAI API key
  - `:model` - Model name (e.g., `"grok-4.20-0309-reasoning"`,
    `"grok-4.1-fast-reasoning"`, `"grok-code-fast-1"`)

  Optional:
  - `:web_search` - `true` or config map to enable Grok's web search tool
  - `:x_search` - `true` or config map to enable search across X posts
  - All options from `Alloy.Provider.OpenAI` (`:max_tokens`, `:tool_choice`, etc.)

  ## Example

      Alloy.run("What's happening on X today?",
        provider: {Alloy.Provider.XAI,
          api_key: System.get_env("XAI_API_KEY"),
          model: "grok-4.20-0309-reasoning",
          web_search: true
        }
      )

  ## With X search

      Alloy.run("What are people saying about Elixir agents?",
        provider: {Alloy.Provider.XAI,
          api_key: System.get_env("XAI_API_KEY"),
          model: "grok-4",
          x_search: true
        }
      )
  """

  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.OpenAI

  @xai_api_url "https://api.x.ai"

  @typedoc """
  Configuration for the xAI provider. Inherits the full `Alloy.Provider.OpenAI`
  config surface plus `:web_search` and `:x_search` for Grok's native search
  tools. `:api_url` defaults to `"https://api.x.ai"`.
  """
  @type config :: OpenAI.config()

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    OpenAI.complete(messages, tool_defs, with_defaults(config))
  end

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    OpenAI.stream(messages, tool_defs, with_defaults(config), on_chunk)
  end

  defp with_defaults(config) do
    Map.put_new(config, :api_url, @xai_api_url)
  end
end
