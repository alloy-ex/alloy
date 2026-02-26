defmodule Alloy.Usage do
  @moduledoc """
  Token usage tracking across turns.

  Accumulates input/output token counts from provider responses
  so callers can track costs and enforce limits.
  """

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }

  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0

  @doc """
  Merges usage from a provider response into accumulated usage.
  """
  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = acc, response_usage) when is_map(response_usage) do
    %__MODULE__{
      input_tokens: acc.input_tokens + Map.get(response_usage, :input_tokens, 0),
      output_tokens: acc.output_tokens + Map.get(response_usage, :output_tokens, 0),
      cache_creation_input_tokens:
        acc.cache_creation_input_tokens +
          Map.get(response_usage, :cache_creation_input_tokens, 0),
      cache_read_input_tokens:
        acc.cache_read_input_tokens + Map.get(response_usage, :cache_read_input_tokens, 0)
    }
  end

  @doc """
  Returns total tokens consumed (input + output).
  """
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = usage) do
    usage.input_tokens + usage.output_tokens
  end
end
