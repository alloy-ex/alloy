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
          cache_read_input_tokens: non_neg_integer(),
          estimated_cost_cents: number()
        }

  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            estimated_cost_cents: 0

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
        acc.cache_read_input_tokens + Map.get(response_usage, :cache_read_input_tokens, 0),
      estimated_cost_cents:
        acc.estimated_cost_cents + Map.get(response_usage, :estimated_cost_cents, 0)
    }
  end

  @doc """
  Returns total tokens consumed (input + output).
  """
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{input_tokens: input, output_tokens: output})
      when is_integer(input) and is_integer(output) do
    input + output
  end

  @doc """
  Estimates cost in cents given per-million token prices in dollars.
  Replaces (does not accumulate) the existing `estimated_cost_cents`.

  Only `input_tokens` and `output_tokens` are priced; cache reads and
  writes are not included.
  """
  @spec estimate_cost(t(), number(), number()) :: t()
  def estimate_cost(%__MODULE__{} = usage, input_price_per_m, output_price_per_m) do
    # Rates stay unrounded: many models cost a fraction of a cent per million
    # tokens ($0.075/M is 7.5¢/M), and rounding the rate skews every estimate.
    input_cost = usage.input_tokens * input_price_per_m * 100 / 1_000_000
    output_cost = usage.output_tokens * output_price_per_m * 100 / 1_000_000
    %{usage | estimated_cost_cents: input_cost + output_cost}
  end
end
