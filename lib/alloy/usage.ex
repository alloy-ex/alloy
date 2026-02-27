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
          estimated_cost_cents: non_neg_integer()
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
  def total(%__MODULE__{} = usage) do
    usage.input_tokens + usage.output_tokens
  end

  @doc """
  Estimates cost in cents given per-million token prices.

  **Important:** This function **replaces** the existing `estimated_cost_cents`
  value with a freshly computed one based on the struct's token counts. It does
  **not** accumulate — any previously stored cost (including costs merged via
  `merge/2`) will be overwritten. Call this on a fresh `Usage.t()` or before
  calling `merge/2` to avoid silently losing merged costs.

  If you need to accumulate costs across multiple turns, use `merge/2` which
  preserves and sums `estimated_cost_cents`.

  Prices are in USD per million tokens. The result is stored as integer cents
  (rounded) to avoid floating-point accumulation errors across turns.

  Costs are computed in whole cents and fractional cents are truncated (not
  rounded). For high-volume, low-token workloads this may under-report by up
  to 1 cent per call.

  ## Examples

      iex> usage = %Alloy.Usage{input_tokens: 1_000_000, output_tokens: 1_000_000}
      iex> Alloy.Usage.estimate_cost(usage, 3.0, 15.0)
      %Alloy.Usage{input_tokens: 1_000_000, output_tokens: 1_000_000, estimated_cost_cents: 1800}

  """
  @spec estimate_cost(t(), number(), number()) :: t()
  def estimate_cost(%__MODULE__{} = usage, input_price_per_m, output_price_per_m) do
    # Convert rates to integer cents-per-million to avoid float accumulation errors.
    # round/1 is used only once here on the rate conversion (not on the token math),
    # so any imprecision is limited to sub-cent rounding of the rate itself.
    input_cents_per_m = round(input_price_per_m * 100)
    output_cents_per_m = round(output_price_per_m * 100)
    input_cost = div(usage.input_tokens * input_cents_per_m, 1_000_000)
    output_cost = div(usage.output_tokens * output_cents_per_m, 1_000_000)
    %{usage | estimated_cost_cents: input_cost + output_cost}
  end
end
