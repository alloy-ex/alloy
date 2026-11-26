defmodule Alloy.Cancel do
  @moduledoc """
  Lock-free cooperative cancellation token for `Alloy.run/2` and `Alloy.stream/3`.

  Backed by a single unsigned `:atomics` slot — no processes, no ETS tables,
  and nothing to clean up or leak. Pass a token via `:cancel_token` and call
  `cancel/1` from any process to cooperatively stop an in-flight run:

      token = Alloy.Cancel.new()
      task = Task.async(fn -> Alloy.run("Analyze repo", provider: provider, cancel_token: token) end)
      Alloy.Cancel.cancel(token)
      {:error, %Alloy.Result{status: :cancelled, error: :cancelled}} = Task.await(task)

  Cancellation is idempotent and monotonic: once cancelled, a token remains
  cancelled. Create a fresh token with `new/0` for each new run.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref()}

  @doc """
  Creates a new, uncancelled token.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{ref: :atomics.new(1, signed: false)}
  end

  @doc """
  Marks the token as cancelled. Safe to call from any process and idempotent.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}) do
    :atomics.put(ref, 1, 1)
    :ok
  end

  @doc """
  Returns `true` if `token` has been cancelled, or `false` if uncancelled or `nil`.
  """
  @spec cancelled?(t() | nil) :: boolean()
  def cancelled?(nil), do: false
  def cancelled?(%__MODULE__{ref: ref}), do: :atomics.get(ref, 1) != 0
end
