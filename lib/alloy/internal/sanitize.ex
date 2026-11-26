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

  def exception_summary(exception, max_bytes) do
    case exception_parts(exception, max_bytes) do
      {mod, nil} -> mod
      {"RuntimeError", msg} -> msg
      {"ArgumentError", "argument error"} -> "argument error"
      {mod, detail} -> "#{mod} (#{detail})"
    end
  end

  @doc """
  Returns `{module_name, safe_detail | nil}` for an exception so diagnostic
  headers can include the module name once without prefix-stripping real
  `RuntimeError` messages.
  """
  @spec exception_parts(Exception.t(), pos_integer()) :: {String.t(), String.t() | nil}
  def exception_parts(exception, max_bytes \\ 500)

  def exception_parts(%RuntimeError{message: msg}, max_bytes)
      when is_binary(msg) and is_integer(max_bytes) and max_bytes > 0 do
    {"RuntimeError", cap_bytes(msg, max_bytes)}
  end

  def exception_parts(%ArgumentError{message: "argument error"}, _max_bytes) do
    {"ArgumentError", "argument error"}
  end

  def exception_parts(%KeyError{key: key}, _max_bytes) when is_atom(key) do
    {"KeyError", "key #{inspect(key)} not found"}
  end

  def exception_parts(%mod{}, _max_bytes), do: {inspect(mod), nil}

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
  Returns a bounded, value-safe outer shape summary for error messages on
  untrusted or potentially secret-bearing terms (provider tuples, config
  options, middleware return values). Only atoms, floats, and integers with
  `abs(n) <= 10^15` are printed verbatim; strings and compound structures are
  reduced to type labels while preserving atom tags on 2/3-tuples and the first
  element's shape on non-atom 2-tuples (`{first_shape, ...}`) up to a fixed
  depth cap.
  """
  @spec shape_summary(term()) :: String.t()
  def shape_summary(term) do
    term |> do_shape_summary(2) |> cap_bytes(@default_max_inspect_bytes)
  end

  defp do_shape_summary({tag, val}, depth) when is_atom(tag) and depth > 0,
    do: "{#{inspect(tag)}, #{do_shape_summary(val, depth - 1)}}"

  defp do_shape_summary({tag, val1, val2}, depth) when is_atom(tag) and depth > 0,
    do:
      "{#{inspect(tag)}, #{do_shape_summary(val1, depth - 1)}, #{do_shape_summary(val2, depth - 1)}}"

  defp do_shape_summary({first, _second}, depth) when depth > 0,
    do: "{#{do_shape_summary(first, depth - 1)}, ...}"

  defp do_shape_summary(v, _depth) when is_atom(v) or is_float(v), do: inspect(v)

  defp do_shape_summary(v, _depth) when is_integer(v) and abs(v) <= 1_000_000_000_000_000,
    do: inspect(v)

  defp do_shape_summary(v, _depth) when is_integer(v), do: "integer"
  defp do_shape_summary(v, _depth) when is_binary(v), do: "string"
  defp do_shape_summary(%mod{}, _depth), do: "%#{inspect(mod)}{}"
  defp do_shape_summary(v, _depth) when is_map(v), do: "map"
  defp do_shape_summary(v, _depth) when is_list(v), do: "list"
  defp do_shape_summary(v, _depth) when is_tuple(v), do: "tuple"
  defp do_shape_summary(_other, _depth), do: "term"

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
