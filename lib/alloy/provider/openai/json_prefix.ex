defmodule Alloy.Provider.OpenAI.JSONPrefix do
  @moduledoc false
  # Token-level RFC 8259 / IEEE-754 JSON prefix completer for OpenAI Responses
  # streaming function-call argument reconciliation. Preserves already-emitted
  # whitespace, map key order, string escapes (\uXXXX, \/, etc.), and numeric
  # spellings (e.g. 1e2) while verifying that the completed JSON decodes to the
  # expected value.

  @json_number_prefix_re ~r/^-?(?:(?:0|[1-9][0-9]*)(?:\.(?:[0-9]+(?:[eE][+-]?[0-9]*)?)?|[eE][+-]?[0-9]*)?)?$/

  # Attempts to compute a suffix such that `emitted <> suffix` is valid JSON
  # decoding to `expected_input`. Returns `{:ok, suffix, combined}` or
  # `:conflict`.
  @spec reconcile(String.t(), term()) :: {:ok, String.t(), String.t()} | :conflict
  def reconcile(emitted, expected_input) when is_binary(emitted) do
    with {:ok, suffix} <- complete(expected_input, emitted),
         combined = emitted <> suffix,
         {:ok, decoded} <- Jason.decode(combined),
         true <- decoded == expected_input do
      {:ok, suffix, combined}
    else
      _ -> :conflict
    end
  end

  # Computes a JSON completion suffix for `prefix` against `expected`, or
  # `:error` when `prefix` cannot be extended to `expected`.
  @spec complete(term(), String.t()) :: {:ok, String.t()} | :error
  def complete(expected, prefix) when is_binary(prefix) do
    case complete_value(expected, prefix) do
      {:suffix, suffix} -> {:ok, suffix}
      {:complete, rest} -> if skip_json_ws(rest) == <<>>, do: {:ok, ""}, else: :error
      :error -> :error
    end
  end

  defp complete_value(expected, prefix) do
    case skip_json_ws(prefix) do
      <<>> -> {:suffix, Jason.encode!(expected)}
      rest -> complete_non_empty_value(expected, rest)
    end
  end

  defp complete_non_empty_value(map, <<"{", rest::binary>>) when is_map(map),
    do: complete_map_entries(map, rest, false)

  defp complete_non_empty_value(list, <<"[", rest::binary>>) when is_list(list),
    do: complete_list_entries(list, rest, false)

  defp complete_non_empty_value(str, <<"\"", _::binary>> = rest) when is_binary(str) do
    case parse_json_string_prefix(rest) do
      {:complete, decoded, after_str} ->
        if decoded == str, do: {:complete, after_str}, else: :error

      {:partial, decoded_prefix, partial_escape} ->
        case complete_string_tail(str, decoded_prefix, partial_escape) do
          {:ok, tail} -> {:suffix, tail}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp complete_non_empty_value(num, rest) when is_number(num),
    do: complete_number_value(num, rest)

  defp complete_non_empty_value(val, rest) when is_boolean(val) or is_nil(val),
    do: complete_literal_value(val, rest)

  defp complete_non_empty_value(_expected, _rest), do: :error

  defp complete_map_entries(remaining, rest, expect_comma?) do
    case skip_json_ws(rest) do
      <<>> ->
        {:suffix, finish_map_suffix(remaining, expect_comma?)}

      <<"}", after_close::binary>> ->
        if map_size(remaining) == 0, do: {:complete, after_close}, else: :error

      <<",", after_comma::binary>> when expect_comma? ->
        complete_map_after_comma(remaining, after_comma)

      <<"\"", _::binary>> = str_start when not expect_comma? ->
        complete_map_key(remaining, str_start)

      _ ->
        :error
    end
  end

  defp finish_map_suffix(remaining, _expect_comma?) when map_size(remaining) == 0, do: "}"
  defp finish_map_suffix(remaining, true), do: "," <> encode_remaining_pairs(remaining) <> "}"
  defp finish_map_suffix(remaining, false), do: encode_remaining_pairs(remaining) <> "}"

  defp complete_map_after_comma(remaining, after_comma) do
    case skip_json_ws(after_comma) do
      <<>> when map_size(remaining) == 0 -> :error
      <<>> -> {:suffix, encode_remaining_pairs(remaining) <> "}"}
      <<"\"", _::binary>> = str_start -> complete_map_key(remaining, str_start)
      _ -> :error
    end
  end

  defp complete_map_key(remaining, str_start) do
    case parse_json_string_prefix(str_start) do
      {:complete, key, after_key} ->
        complete_map_key_value(remaining, key, after_key)

      {:partial, decoded_prefix, partial_escape} ->
        complete_partial_map_key(remaining, decoded_prefix, partial_escape)

      :error ->
        :error
    end
  end

  defp complete_map_key_value(remaining, key, after_key) do
    case Map.fetch(remaining, key) do
      :error ->
        :error

      {:ok, val} ->
        next_remaining = Map.delete(remaining, key)

        case skip_json_ws(after_key) do
          <<>> ->
            {:suffix, ":" <> Jason.encode!(val) <> close_remaining_map(next_remaining)}

          <<":", after_colon::binary>> ->
            complete_map_after_colon(val, after_colon, next_remaining)

          _ ->
            :error
        end
    end
  end

  defp complete_map_after_colon(val, after_colon, next_remaining) do
    case complete_value(val, after_colon) do
      {:complete, after_val} ->
        complete_map_entries(next_remaining, after_val, true)

      {:suffix, val_suffix} ->
        {:suffix, val_suffix <> close_remaining_map(next_remaining)}

      :error ->
        :error
    end
  end

  defp complete_partial_map_key(remaining, decoded_prefix, partial_escape) do
    Enum.find_value(remaining, :error, fn {key, val} ->
      case complete_string_tail(key, decoded_prefix, partial_escape) do
        {:ok, key_suffix} ->
          next_remaining = Map.delete(remaining, key)

          {:suffix,
           key_suffix <> ":" <> Jason.encode!(val) <> close_remaining_map(next_remaining)}

        :error ->
          nil
      end
    end)
  end

  defp close_remaining_map(remaining) when map_size(remaining) == 0, do: "}"
  defp close_remaining_map(remaining), do: "," <> encode_remaining_pairs(remaining) <> "}"

  defp encode_remaining_pairs(remaining) do
    Enum.map_join(remaining, ",", fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end)
  end

  defp complete_list_entries(remaining, rest, expect_comma?) do
    case skip_json_ws(rest) do
      <<>> ->
        {:suffix, finish_list_suffix(remaining, expect_comma?)}

      <<"]", after_close::binary>> ->
        if remaining == [], do: {:complete, after_close}, else: :error

      <<",", after_comma::binary>> when expect_comma? ->
        complete_list_after_comma(remaining, after_comma)

      val_start when not expect_comma? ->
        complete_list_head(remaining, val_start)

      _ ->
        :error
    end
  end

  defp finish_list_suffix([], _expect_comma?), do: "]"

  defp finish_list_suffix(remaining, true),
    do: "," <> Enum.map_join(remaining, ",", &Jason.encode!/1) <> "]"

  defp finish_list_suffix(remaining, false),
    do: Enum.map_join(remaining, ",", &Jason.encode!/1) <> "]"

  defp complete_list_after_comma([], _after_comma), do: :error

  defp complete_list_after_comma(remaining, after_comma) do
    case skip_json_ws(after_comma) do
      <<>> -> {:suffix, Enum.map_join(remaining, ",", &Jason.encode!/1) <> "]"}
      val_start -> complete_list_head(remaining, val_start)
    end
  end

  defp complete_list_head([], _val_start), do: :error

  defp complete_list_head([head | tail], val_start) do
    case complete_value(head, val_start) do
      {:complete, after_head} ->
        complete_list_entries(tail, after_head, true)

      {:suffix, head_suffix} ->
        rest_tail =
          if tail == [],
            do: "]",
            else: "," <> Enum.map_join(tail, ",", &Jason.encode!/1) <> "]"

        {:suffix, head_suffix <> rest_tail}

      :error ->
        :error
    end
  end

  defp complete_number_value(expected, rest) do
    {token, after_token} = take_number_token(rest, 0)

    cond do
      token == "" ->
        :error

      after_token != "" ->
        case Jason.decode(token) do
          {:ok, num} when is_number(num) and num == expected -> {:complete, after_token}
          _ -> :error
        end

      true ->
        complete_number_token(token, expected)
    end
  end

  defp complete_number_token(token, expected) do
    if Regex.match?(@json_number_prefix_re, token) do
      cond do
        match?({:ok, num} when is_number(num) and num == expected, Jason.decode(token)) ->
          {:suffix, ""}

        String.contains?(token, ["e", "E"]) ->
          complete_exponent_number(token, expected)

        true ->
          complete_mantissa_token(token, expected)
      end
    else
      :error
    end
  end

  defp complete_mantissa_token("-", expected) when expected == 0, do: {:suffix, "0"}

  defp complete_mantissa_token("-", expected) when expected < 0 do
    encoded = Jason.encode!(expected)
    {:suffix, binary_part(encoded, 1, byte_size(encoded) - 1)}
  end

  defp complete_mantissa_token("-", _expected), do: :error

  defp complete_mantissa_token(token, expected) do
    with :error <- try_decimal_prefix_completion(token, expected),
         :error <- try_direct_exponent_completion(token, expected),
         :error <- try_mantissa_exponent_completion(token, expected) do
      try_rounding_boundary_completion(token, expected)
    end
  end

  # Handles IEEE-754 rounding-equivalent decimal prefixes whose lower or upper
  # digit boundary rounds to `expected` (e.g. "9007199254740993." -> 9007199254740992.0
  # or "0.29" from "0.29999999999999999" -> 0.3).
  defp try_rounding_boundary_completion(token, expected) do
    nines = String.duplicate("9", 20)

    tails =
      cond do
        String.contains?(token, ".") -> ["0", nines]
        is_float(expected) -> [".0", "." <> nines]
        true -> []
      end

    Enum.find_value(tails, :error, &try_boundary_tail(token, &1, expected))
  end

  defp try_boundary_tail(token, tail, expected) do
    candidate = token <> tail

    case Jason.decode(candidate) do
      {:ok, num} when is_number(num) and num == expected ->
        {:suffix, tail}

      _ when expected !== 0 ->
        case complete_exponent_number(candidate <> "e", expected) do
          {:suffix, exp_tail} -> {:suffix, tail <> "e" <> exp_tail}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp try_decimal_prefix_completion(token, expected) do
    Enum.find_value(decimal_candidates(expected), :error, fn full ->
      if String.starts_with?(full, token) do
        tail = binary_part(full, byte_size(token), byte_size(full) - byte_size(token))

        case Jason.decode(token <> tail) do
          {:ok, num} when is_number(num) and num == expected -> {:suffix, tail}
          _ -> nil
        end
      end
    end)
  end

  defp decimal_candidates(0), do: ["0", "0.0", "-0", "-0.0"]

  defp decimal_candidates(n) when is_integer(n) do
    s = Integer.to_string(n)
    [s, s <> ".0"]
  end

  defp decimal_candidates(f) when is_float(f) do
    base = [Jason.encode!(f) | fixed_decimal_strings(f)]
    if f == 0.0, do: base ++ ["-0", "-0.0"], else: base
  end

  defp fixed_decimal_strings(float) when is_float(float) do
    {neg?, sig, exp} = parse_short_float(:erlang.float_to_binary(float, [:short]))
    sign = if neg?, do: "-", else: ""

    cond do
      exp >= 0 and exp <= 350 ->
        whole = sign <> sig <> String.duplicate("0", exp)
        [whole, whole <> ".0"]

      exp < 0 and -exp <= 350 ->
        len = byte_size(sig)
        dot_pos = len + exp

        fixed =
          if dot_pos > 0 do
            sign <>
              binary_part(sig, 0, dot_pos) <>
              "." <> binary_part(sig, dot_pos, len - dot_pos)
          else
            sign <> "0." <> String.duplicate("0", -dot_pos) <> sig
          end

        [fixed]

      true ->
        []
    end
  end

  defp parse_short_float(short) do
    {neg?, rest} =
      case short do
        <<"-", tail::binary>> -> {true, tail}
        tail -> {false, tail}
      end

    {mantissa, exp} =
      case String.split(rest, ["e", "E"], parts: 2) do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {digits, frac_len} =
      case String.split(mantissa, ".", parts: 2) do
        [i, f] -> {i <> f, byte_size(f)}
        [i] -> {i, 0}
      end

    trimmed = String.trim_trailing(digits, "0")
    trailing_zeros = byte_size(digits) - byte_size(trimmed)
    sig = trimmed |> String.trim_leading("0")
    sig = if sig == "", do: "0", else: sig
    {neg?, sig, exp - frac_len + trailing_zeros}
  end

  defp try_direct_exponent_completion(_token, 0), do: :error

  defp try_direct_exponent_completion(token, expected) do
    if String.ends_with?(token, ".") do
      :error
    else
      case complete_exponent_number(token <> "e", expected) do
        {:suffix, exp_tail} -> {:suffix, "e" <> exp_tail}
        :error -> :error
      end
    end
  end

  defp try_mantissa_exponent_completion(_token, expected) when expected == 0, do: :error

  defp try_mantissa_exponent_completion(token, expected) do
    neg_token? = String.starts_with?(token, "-")

    if neg_token? == expected < 0 do
      expected_sig = expected_sig_digits(expected)
      token_sig = token |> String.replace(["-", "."], "") |> String.trim_leading("0")

      if String.starts_with?(expected_sig, token_sig) do
        rem_digits =
          binary_part(
            expected_sig,
            byte_size(token_sig),
            byte_size(expected_sig) - byte_size(token_sig)
          )

        complete_remaining_mantissa(token, rem_digits, expected)
      else
        :error
      end
    else
      :error
    end
  end

  defp complete_remaining_mantissa(_token, "", _expected), do: :error

  defp complete_remaining_mantissa(token, rem_digits, expected) do
    mantissa_tail = if token in ["0", "-0"], do: "." <> rem_digits, else: rem_digits
    full_mantissa = token <> mantissa_tail

    case Jason.decode(full_mantissa) do
      {:ok, num} when is_number(num) and num == expected ->
        {:suffix, mantissa_tail}

      _ ->
        case complete_exponent_number(full_mantissa <> "e", expected) do
          {:suffix, exp_tail} -> {:suffix, mantissa_tail <> "e" <> exp_tail}
          :error -> :error
        end
    end
  end

  defp expected_sig_digits(n) when is_integer(n) do
    n |> abs() |> Integer.to_string() |> String.trim_trailing("0")
  end

  defp expected_sig_digits(f) when is_float(f) do
    {_neg?, sig, _exp} = parse_short_float(:erlang.float_to_binary(f, [:short]))
    sig
  end

  defp complete_exponent_number(token, expected) do
    case String.split(token, ["e", "E"], parts: 2) do
      [mantissa_str, exp_prefix] ->
        case Jason.decode(mantissa_str) do
          {:ok, mantissa} when is_number(mantissa) ->
            match_exponent_suffix(token, mantissa, exp_prefix, expected)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp match_exponent_suffix(_token, mantissa, exp_prefix, expected)
       when mantissa == 0 and expected == 0 do
    if exp_prefix in ["", "+", "-"], do: {:suffix, "0"}, else: :error
  end

  defp match_exponent_suffix(token, mantissa, exp_prefix, expected)
       when mantissa != 0 and expected == 0 do
    with {:ok, tail} <- underflow_exponent_suffix(exp_prefix, byte_size(token)),
         {:ok, num} when is_number(num) and num == expected <- Jason.decode(token <> tail) do
      {:suffix, tail}
    else
      _ -> :error
    end
  end

  defp match_exponent_suffix(token, mantissa, exp_prefix, expected)
       when mantissa != 0 and expected != 0 do
    with true <- mantissa > 0 == expected > 0,
         {:ok, exp} <- safe_log10_exponent(expected, mantissa),
         {:ok, tail} <- complete_exponent_prefix(exp_prefix, exp),
         {:ok, num} when is_number(num) and num == expected <- Jason.decode(token <> tail) do
      {:suffix, tail}
    else
      _ -> :error
    end
  end

  defp match_exponent_suffix(_token, _mantissa, _exp_prefix, _expected), do: :error

  defp underflow_exponent_suffix("", token_len),
    do: {:ok, "-" <> Integer.to_string(token_len + 400)}

  defp underflow_exponent_suffix(<<?-, digits::binary>>, token_len) do
    if all_digits?(digits) do
      if String.trim_leading(digits, "0") == "" do
        {:ok, Integer.to_string(token_len + 400)}
      else
        {:ok, if(token_len > 300, do: "0000", else: "000")}
      end
    else
      :error
    end
  end

  defp underflow_exponent_suffix(_exp_prefix, _token_len), do: :error

  # Compute log10(|expected| / |mantissa|) as log10(|expected|) - log10(|mantissa|)
  # so large values like 1.0e308 / 0.1 never overflow IEEE-754 before log10 runs.
  defp safe_log10_exponent(expected, mantissa) do
    {:ok, round(:math.log10(abs(expected)) - :math.log10(abs(mantissa)))}
  rescue
    ArithmeticError -> :error
  end

  defp complete_exponent_prefix("", exp), do: {:ok, Integer.to_string(exp)}

  defp complete_exponent_prefix(<<?+, digits::binary>>, exp) when exp >= 0,
    do: complete_exponent_digits(digits, exp)

  defp complete_exponent_prefix(<<?-, digits::binary>>, exp) when exp <= 0,
    do: complete_exponent_digits(digits, abs(exp))

  defp complete_exponent_prefix(digits, exp) when exp >= 0,
    do: complete_exponent_digits(digits, exp)

  defp complete_exponent_prefix(_exp_prefix, _exp), do: :error

  defp complete_exponent_digits(digits, abs_exp) do
    if all_digits?(digits) do
      trimmed = String.trim_leading(digits, "0")
      abs_str = Integer.to_string(abs_exp)

      if String.starts_with?(abs_str, trimmed) do
        {:ok, binary_part(abs_str, byte_size(trimmed), byte_size(abs_str) - byte_size(trimmed))}
      else
        :error
      end
    else
      :error
    end
  end

  defp all_digits?(<<>>), do: true
  defp all_digits?(<<c, rest::binary>>) when c in ?0..?9, do: all_digits?(rest)
  defp all_digits?(_), do: false

  defp take_number_token(bin, len) do
    case bin do
      <<_::binary-size(^len), c, _::binary>>
      when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E] ->
        take_number_token(bin, len + 1)

      _ ->
        {binary_part(bin, 0, len), binary_part(bin, len, byte_size(bin) - len)}
    end
  end

  defp complete_literal_value(val, rest) do
    encoded = Jason.encode!(val)
    {token, after_token} = take_alpha_token(rest, 0)

    cond do
      token == "" ->
        :error

      after_token != "" ->
        if token == encoded, do: {:complete, after_token}, else: :error

      String.starts_with?(encoded, token) ->
        {:suffix, binary_part(encoded, byte_size(token), byte_size(encoded) - byte_size(token))}

      true ->
        :error
    end
  end

  defp take_alpha_token(bin, len) do
    case bin do
      <<_::binary-size(^len), c, _::binary>> when c in ?a..?z ->
        take_alpha_token(bin, len + 1)

      _ ->
        {binary_part(bin, 0, len), binary_part(bin, len, byte_size(bin) - len)}
    end
  end

  defp parse_json_string_prefix(<<"\"", rest::binary>>), do: scan_string_prefix(rest, [])

  defp scan_string_prefix(<<>>, acc), do: {:partial, IO.iodata_to_binary(acc), ""}

  defp scan_string_prefix(<<"\"", after_str::binary>>, acc),
    do: {:complete, IO.iodata_to_binary(acc), after_str}

  defp scan_string_prefix(<<"\\", after_bs::binary>>, acc),
    do: scan_string_escape(after_bs, acc)

  defp scan_string_prefix(<<c::utf8, tail::binary>>, acc) when c >= 0x20,
    do: scan_string_prefix(tail, [acc, <<c::utf8>>])

  defp scan_string_prefix(_invalid, _acc), do: :error

  defp scan_string_escape(<<>>, acc), do: {:partial, IO.iodata_to_binary(acc), "\\"}
  defp scan_string_escape(<<"\"", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\""])
  defp scan_string_escape(<<"\\", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\\"])
  defp scan_string_escape(<<"/", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "/"])
  defp scan_string_escape(<<"b", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\b"])
  defp scan_string_escape(<<"f", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\f"])
  defp scan_string_escape(<<"n", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\n"])
  defp scan_string_escape(<<"r", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\r"])
  defp scan_string_escape(<<"t", tail::binary>>, acc), do: scan_string_prefix(tail, [acc, "\t"])

  defp scan_string_escape(<<"u", hex_rest::binary>>, acc),
    do: scan_unicode_escape(hex_rest, acc)

  defp scan_string_escape(_invalid, _acc), do: :error

  defp scan_unicode_escape(hex_rest, acc) when byte_size(hex_rest) < 4 do
    if all_hex?(hex_rest),
      do: {:partial, IO.iodata_to_binary(acc), "\\u" <> hex_rest},
      else: :error
  end

  defp scan_unicode_escape(<<hex::binary-size(4), tail::binary>>, acc) do
    case parse_hex4(hex) do
      {:ok, hi} when hi in 0xD800..0xDBFF ->
        scan_surrogate_low(hex, hi, tail, acc)

      {:ok, lo} when lo in 0xDC00..0xDFFF ->
        :error

      {:ok, cp} ->
        scan_string_prefix(tail, [acc, <<cp::utf8>>])

      :error ->
        :error
    end
  end

  defp scan_surrogate_low(hi_hex, _hi, <<>>, acc),
    do: {:partial, IO.iodata_to_binary(acc), "\\u" <> hi_hex}

  defp scan_surrogate_low(hi_hex, _hi, <<"\\">>, acc),
    do: {:partial, IO.iodata_to_binary(acc), "\\u" <> hi_hex <> "\\"}

  defp scan_surrogate_low(hi_hex, _hi, <<"\\u", low_partial::binary>>, acc)
       when byte_size(low_partial) < 4 do
    if all_hex?(low_partial),
      do: {:partial, IO.iodata_to_binary(acc), "\\u" <> hi_hex <> "\\u" <> low_partial},
      else: :error
  end

  defp scan_surrogate_low(_hi_hex, hi, <<"\\u", lo_hex::binary-size(4), tail::binary>>, acc) do
    case parse_hex4(lo_hex) do
      {:ok, lo} when lo in 0xDC00..0xDFFF ->
        cp = 0x10000 + Bitwise.bsl(hi - 0xD800, 10) + (lo - 0xDC00)
        scan_string_prefix(tail, [acc, <<cp::utf8>>])

      _ ->
        :error
    end
  end

  defp scan_surrogate_low(_hi_hex, _hi, _tail, _acc), do: :error

  defp complete_string_tail(expected, decoded_prefix, partial_escape) do
    if String.starts_with?(expected, decoded_prefix) do
      prefix_len = byte_size(decoded_prefix)
      rem_str = binary_part(expected, prefix_len, byte_size(expected) - prefix_len)
      complete_remaining_string(rem_str, partial_escape)
    else
      :error
    end
  end

  defp complete_remaining_string(rem_str, ""),
    do: {:ok, encode_json_string_inner(rem_str) <> "\""}

  defp complete_remaining_string(<<>>, _partial_escape), do: :error

  defp complete_remaining_string(<<cp::utf8, rest_str::binary>>, "\\") do
    esc_tail =
      case cp do
        ?" ->
          "\""

        ?\\ ->
          "\\"

        ?/ ->
          "/"

        ?\b ->
          "b"

        ?\f ->
          "f"

        ?\n ->
          "n"

        ?\r ->
          "r"

        ?\t ->
          "t"

        _ ->
          esc = unicode_escape_for(cp)
          binary_part(esc, 1, byte_size(esc) - 1)
      end

    {:ok, esc_tail <> encode_json_string_inner(rest_str) <> "\""}
  end

  defp complete_remaining_string(<<cp::utf8, rest_str::binary>>, partial_escape) do
    full_esc = unicode_escape_for(cp)
    down = String.downcase(partial_escape)

    if String.starts_with?(full_esc, down) do
      esc_tail = binary_part(full_esc, byte_size(down), byte_size(full_esc) - byte_size(down))
      {:ok, esc_tail <> encode_json_string_inner(rest_str) <> "\""}
    else
      :error
    end
  end

  defp unicode_escape_for(cp) when cp <= 0xFFFF do
    "\\u" <> hex4(cp)
  end

  defp unicode_escape_for(cp) do
    offset = cp - 0x10000
    hi = 0xD800 + Bitwise.bsr(offset, 10)
    lo = 0xDC00 + Bitwise.band(offset, 0x3FF)
    "\\u" <> hex4(hi) <> "\\u" <> hex4(lo)
  end

  defp hex4(n) do
    n
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  defp all_hex?(<<>>), do: true

  defp all_hex?(<<c, rest::binary>>) when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
    do: all_hex?(rest)

  defp all_hex?(_), do: false

  defp parse_hex4(hex) do
    if all_hex?(hex), do: {:ok, String.to_integer(hex, 16)}, else: :error
  end

  defp encode_json_string_inner(str) do
    encoded = Jason.encode!(str)
    binary_part(encoded, 1, byte_size(encoded) - 2)
  end

  defp skip_json_ws(<<ws, rest::binary>>) when ws in [?\s, ?\t, ?\r, ?\n],
    do: skip_json_ws(rest)

  defp skip_json_ws(rest), do: rest
end
