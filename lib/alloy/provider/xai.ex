defmodule Alloy.Provider.XAI do
  @moduledoc """
  Provider for xAI's Grok models.

  Thin wrapper around `Alloy.Provider.OpenAI` that sets xAI defaults.
  xAI implements the OpenAI Responses API at `https://api.x.ai`, which
  returns reasoning as encrypted reasoning items that Alloy round-trips
  between tool calls. xAI's Chat Completions endpoint is deprecated and
  returns no reasoning content, so use this provider rather than
  `Alloy.Provider.OpenAICompat` for Grok.

  ## Config

  Required:
  - `:api_key` - xAI API key
  - `:model` - Model name (e.g., `"grok-4.7"`, `"grok-4.3"`,
    `"grok-build-0.1"`)

  Optional:
  - `:web_search` - `true` or config map to enable Grok's web search tool
  - `:x_search` - `true` or config map to enable search across X posts
  - All options from `Alloy.Provider.OpenAI` (`:max_tokens`, `:tool_choice`,
    `:previous_response_id`, etc.). Conversation state works the same way:
    the full history by default, or `:previous_response_id` plus only the
    new messages.

  ## Example

      Alloy.run("What's happening on X today?",
        provider: {Alloy.Provider.XAI,
          api_key: System.get_env("XAI_API_KEY"),
          model: "grok-4.7",
          web_search: true
        }
      )

  ## With X search

      Alloy.run("What are people saying about Elixir agents?",
        provider: {Alloy.Provider.XAI,
          api_key: System.get_env("XAI_API_KEY"),
          model: "grok-4.7",
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
