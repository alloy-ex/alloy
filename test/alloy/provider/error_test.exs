defmodule Alloy.Provider.ErrorTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Error

  defp anthropic(type, message),
    do: %{"type" => "error", "error" => %{"type" => type, "message" => message}}

  defp openai(type, code, message),
    do: %{"error" => %{"type" => type, "code" => code, "message" => message}}

  defp gemini(code, status, message),
    do: %{"error" => %{"code" => code, "status" => status, "message" => message}}

  describe "from_response/3 classification" do
    test "Anthropic rate limit, overload, server and timeout errors are retryable" do
      for {status, type, kind} <- [
            {429, "rate_limit_error", :rate_limited},
            {529, "overloaded_error", :overloaded},
            {500, "api_error", :server_error},
            {504, "timeout_error", :timeout}
          ] do
        error = Error.from_response(status, %{}, anthropic(type, "msg"))
        assert error.kind == kind
        assert Error.retryable?(error)
        assert Exception.message(error) == "#{type}: msg"
      end
    end

    test "OpenAI 503 overloaded and 429 slow_down are retryable" do
      overloaded =
        Error.from_response(
          503,
          %{},
          openai("service_unavailable_error", "server_is_overloaded", "busy")
        )

      slow_down = Error.from_response(429, %{}, openai("rate_limit_error", "slow_down", "slow"))

      assert overloaded.kind == :overloaded
      assert slow_down.kind == :rate_limited
      assert Error.retryable?(overloaded) and Error.retryable?(slow_down)
    end

    test "quota and spend-limit 429s are not retried" do
      for code <- [
            "insufficient_quota",
            "project_spend_limit_exceeded",
            "credit_balance_exhausted"
          ] do
        error = Error.from_response(429, %{}, openai("insufficient_quota", code, "pay up"))
        assert error.kind == :quota
        refute Error.retryable?(error)
      end
    end

    test "context overflow is detected across providers" do
      cases = [
        {400,
         anthropic("invalid_request_error", "prompt is too long: 210000 tokens > 200000 maximum")},
        {400,
         openai(
           "invalid_request_error",
           "context_length_exceeded",
           "Your input exceeds the context window of this model."
         )},
        {400,
         gemini(
           400,
           "INVALID_ARGUMENT",
           "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."
         )},
        {400,
         %{
           "error" => %{
             "message" =>
               "This model's maximum prompt length is 131072 but the request contains 140000 tokens."
           }
         }}
      ]

      for {status, body} <- cases do
        error = Error.from_response(status, %{}, body)
        assert error.kind == :context_overflow, "not detected: #{inspect(body)}"
        refute Error.retryable?(error)
      end
    end

    test "a 429 that mentions tokens is a rate limit, not an overflow" do
      body =
        openai(
          "tokens",
          "rate_limit_exceeded",
          "Request too large: context window tokens per min"
        )

      assert Error.from_response(429, %{}, body).kind == :rate_limited
    end

    test "Gemini status labels classify and keep the legacy message shape" do
      error = Error.from_response(429, %{}, gemini(429, "RESOURCE_EXHAUSTED", "quota"))

      assert error.kind == :rate_limited
      assert error.code == nil
      assert Exception.message(error) == "RESOURCE_EXHAUSTED: quota"
    end

    test "list-wrapped error bodies (Gemini compatibility endpoint) are read" do
      body = [gemini(400, "INVALID_ARGUMENT", "bad")]

      assert %Error{kind: :invalid_request, type: "INVALID_ARGUMENT"} =
               Error.from_response(400, %{}, body)
    end

    test "auth failures and unknown bodies fall back to the HTTP status" do
      assert Error.from_response(401, %{}, "nope").kind == :auth

      error = Error.from_response(502, %{}, "<html>Bad Gateway</html>")
      assert error.kind == :server_error
      assert Exception.message(error) == "HTTP 502: <html>Bad Gateway</html>"
    end

    test "JSON string bodies are decoded" do
      body = Jason.encode!(anthropic("rate_limit_error", "slow down"))

      assert %Error{kind: :rate_limited, type: "rate_limit_error"} =
               Error.from_response(429, %{}, body)
    end
  end

  describe "retry-after" do
    test "reads retry-after seconds from Req's header map" do
      error = Error.from_response(429, %{"retry-after" => ["2"]}, "")
      assert error.retry_after_ms == 2_000
    end

    test "prefers retry-after-ms and accepts tuple lists" do
      headers = [{"Retry-After", "9"}, {"retry-after-ms", "1500"}]
      assert Error.from_response(429, headers, "").retry_after_ms == 1_500
    end

    test "ignores the HTTP-date form" do
      headers = %{"retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]}
      assert Error.from_response(503, headers, "").retry_after_ms == nil
    end
  end

  describe "from_body/1" do
    test "classifies in-band errors by code and type, without an HTTP status" do
      error =
        Error.from_body(%{"error" => %{"code" => "server_error", "message" => "Model failed"}})

      assert %Error{kind: :server_error, status: nil, code: "server_error"} = error
      assert Error.retryable?(error)
      assert Exception.message(error) == "Model failed"

      assert Error.from_body(anthropic("overloaded_error", "Overloaded")).kind == :overloaded

      assert Error.from_body(openai("invalid_request_error", "context_length_exceeded", "long")).kind ==
               :context_overflow

      assert Error.from_body(%{"error" => %{"code" => "invalid_prompt"}}).kind == :unknown
    end
  end

  describe "from_transport/1" do
    test "classifies transport failures structurally" do
      assert Error.from_transport(%Req.TransportError{reason: :timeout}).kind == :timeout
      assert Error.from_transport(%Req.TransportError{reason: :econnrefused}).kind == :network
      assert Error.from_transport(%Req.TransportError{reason: :nxdomain}).kind == :unknown
    end

    test "keeps the legacy message" do
      error = Error.from_transport(%Req.TransportError{reason: :closed})

      assert Exception.message(error) ==
               "HTTP request failed: %Req.TransportError{reason: :closed}"
    end
  end

  test "interpolates like the string errors it replaces" do
    error = Error.from_response(429, %{}, anthropic("rate_limit_error", "slow"))
    assert "failed: #{error}" == "failed: rate_limit_error: slow"
  end
end
