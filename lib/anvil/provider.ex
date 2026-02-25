defmodule Anvil.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider translates between its native wire format and Anvil's
  normalized `Anvil.Message` structs. The agent loop only sees normalized
  messages - adding a new provider means implementing this behaviour.

  ## Completion Response

  Providers return a map with:
  - `:stop_reason` - `:tool_use` (continue looping) or `:end_turn` (done)
  - `:messages` - list of `Anvil.Message` structs from the response
  - `:usage` - map with `:input_tokens` and `:output_tokens`
  """

  @type stop_reason :: :tool_use | :end_turn
  @type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

  @type completion_response :: %{
          stop_reason: stop_reason(),
          messages: [Anvil.Message.t()],
          usage: map()
        }

  @doc """
  Send messages to the provider and get a completion response.

  ## Parameters
  - `messages` - Conversation history as normalized `Anvil.Message` structs
  - `tool_defs` - Tool definitions (JSON Schema format)
  - `config` - Provider-specific configuration (API keys, model, etc.)

  ## Returns
  - `{:ok, completion_response()}` on success
  - `{:error, term()}` on failure
  """
  @callback complete(
              messages :: [Anvil.Message.t()],
              tool_defs :: [tool_def()],
              config :: map()
            ) :: {:ok, completion_response()} | {:error, term()}
end
