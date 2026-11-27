defmodule Alloy.Internal.Deadline do
  @moduledoc false
  # Shared monotonic-millisecond deadline arithmetic used across the agent
  # loop, tool executor, compactor, owned workers, and HTTP transport.

  @type t :: integer() | nil

  @doc """
  Returns `true` when `deadline` has been reached or passed. A `nil` deadline
  never expires.
  """
  @spec expired?(t()) :: boolean()
  def expired?(nil), do: false

  def expired?(deadline) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  @doc """
  Returns the earlier of two optional deadlines, treating `nil` as unbounded.
  """
  @spec min(t(), t()) :: t()
  def min(nil, b) when is_integer(b) or is_nil(b), do: b
  def min(a, nil) when is_integer(a), do: a
  def min(a, b) when is_integer(a) and is_integer(b), do: Kernel.min(a, b)

  @doc """
  Returns remaining milliseconds until `deadline`, floored at `0`, or
  `:infinity` when `deadline` is `nil`.
  """
  @spec remaining_ms(t()) :: non_neg_integer() | :infinity
  def remaining_ms(nil), do: :infinity

  def remaining_ms(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  @doc """
  Bounds `max_wait_ms` (a non-negative integer or `:infinity`) by the remaining
  time before `deadline`.
  """
  @spec next_wait_ms(t(), non_neg_integer() | :infinity) :: non_neg_integer() | :infinity
  def next_wait_ms(nil, max_wait_ms)
      when max_wait_ms == :infinity or (is_integer(max_wait_ms) and max_wait_ms >= 0),
      do: max_wait_ms

  def next_wait_ms(deadline, :infinity) when is_integer(deadline), do: remaining_ms(deadline)

  def next_wait_ms(deadline, max_wait_ms)
      when is_integer(deadline) and is_integer(max_wait_ms) and max_wait_ms >= 0 do
    Kernel.min(remaining_ms(deadline), max_wait_ms)
  end
end
