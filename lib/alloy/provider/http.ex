defmodule Alloy.Provider.HTTP do
  @moduledoc false
  # Request plumbing shared by the built-in HTTP providers: the JSON POST,
  # Req's own retries switched off (Alloy.Provider.Retry owns retries and the
  # turn deadline), and every failure turned into an Alloy.Provider.Error.

  alias Alloy.Provider.{Error, SSE}

  @type headers :: [{String.t(), String.t()}]

  @doc """
  POSTs `body` as JSON. Returns the decoded body of a 200 response.
  """
  @spec post_json(String.t(), headers(), map(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_json(url, headers, body, req_options) do
    case request(url, headers, body, req_options) do
      {:ok, %{status: 200, body: resp_body}} -> {:ok, resp_body}
      {:ok, resp} -> {:error, Error.from_response(resp.status, resp.headers, resp.body)}
      {:error, reason} -> {:error, Error.from_transport(reason)}
    end
  end

  @doc """
  POSTs `body` as JSON and feeds the SSE response through `handle_event`
  (see `Alloy.Provider.SSE.req_stream_handler/2`). Returns the final
  accumulator of a 200 response.

  `req_options` may carry extra Req options such as `params:`.
  """
  @spec stream_sse(
          String.t(),
          headers(),
          map(),
          map(),
          (map(), SSE.sse_event() -> map()),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def stream_sse(url, headers, body, initial_acc, handle_event, req_options) do
    handler = SSE.req_stream_handler(initial_acc, handle_event)

    case request(url, headers, body, [into: handler] ++ req_options) do
      {:ok, %{status: 200} = resp} ->
        {:ok, Map.get(resp.private, :sse_acc, initial_acc)}

      {:ok, resp} ->
        {:error, Error.from_response(resp.status, resp.headers, error_body(resp, initial_acc))}

      {:error, reason} ->
        {:error, Error.from_transport(reason)}
    end
  end

  defp request(url, headers, body, req_options) do
    [url: url, method: :post, headers: headers, body: Jason.encode!(body)]
    |> Keyword.merge(req_options)
    |> Keyword.put(:retry, false)
    |> Req.request()
  end

  # With an `into:` handler the error body is consumed by the SSE parser and
  # resp.body is left empty; the unparsed bytes are still in its buffer.
  defp error_body(%{body: ""} = resp, initial_acc) do
    resp.private
    |> Map.get(:sse_acc, initial_acc)
    |> Map.get(:buffer, "")
  end

  defp error_body(resp, _initial_acc), do: resp.body
end
