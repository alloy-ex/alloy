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
            "credit_balance_exhausted",
            "subscription_sharing_usage_limit_exceeded"
          ] do
        error = Error.from_response(429, %{}, openai("rate_limit_error", code, "pay up"))
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

    test "reads future HTTP dates and clamps past dates to zero" do
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      headers = %{"retry-after" => [Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")]}
      assert Error.from_response(503, headers, "").retry_after_ms in 55_000..60_000

      past = %{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}
      assert Error.from_response(503, past, "").retry_after_ms == 0
    end

    test "ignores invalid durations and dates" do
      for value <- [
            "garbage",
            "-1",
            "1 second",
            "Wed, 99 Oct 2026 07:28:00 GMT",
            "Wed, 29 Feb 2025 07:28:00 GMT",
            "Wed, 01 Oct 2026 24:28:00 GMT",
            "Wed, 01 Oct 2026 07:28:00 UTC",
            "Wed, 01 Oct 2026 07:28:00 GMT\nextra"
          ] do
        assert Error.from_response(503, %{"retry-after" => [value]}, "").retry_after_ms == nil
      end
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

      assert %Error{kind: :rate_limited, status: 429, message: "Too many requests"} =
               Error.from_body(%{"error" => %{"code" => 429, "message" => "Too many requests"}})

      assert %Error{kind: :server_error, status: 502, message: "Bad gateway"} =
               Error.from_body(%{"error" => %{"code" => 502, "message" => "Bad gateway"}})

      assert %Error{kind: :auth, status: 403, message: "Denied"} =
               Error.from_body(%{"error" => %{"code" => 403, "message" => "Denied"}})

      assert %Error{kind: :rate_limited, type: "RESOURCE_EXHAUSTED"} =
               Error.from_body(%{
                 "error" => %{
                   "type" => 999,
                   "status" => "RESOURCE_EXHAUSTED",
                   "message" => "busy"
                 }
               })

      assert %Error{kind: :rate_limited, status: 429, message: "Slow down"} =
               Error.from_body(%{"error" => %{"code" => "429", "message" => "Slow down"}})

      # Bounded JSON, inspect, and string-body fallbacks (including non-JSON and nested terms).
      huge = String.duplicate("x", 3_000)
      json_fallback = Error.from_body(%{"error" => %{"detail" => huge}})
      assert String.length(json_fallback.message) == 500

      non_json = Error.from_body(%{"error" => %{"a_pid" => self(), "z_detail" => huge}})
      assert String.length(non_json.message) == 500
      assert non_json.message =~ "#PID<"

      wide_nested = Map.new(1..10, &{"k#{&1}", String.duplicate("y", 100)})
      non_error_map = Error.from_body(wide_nested)
      assert String.length(non_error_map.message) == 500

      raw_html = "<html>" <> huge <> "</html>"
      assert byte_size(Error.from_response(502, %{}, raw_html).message) == 2_000
      assert byte_size(Error.from_body(%{"error" => huge}).message) == 2_000
      assert byte_size(Error.from_body(%{"error" => %{"message" => huge}}).message) == 2_000

      # Overflow classification runs on full payload before byte capping, and
      # combining-mark / multi-byte UTF-8 payloads stay valid UTF-8 within byte cap.
      long_overflow = String.duplicate("x", 2_500) <> " prompt is too long"
      overflow_err = Error.from_response(400, %{}, long_overflow)
      assert overflow_err.kind == :context_overflow
      assert byte_size(overflow_err.message) == 2_000

      combining = "e" <> String.duplicate("\u0301", 2_000)
      capped_utf8 = Error.from_response(500, %{}, combining)
      assert String.valid?(capped_utf8.message)
      assert byte_size(capped_utf8.message) <= 2_000

      # Invalid UTF-8 (e.g. Latin-1 proxy pages) is sanitized on both short and long bodies
      # without discarding trailing diagnostic text.
      short_invalid = <<"bad ", 0xE9, " gateway">>
      short_err = Error.from_response(502, %{}, short_invalid)
      assert String.valid?(short_err.message)
      assert short_err.message =~ "gateway"

      long_invalid = <<"err ", 0xE9, " ">> <> String.duplicate("z", 2_500)
      long_err = Error.from_response(502, %{}, long_invalid)
      assert String.valid?(long_err.message)
      assert byte_size(long_err.message) == 2_000
      assert long_err.message =~ "zzzzz"

      # 5xx server error mentioning "context window" stays :server_error (retryable),
      # while an explicit context_length_exceeded code still classifies as :context_overflow.
      html_502 = "<html>502 Bad Gateway: context window proxy timeout</html>"
      assert Error.from_response(502, %{}, html_502).kind == :server_error

      assert Error.from_response(
               500,
               %{},
               %{"error" => %{"code" => "context_length_exceeded", "message" => "too long"}}
             ).kind == :context_overflow

      assert Error.from_response(
               500,
               %{},
               %{"error" => %{"type" => "context_length_exceeded", "message" => "too long"}}
             ).kind == :context_overflow

      # Multi-MB invalid UTF-8 body is sliced before sanitization and capped cleanly at 2,000 bytes.
      multi_mb_latin1 = :binary.copy(<<"bad ", 0xE9, " gateway\n">>, 150_000)
      multi_mb_err = Error.from_response(502, %{}, multi_mb_latin1)
      assert multi_mb_err.kind == :server_error
      assert String.valid?(multi_mb_err.message)
      assert byte_size(multi_mb_err.message) <= 2_000

      # 64 KiB overflow phrase scan boundary on 4xx bodies.
      within_64k = String.duplicate("a", 60_000) <> " prompt is too long"
      past_64k = String.duplicate("a", 70_000) <> " prompt is too long"
      assert Error.from_response(400, %{}, within_64k).kind == :context_overflow
      assert Error.from_response(400, %{}, past_64k).kind == :invalid_request

      long_transport = Error.from_transport({:error, huge})
      assert byte_size(long_transport.message) <= 530
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
