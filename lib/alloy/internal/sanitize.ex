defmodule Alloy.Internal.Sanitize do
  @moduledoc false
  # Shared UTF-8-safe byte capping, bounded term inspection, and stacktrace
  # argument stripping so errors and logs never allocate unboundedly or leak
  # secrets captured in raw payloads or function arguments.

  @default_inspect_opts [limit: 20, printable_limit: 500]
  @default_max_inspect_bytes 500

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
  Inspects a term with bounded collection/printable limits and caps the total
  UTF-8 byte size (default: 500 bytes, configurable via `:max_bytes`) so nested
  collections or unexpected model payloads cannot blow up error messages.
  """
  @spec inspect_bounded(term(), keyword()) :: String.t()
  def inspect_bounded(term, opts \\ []) do
    {max_bytes, inspect_opts} = Keyword.pop(opts, :max_bytes, @default_max_inspect_bytes)
    rendered = inspect(term, Keyword.merge(@default_inspect_opts, inspect_opts))

    if byte_size(rendered) > max_bytes and max_bytes > 3 do
      cap_bytes(rendered, max_bytes - 3) <> "..."
    else
      cap_bytes(rendered, max_bytes)
    end
  end

  @doc """
  Returns a bounded, value-safe exception summary.

  Structural Elixir exceptions (`KeyError`, `MatchError`, `CaseClauseError`,
  `BadMapError`, `WithClauseError`, etc.) embed raw inspected terms — potentially
  whole config or context maps carrying API keys — inside `Exception.message/1`.
  Only explicit `RuntimeError` messages (capped to `max_bytes`), standard
  `:badarg` (`"argument error"`), and atom key names on `KeyError` are kept;
  all other exceptions report only their module.
  """
  @spec exception_summary(Exception.t(), pos_integer() | :redact) :: String.t()
  def exception_summary(exception, max_bytes \\ 500)

  def exception_summary(%mod{}, :redact), do: inspect(mod)

  def exception_summary(%RuntimeError{message: msg}, max_bytes)
      when is_binary(msg) and is_integer(max_bytes) and max_bytes > 0 do
    cap_bytes(msg, max_bytes)
  end

  def exception_summary(%ArgumentError{message: "argument error"}, _max_bytes) do
    "argument error"
  end

  def exception_summary(%KeyError{key: key}, _max_bytes) when is_atom(key) do
    "KeyError (key #{inspect(key)} not found)"
  end

  def exception_summary(%mod{}, _max_bytes), do: inspect(mod)

  @doc """
  Returns a bounded, value-safe summary for a caught `:error`, `:exit`, or
  `:throw` crash without leaking captured context or arguments.
  """
  @spec crash_summary(:error | :exit | :throw, term(), Exception.stacktrace(), pos_integer()) ::
          String.t()
  def crash_summary(kind, reason, stacktrace, max_bytes \\ 500)

  def crash_summary(:error, reason, stacktrace, max_bytes) do
    case Exception.normalize(:error, reason, stacktrace) do
      %ErlangError{original: orig} -> "error: #{exit_summary(orig, max_bytes)}"
      exception -> exception_summary(exception, max_bytes)
    end
  end

  def crash_summary(kind, reason, _stacktrace, max_bytes) do
    "#{kind}: #{exit_summary(reason, max_bytes)}"
  end

  @doc """
  Returns a bounded, value-safe summary for a process exit or thrown term.

  Recursively unwraps stacktrace wrappers (`{reason, stacktrace}`) and OTP
  call-exit tuples (`{reason, {mod, fun, args}}`, dropping `args`), formats
  exceptions via `exception_summary/2`, preserves small primitive tags (atoms,
  numbers, `{:shutdown, atom}`), and replaces arbitrary compound terms with
  type labels so secrets never leak.
  """
  @spec exit_summary(term(), pos_integer() | :redact) :: String.t()
  def exit_summary(reason, max_bytes \\ 500)

  def exit_summary({inner, {mod, fun, args}}, max_bytes)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    exit_summary(inner, max_bytes)
  end

  def exit_summary({{:nocatch, thrown}, stack}, max_bytes) when is_list(stack) do
    if stacktrace?(stack),
      do: "nocatch: #{exit_summary(thrown, max_bytes)}",
      else: "unexpected tuple"
  end

  def exit_summary({inner, stack}, max_bytes) when is_list(stack) do
    cond do
      stacktrace?(stack) ->
        case Exception.normalize(:error, inner, stack) do
          %ErlangError{original: orig} -> exit_summary(orig, max_bytes)
          exception -> exception_summary(exception, max_bytes)
        end

      stack == [] and is_exception(inner) ->
        exception_summary(inner, max_bytes)

      stack == [] and is_atom(inner) ->
        inspect(inner)

      is_atom(inner) ->
        "{#{inspect(inner)}, ...}"

      true ->
        "unexpected tuple"
    end
  end

  def exit_summary({:nocatch, thrown}, max_bytes) do
    "nocatch: #{exit_summary(thrown, max_bytes)}"
  end

  def exit_summary({tag, detail}, _max_bytes) when is_atom(tag) and is_atom(detail) do
    "{#{inspect(tag)}, #{inspect(detail)}}"
  end

  def exit_summary({tag, _other}, _max_bytes) when is_atom(tag), do: "{#{inspect(tag)}, ...}"

  def exit_summary(exception, max_bytes) when is_exception(exception) do
    exception_summary(exception, max_bytes)
  end

  def exit_summary(reason, _max_bytes) when is_atom(reason) or is_number(reason) do
    inspect(reason)
  end

  def exit_summary(%mod{}, _max_bytes), do: "unexpected #{inspect(mod)}"
  def exit_summary(reason, _max_bytes) when is_map(reason), do: "unexpected map"
  def exit_summary(reason, _max_bytes) when is_tuple(reason), do: "unexpected tuple"
  def exit_summary(reason, _max_bytes) when is_list(reason), do: "unexpected list"
  def exit_summary(reason, _max_bytes) when is_binary(reason), do: "unexpected binary"
  def exit_summary(_other, _max_bytes), do: "unexpected term"

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

  defp stacktrace?([{mod, fun, arity_or_args, loc} | _])
       when is_atom(mod) and is_atom(fun) and
              (is_integer(arity_or_args) or is_list(arity_or_args)) and is_list(loc),
       do: true

  defp stacktrace?([{fun, arity_or_args, loc} | _])
       when is_function(fun) and (is_integer(arity_or_args) or is_list(arity_or_args)) and
              is_list(loc),
       do: true

  defp stacktrace?(_), do: false

  defp drop_incomplete_utf8_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      bin |> binary_part(0, byte_size(bin) - 1) |> drop_incomplete_utf8_tail()
    end
  end
end
