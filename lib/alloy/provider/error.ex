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
      `:network`
    * not retried: `:context_overflow` (the loop compacts once instead),
      `:quota` (billing or spend limit), `:auth`, `:invalid_request`,
      `:unknown`
  """

  @type kind ::
          :rate_limited
          | :overloaded
          | :server_error
          | :timeout
          | :network
          | :context_overflow
          | :quota
          | :auth
          | :invalid_request
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

  @retryable [:rate_limited, :overloaded, :server_error, :timeout, :network]

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

  @quota_labels ~w(insufficient_quota billing_hard_limit_reached credit_balance_exhausted)

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
    {type, code, message} = body |> decode() |> fields()

    %__MODULE__{
      kind: classify(status, type, code, message),
      status: status,
      type: type,
      code: code,
      message: message,
      retry_after_ms: retry_after_ms(headers)
    }
  end

  @doc """
  Builds an error from a transport failure (connection refused, closed,
  timed out) reported by Req, Finch or Mint.
  """
  @spec from_transport(term()) :: t()
  def from_transport(reason) do
    %__MODULE__{
      kind: transport_kind(reason),
      message: "HTTP request failed: #{inspect(reason)}"
    }
  end

  # ── Body parsing ──────────────────────────────────────────────────────────

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  defp fields(%{"error" => %{} = error}) do
    {
      label(error["type"] || error["status"]),
      label(error["code"]),
      label(error["message"]) || Jason.encode!(error)
    }
  end

  defp fields(%{"error" => error}) when is_binary(error), do: {nil, nil, error}
  defp fields([first | _]), do: fields(first)
  defp fields(body) when is_binary(body), do: {nil, nil, body}
  defp fields(body), do: {nil, nil, inspect(body)}

  defp label(value) when is_binary(value) and value != "", do: value
  defp label(_value), do: nil

  # ── Classification ────────────────────────────────────────────────────────

  defp classify(status, type, code, message) do
    cond do
      status != 429 and overflow?(code, message) ->
        :context_overflow

      quota?(type) or quota?(code) ->
        :quota

      true ->
        Map.get(@kinds_by_label, code) || Map.get(@kinds_by_label, type) || by_status(status)
    end
  end

  defp overflow?(code, message) do
    text = String.downcase("#{code} #{message}")
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

  defp transport_kind(%{reason: reason}), do: transport_kind(reason)
  defp transport_kind(reason) when reason in [:timeout, :connect_timeout], do: :timeout

  defp transport_kind(reason) when reason in [:econnrefused, :econnreset, :closed, :unprocessed],
    do: :network

  defp transport_kind(_reason), do: :unknown

  # ── Retry-After ───────────────────────────────────────────────────────────

  # OpenAI sends `retry-after-ms`; everyone else sends `retry-after` in
  # seconds. The HTTP-date form is ignored, so normal backoff applies.
  defp retry_after_ms(headers) do
    case {header(headers, "retry-after-ms"), header(headers, "retry-after")} do
      {ms, _} when is_binary(ms) -> parse_duration(ms, 1)
      {nil, seconds} when is_binary(seconds) -> parse_duration(seconds, 1_000)
      _ -> nil
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
