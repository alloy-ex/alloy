defmodule Alloy.Provider.Error do
  @moduledoc """
  A provider failure with enough structure for the loop to act on it.

  The built-in HTTP providers return `{:error, %Alloy.Provider.Error{}}`. The
  loop reads `:kind` to decide whether to retry (`retryable?/1`), how long to
  wait (`:retry_after_ms`, from the `Retry-After` header), and whether to
  compact the conversation and try again (`:context_overflow`).

  Custom providers can return this struct to get the same behaviour; plain
  string errors keep working.

  `Alloy.Result.error` stays a string — `Exception.message/1` of this struct,
  in the same `"<type>: <message>"` / `"HTTP <status>: <body>"` shape earlier
  versions returned — and the struct itself is available as
  `result.metadata.run.provider_error`. It also implements `String.Chars`, so
  interpolating it keeps working.

  ## Kinds

    * retried: `:rate_limited`, `:overloaded`, `:server_error`, `:timeout`,
      `:network`, `:malformed_reply` (transient garbled/truncated JSON,
      undecodable SSE frames, or invalid model tool-call argument JSON; retries
      only run before any stream output is emitted and are bounded by
      `:max_retries`)
    * not retried: `:context_overflow` (the loop compacts once instead),
      `:protocol_error` (valid JSON that violates the provider wire schema —
      non-object top-level responses, malformed choices/candidates/blocks,
      missing required tool-call `id`/`name`, or mismatched SSE event deltas),
      `:quota` (billing or spend limit), `:auth`, `:invalid_request`,
      `:session_uncertain` (a persisted CLI turn may have been recorded),
      `:shutdown` (interrupted by supervisor shutdown; skips retries and
      fallbacks — on a resumed Codex session, also rotate `:session_generation`),
      `:cancelled` (interrupted cooperatively via `Alloy.Cancel`; skips retries
      and fallbacks — on a resumed Codex session, also rotate `:session_generation`),
      `:unknown`
  """

  alias Alloy.Internal.Sanitize

  @type kind ::
          :rate_limited
          | :overloaded
          | :server_error
          | :timeout
          | :network
          | :malformed_reply
          | :protocol_error
          | :session_uncertain
          | :context_overflow
          | :quota
          | :auth
          | :invalid_request
          | :shutdown
          | :cancelled
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          status: pos_integer() | nil,
          type: String.t() | nil,
          code: String.t() | nil,
          retry_after_ms: non_neg_integer() | nil
        }

  defexception [:message, :status, :type, :code, :retry_after_ms, kind: :unknown]

  @retryable [:rate_limited, :overloaded, :server_error, :timeout, :network, :malformed_reply]

  # Error `code` or `type` values from Anthropic, OpenAI, Gemini and xAI.
  # Codes are checked before types because they are more specific (OpenAI
  # sends type "rate_limit_error" with code "slow_down" or a quota code).
  @kinds_by_label %{
    "rate_limit_error" => :rate_limited,
    "rate_limit_exceeded" => :rate_limited,
    "slow_down" => :rate_limited,
    "RESOURCE_EXHAUSTED" => :rate_limited,
    "overloaded_error" => :overloaded,
    "server_is_overloaded" => :overloaded,
    "service_unavailable_error" => :overloaded,
    "UNAVAILABLE" => :overloaded,
    "timeout_error" => :timeout,
    "DEADLINE_EXCEEDED" => :timeout,
    "api_error" => :server_error,
    "server_error" => :server_error,
    "INTERNAL" => :server_error,
    "authentication_error" => :auth,
    "permission_error" => :auth,
    "UNAUTHENTICATED" => :auth,
    "PERMISSION_DENIED" => :auth
  }

  @quota_labels ~w(insufficient_quota billing_hard_limit_reached credit_balance_exhausted subscription_sharing_usage_limit_exceeded)

  @overflow_phrases [
    "prompt is too long",
    "context_length_exceeded",
    "maximum context length",
    "context window",
    "exceeds the maximum number of tokens",
    "maximum prompt length"
  ]

  @impl Exception
  def message(%__MODULE__{type: type, message: message}) when is_binary(type),
    do: "#{type}: #{message}"

  def message(%__MODULE__{status: status, message: message}) when is_integer(status),
    do: "HTTP #{status}: #{message}"

  def message(%__MODULE__{message: message}), do: message

  @doc false
  # For string errors from custom providers, which carry no :kind.
  @spec overflow_text?(String.t()) :: boolean()
  def overflow_text?(text) when is_binary(text), do: overflow?(nil, text)

  @doc "Whether the loop should retry after this error."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{kind: kind}), do: kind in @retryable

  @doc """
  Builds an error from a non-success HTTP response.

  Reads the error body shapes used by Anthropic (`{"error": {"type", ...}}`),
  OpenAI (`{"error": {"type", "code", ...}}`), Gemini
  (`{"error": {"status", ...}}`, sometimes wrapped in a list) and most
  OpenAI-compatible servers. `headers` may be Req's header map or a list of
  `{name, value}` tuples.
  """
  @spec from_response(pos_integer(), map() | [{String.t(), String.t()}], term()) :: t()
  def from_response(status, headers, body) do
    {type, code, raw_message, stored_message} = body |> decode() |> fields()

    %__MODULE__{
      kind: classify(status, type, code, raw_message),
      status: status,
      type: type,
      code: code,
      message: stored_message,
      retry_after_ms: retry_after_ms(headers)
    }
  end

  @doc """
  Builds an error reported inside a successful HTTP response: a failed
  response object or an error event in an SSE stream. Accepts the body
  shapes `from_response/3` reads and classifies by code, type, and numeric
  HTTP status codes (`400..599`) carried in `error.code`.
  """
  @spec from_body(term()) :: t()
  def from_body(body) do
    decoded = decode(body)
    {type, code, raw_message, stored_message} = fields(decoded)
    status = numeric_status(decoded)

    %__MODULE__{
      kind: classify(status, type, code, raw_message),
      status: status,
      type: type,
      code: code,
      message: stored_message
    }
  end

  # Assumes numeric error.code values in 400..599 represent HTTP statuses
  # (as used by Gemini and OpenRouter in-band 200 error payloads).
  defp numeric_status(%{"error" => %{"code" => status}})
       when is_integer(status) and status >= 400 and status <= 599,
       do: status

  defp numeric_status(%{"error" => %{"code" => status}}) when is_binary(status) do
    case Integer.parse(status) do
      {n, ""} when n >= 400 and n <= 599 -> n
      _ -> nil
    end
  end

  defp numeric_status([first | _]), do: numeric_status(first)
  defp numeric_status(_), do: nil

  @doc """
  Builds an error from a transport failure (connection refused, closed,
  timed out) reported by Req, Finch or Mint.
  """
  @spec from_transport(term()) :: t()
  def from_transport(reason) do
    detail = format_transport_reason(reason)

    %__MODULE__{
      kind: transport_kind(reason),
      message: "HTTP request failed: #{detail}"
    }
  end

  defp format_transport_reason({:invalid_header_value, name, _value}),
    do: "invalid HTTP header value for #{format_header_name(name)}"

  defp format_transport_reason(%{__struct__: mod, reason: {:invalid_header_value, name, _value}}),
    do: "#{inspect(mod)}: invalid HTTP header value for #{format_header_name(name)}"

  defp format_transport_reason(reason), do: Sanitize.inspect_bounded(reason)

  defp format_header_name(name) when is_binary(name), do: inspect(Sanitize.cap_bytes(name, 64))
  defp format_header_name(name), do: Sanitize.shape_summary(name)

  # ── Body parsing ──────────────────────────────────────────────────────────

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  defp fields(%{"error" => %{} = error}) do
    {raw, stored} =
      case label(error["message"]) do
        nil -> encode_error_fallback(error)
        msg -> {msg, Sanitize.cap_bytes(msg, 2_000)}
      end

    {label(error["type"]) || label(error["status"]), label(error["code"]), raw, stored}
  end

  defp fields(%{"error" => error}) when is_binary(error),
    do: {nil, nil, error, Sanitize.cap_bytes(error, 2_000)}

  defp fields([first | _]), do: fields(first)

  defp fields(body) when is_binary(body), do: {nil, nil, body, Sanitize.cap_bytes(body, 2_000)}

  defp fields(body) do
    {raw, stored} = encode_error_fallback(body)
    {nil, nil, raw, stored}
  end

  defp encode_error_fallback(term) do
    raw =
      case Jason.encode(term) do
        {:ok, json} -> json
        {:error, _} -> Sanitize.inspect_bounded(term)
      end

    {raw, Sanitize.cap_bytes(raw, 500)}
  end

  defp label(value) when is_binary(value) and value != "", do: value
  defp label(_value), do: nil

  # ── Classification ────────────────────────────────────────────────────────

  defp classify(status, type, code, message) do
    cond do
      status != 429 and (overflow_code?(code) or overflow_code?(type)) ->
        :context_overflow

      status != 429 and not server_status?(status) and overflow?(code, message) ->
        :context_overflow

      quota?(type) or quota?(code) ->
        :quota

      true ->
        Map.get(@kinds_by_label, code) || Map.get(@kinds_by_label, type) || by_status(status)
    end
  end

  defp overflow_code?("context_length_exceeded"), do: true
  defp overflow_code?(_), do: false

  defp server_status?(status) when is_integer(status) and status in 500..599, do: true
  defp server_status?(_), do: false

  # Bound the overflow scan to 64 KiB so multi-MB error bodies cannot allocate
  # large lowercased copies while still catching long proxy-wrapped errors.
  defp overflow?(code, message) do
    scanned = Sanitize.cap_bytes(message, 65_536)
    text = String.downcase("#{code} #{scanned}")
    Enum.any?(@overflow_phrases, &String.contains?(text, &1))
  end

  defp quota?(label) when is_binary(label),
    do: label in @quota_labels or String.ends_with?(label, "_spend_limit_exceeded")

  defp quota?(_label), do: false

  defp by_status(429), do: :rate_limited
  defp by_status(529), do: :overloaded
  defp by_status(status) when status in [408, 504], do: :timeout
  defp by_status(status) when status in 500..599, do: :server_error
  defp by_status(status) when status in [401, 403], do: :auth
  defp by_status(status) when status in 400..499, do: :invalid_request
  defp by_status(_status), do: :unknown

  defp transport_kind(%Jason.DecodeError{}), do: :malformed_reply
  defp transport_kind(%{reason: reason}), do: transport_kind(reason)
  defp transport_kind(reason) when reason in [:timeout, :connect_timeout], do: :timeout

  defp transport_kind(reason) when reason in [:econnrefused, :econnreset, :closed, :unprocessed],
    do: :network

  defp transport_kind(_reason), do: :unknown

  # ── Retry-After ───────────────────────────────────────────────────────────

  defp retry_after_ms(headers) do
    case {header(headers, "retry-after-ms"), header(headers, "retry-after")} do
      {ms, _} when is_binary(ms) ->
        parse_duration(ms, 1)

      {nil, value} when is_binary(value) ->
        parse_duration(value, 1_000) || parse_retry_date(value)

      _ ->
        nil
    end
  end

  defp parse_retry_date(value) do
    case http_date(String.trim(value)) do
      {:ok, datetime} -> max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 0)
      {:error, _reason} -> nil
    end
  end

  defp http_date(value) do
    pattern =
      ~r/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/

    case Regex.run(pattern, value) do
      [_full, day, month, year, time] ->
        month =
          Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == month)) + 1

        iso = "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}-#{day}T#{time}Z"

        case DateTime.from_iso8601(iso) do
          {:ok, datetime, 0} -> {:ok, datetime}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_format}
    end
  end

  defp parse_duration(value, scale) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> round(number * scale)
      _ -> nil
    end
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} -> String.downcase(key) == name && value end)
  end

  defp header(_headers, _name), do: nil

  defimpl String.Chars do
    @spec to_string(Alloy.Provider.Error.t()) :: String.t()
    def to_string(error), do: Exception.message(error)
  end
end
