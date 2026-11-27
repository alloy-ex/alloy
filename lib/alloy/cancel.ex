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
  defstruct [:ref, parents: []]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref(), parents: [t()]}

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
  def cancelled?(%__MODULE__{ref: ref, parents: []}), do: :atomics.get(ref, 1) != 0

  def cancelled?(%__MODULE__{ref: ref, parents: parents}) do
    :atomics.get(ref, 1) != 0 or Enum.any?(parents, &cancelled?/1)
  end

  @doc false
  @spec combine(t() | nil, t() | nil) :: t() | nil
  def combine(nil, inner), do: inner
  def combine(outer, nil), do: outer
  def combine(%__MODULE__{ref: ref} = outer, %__MODULE__{ref: ref}), do: outer

  def combine(%__MODULE__{} = outer, %__MODULE__{parents: parents} = inner) do
    %{inner | parents: Enum.uniq([outer | parents])}
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{ref: ref, parents: parents})
      when is_reference(ref) and is_list(parents) do
    Enum.all?(parents, &valid?/1)
  end

  def valid?(_other), do: false
end
