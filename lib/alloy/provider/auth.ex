defmodule Alloy.Provider.Auth do
  @moduledoc false
  # Shared provider authentication helpers: static and dynamic :api_key
  # resolution (with secret-safe byte validation and bounded worker execution),
  # :auth_scheme validation, and auth header formatting.

  alias Alloy.Internal.Sanitize
  alias Alloy.OwnedWorker
  alias Alloy.Provider.{Error, HTTP}

  @allowed_callback_error_kinds [
    :auth,
    :cancelled,
    :timeout,
    :rate_limited,
    :overloaded,
    :server_error,
    :network,
    :invalid_request,
    :quota
  ]

  @spec resolve_api_key(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve_api_key(config) when is_map(config) do
    case Map.get(config, :api_key) do
      key when is_binary(key) ->
        validate_api_key_bytes(key)

      fun when is_function(fun, 0) ->
        resolve_api_key_callback(
          fun,
          Map.get(config, :alloy_request_deadline),
          Map.get(config, :alloy_cancel_token)
        )

      nil ->
        {:error, %Error{kind: :auth, message: "Missing :api_key in provider config"}}

      other ->
        {:error,
         %Error{
           kind: :auth,
           message: "Invalid :api_key in provider config: #{Sanitize.shape_summary(other)}"
         }}
    end
  end

  @spec resolve_optional_api_key(map()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def resolve_optional_api_key(config) when is_map(config) do
    case Map.get(config, :api_key) do
      nil -> {:ok, nil}
      _present -> resolve_api_key(config)
    end
  end

  @spec resolve_auth_scheme(map()) :: {:ok, :api_key | :bearer} | {:error, Error.t()}
  def resolve_auth_scheme(config) when is_map(config) do
    case Map.get(config, :auth_scheme, :api_key) do
      scheme when scheme in [:api_key, :bearer] ->
        {:ok, scheme}

      other ->
        {:error,
         %Error{
           kind: :invalid_request,
           message:
             "Invalid :auth_scheme: expected :api_key or :bearer, got #{Sanitize.shape_summary(other)}"
         }}
    end
  end

  @spec auth_header(String.t(), :api_key | :bearer, String.t()) :: {String.t(), String.t()}
  def auth_header(api_key, :bearer, _api_key_header) when is_binary(api_key) do
    {"authorization", "Bearer #{api_key}"}
  end

  def auth_header(api_key, :api_key, api_key_header)
      when is_binary(api_key) and is_binary(api_key_header) do
    {api_key_header, api_key}
  end

  defp validate_api_key_bytes(key) do
    if contains_invalid_header_byte?(key) do
      {:error,
       %Error{
         kind: :auth,
         message: "Invalid :api_key: contains non-ASCII or control bytes"
       }}
    else
      {:ok, key}
    end
  end

  # Mint's HTTP/1 encoder rejects bytes outside printable ASCII (0x20..0x7E)
  # with {:invalid_header_value, name, value}; reject them upfront so secrets
  # can never leak into transport error messages.
  defp contains_invalid_header_byte?(<<>>), do: false
  defp contains_invalid_header_byte?(<<b, _rest::binary>>) when b < 0x20 or b >= 0x7F, do: true

  defp contains_invalid_header_byte?(<<_b, rest::binary>>),
    do: contains_invalid_header_byte?(rest)

  defp resolve_api_key_callback(fun, deadline, cancel_token)
       when is_integer(deadline) or not is_nil(cancel_token) do
    case HTTP.run_managed(deadline, cancel_token, fn -> invoke_api_key_callback(fun) end) do
      {:ok, result} ->
        HTTP.maybe_override_cancelled(
          result,
          cancel_token,
          "Request cancelled while resolving :api_key"
        )

      :cancelled ->
        HTTP.cancelled_error("Request cancelled while resolving :api_key")

      :expired ->
        {:error,
         %Error{kind: :timeout, message: "Request exceeded deadline while resolving :api_key"}}

      {:shutdown, _reason} ->
        HTTP.shutdown_error()

      {:worker_exit, reason} ->
        {:error,
         %Error{
           kind: :auth,
           message: "Dynamic :api_key callback exited: #{OwnedWorker.format_exit_reason(reason)}"
         }}

      :timeout ->
        {:error,
         %Error{
           kind: :timeout,
           message: "Dynamic :api_key callback exceeded request deadline"
         }}
    end
  end

  defp resolve_api_key_callback(fun, _no_deadline, nil), do: invoke_api_key_callback(fun)

  defp invoke_api_key_callback(fun) do
    case fun.() do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        validate_api_key_bytes(key)

      key when is_binary(key) and byte_size(key) > 0 ->
        validate_api_key_bytes(key)

      {:error, %Error{} = err} ->
        safe_kind = if err.kind in @allowed_callback_error_kinds, do: err.kind, else: :auth
        safe_status = if is_integer(err.status) and err.status > 0, do: err.status, else: nil

        safe_retry_after =
          if is_integer(err.retry_after_ms) and err.retry_after_ms >= 0,
            do: err.retry_after_ms,
            else: nil

        {:error,
         %Error{
           kind: safe_kind,
           status: safe_status,
           retry_after_ms: safe_retry_after,
           message: "Dynamic :api_key callback failed (#{safe_kind})"
         }}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :auth,
           message: "Dynamic :api_key callback failed: #{Sanitize.shape_summary(reason)}"
         }}

      other ->
        {:error,
         %Error{
           kind: :auth,
           message:
             "Dynamic :api_key callback returned invalid value: #{Sanitize.shape_summary(other)}"
         }}
    end
  rescue
    exception ->
      {:error,
       %Error{
         kind: :auth,
         message: "Dynamic :api_key callback raised: #{inspect(exception.__struct__)}"
       }}
  catch
    kind, reason ->
      {:error,
       %Error{
         kind: :auth,
         message: "Dynamic :api_key callback #{kind}: #{Sanitize.exit_summary(reason, :redact)}"
       }}
  end
end
