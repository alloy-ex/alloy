defmodule Alloy.Internal.Sanitize do
  @moduledoc false
  # Shared UTF-8-safe byte capping, bounded term inspection, and stacktrace
  # argument stripping so errors and logs never allocate unboundedly or leak
  # secrets captured in raw payloads or function arguments.

  @default_inspect_opts [limit: 20, printable_limit: 500]

  @doc """
  Slices before sanitizing invalid UTF-8 so multi-MB invalid binaries never
  allocate proportionally, then normalizes invalid bytes and caps by UTF-8
  byte size while preserving valid UTF-8.
  """
  @spec cap_bytes(String.t(), pos_integer()) :: String.t()
  def cap_bytes(str, max_bytes) when is_binary(str) and is_integer(max_bytes) and max_bytes > 0 do
    slice =
      if byte_size(str) <= max_bytes do
        str
      else
        # Keep up to max_bytes + 3 bytes before sanitizing so a valid 4-byte
        # UTF-8 codepoint starting just before max_bytes stays intact.
        binary_part(str, 0, min(byte_size(str), max_bytes + 3))
      end

    valid = if String.valid?(slice), do: slice, else: String.replace_invalid(slice)

    if byte_size(valid) <= max_bytes do
      valid
    else
      valid
      |> binary_part(0, max_bytes)
      |> drop_incomplete_utf8_tail()
    end
  end

  @doc """
  Inspects a term with bounded collection and printable limits so unexpected
  payloads or model-supplied inputs cannot blow up error messages.
  """
  @spec inspect_bounded(term(), keyword()) :: String.t()
  def inspect_bounded(term, opts \\ []) do
    inspect(term, Keyword.merge(@default_inspect_opts, opts))
  end

  @doc """
  Inspects a term with bounded limits and caps the resulting UTF-8 byte size.
  """
  @spec inspect_capped(term(), pos_integer(), keyword()) :: String.t()
  def inspect_capped(term, max_bytes, opts \\ []) do
    term
    |> inspect_bounded(opts)
    |> cap_bytes(max_bytes)
  end

  @doc """
  Replaces argument lists in stacktrace entries with their arity so secrets
  captured in function arguments never leak into logs or error reports.
  """
  @spec stacktrace(Exception.stacktrace()) :: Exception.stacktrace()
  def stacktrace(entries) when is_list(entries) do
    Enum.map(entries, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      {fun, args, location} when is_list(args) -> {fun, length(args), location}
      entry -> entry
    end)
  end

  defp drop_incomplete_utf8_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      bin |> binary_part(0, byte_size(bin) - 1) |> drop_incomplete_utf8_tail()
    end
  end
end
