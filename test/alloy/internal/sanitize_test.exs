defmodule Alloy.Internal.SanitizeTest do
  use ExUnit.Case, async: true

  alias Alloy.Internal.Sanitize

  describe "cap_bytes/2" do
    test "returns short valid binaries unchanged" do
      assert Sanitize.cap_bytes("hello", 10) == "hello"
    end

    test "caps multi-byte UTF-8 without splitting codepoints" do
      # Each emoji is 4 bytes; capping at 6 bytes keeps 1 emoji (4 bytes).
      result = Sanitize.cap_bytes("🎉🎉🎉", 6)
      assert String.valid?(result)
      assert result == "🎉"
    end

    test "sanitizes invalid UTF-8 bytes and respects max_bytes" do
      raw = <<"ok ", 0xE9, " ">> <> String.duplicate("a", 50)
      capped = Sanitize.cap_bytes(raw, 20)
      assert String.valid?(capped)
      assert byte_size(capped) <= 20
    end
  end

  describe "inspect_bounded/2 and inspect_capped/3" do
    test "bounds large collections and caps total byte size" do
      huge = Map.new(1..100, &{"k#{&1}", String.duplicate("x", 100)})
      bounded = Sanitize.inspect_bounded(huge)
      assert bounded =~ "..."

      capped = Sanitize.inspect_capped(huge, 80)
      assert String.valid?(capped)
      assert byte_size(capped) <= 80
    end
  end

  describe "stacktrace/1" do
    test "replaces argument lists with arities while preserving arity entries" do
      trace = [
        {MyMod, :secret_fn, ["sk-secret", %{token: "abc"}], [file: ~c"a.ex", line: 10]},
        {&String.upcase/1, ["sk-secret"], [file: ~c"b.ex", line: 20]},
        {MyMod, :already_arity, 2, [file: ~c"c.ex", line: 30]}
      ]

      sanitized = Sanitize.stacktrace(trace)

      assert sanitized == [
               {MyMod, :secret_fn, 2, [file: ~c"a.ex", line: 10]},
               {&String.upcase/1, 1, [file: ~c"b.ex", line: 20]},
               {MyMod, :already_arity, 2, [file: ~c"c.ex", line: 30]}
             ]
    end
  end

  describe "exception_summary/2" do
    test "caps RuntimeError messages at UTF-8 boundaries and omits structural terms" do
      long_msg = "boom " <> String.duplicate("🎉", 20)
      summary = Sanitize.exception_summary(%RuntimeError{message: long_msg}, 12)
      assert String.valid?(summary)
      assert byte_size(summary) <= 12
      assert String.starts_with?(summary, "boom ")

      assert Sanitize.exception_summary(%ArgumentError{message: "argument error"}) ==
               "argument error"

      assert Sanitize.exception_summary(%ArgumentError{message: "bad secret sk-arg"}) ==
               "ArgumentError"

      assert Sanitize.exception_summary(%KeyError{key: :db_url, term: %{api_key: "sk-123"}}) ==
               "KeyError (key :db_url not found)"

      assert Sanitize.exception_summary(%KeyError{key: "sk-string-key", term: %{secret: "x"}}) ==
               "KeyError"

      assert Sanitize.exception_summary(%MatchError{term: %{api_key: "sk-match"}}) == "MatchError"

      assert Sanitize.exception_summary(%CaseClauseError{term: %{api_key: "sk-case"}}) ==
               "CaseClauseError"
    end
  end

  describe "exit_summary/2 and crash_summary/4" do
    test "unwraps stacktrace and OTP call-exit wrappers without leaking terms or args" do
      stack = [{MyMod, :run, 1, [file: ~c"a.ex", line: 1]}]
      fun_stack = [{&Function.identity/1, 1, [file: ~c"b.ex", line: 2]}]
      secret = %{api_key: "sk-super-secret"}

      assert Sanitize.exit_summary(
               {{%KeyError{key: :db_url, term: secret}, stack}, {Task, :await, [secret, 5_000]}}
             ) == "KeyError (key :db_url not found)"

      assert Sanitize.exit_summary(
               {:timeout, {GenServer, :call, [self(), {:query, secret}, 5_000]}}
             ) == ":timeout"

      assert Sanitize.exit_summary({{:badkey, :token, secret}, fun_stack}) ==
               "KeyError (key :token not found)"

      assert Sanitize.exit_summary({{:badmatch, secret}, stack}) == "MatchError"
      assert Sanitize.exit_summary({{:nocatch, :boom}, stack}) == "nocatch: :boom"
      assert Sanitize.exit_summary({{:nocatch, secret}, stack}) == "nocatch: unexpected map"
      assert Sanitize.exit_summary({:custom_atom, stack}) == ":custom_atom"

      assert Sanitize.exit_summary({%KeyError{key: :x, term: secret}, []}) ==
               "KeyError (key :x not found)"

      assert Sanitize.exit_summary({{:nocatch, :x}, [:not_a_stack]}) == "unexpected tuple"
      assert Sanitize.exit_summary({:not_exception, [:not_a_stack]}) == "unexpected tuple"
      assert Sanitize.exit_summary({:nocatch, :direct}) == "nocatch: :direct"
      assert Sanitize.exit_summary({:shutdown, :closed}) == "{:shutdown, :closed}"
      assert Sanitize.exit_summary({:shutdown, secret}) == "{:shutdown, ...}"
      assert Sanitize.exit_summary({:error, :enoent}) == "{:error, :enoent}"
      assert Sanitize.exit_summary({:timeout, :db}) == "{:timeout, :db}"
      assert Sanitize.exit_summary({:noproc, []}) == ":noproc"
      assert Sanitize.exit_summary(%RuntimeError{message: "sk-redact"}, :redact) == "RuntimeError"
      assert Sanitize.exit_summary(%MatchError{term: secret}) == "MatchError"
      assert Sanitize.exit_summary(42) == "42"
      assert Sanitize.exit_summary(URI.parse("https://example.com")) == "unexpected URI"
      assert Sanitize.exit_summary(secret) == "unexpected map"
      assert Sanitize.exit_summary({:custom_crash, "sk-123"}) == "{:custom_crash, ...}"
      assert Sanitize.exit_summary({1, "sk-123"}) == "unexpected tuple"
      assert Sanitize.exit_summary(["sk-123"]) == "unexpected list"
      assert Sanitize.exit_summary("sk-123") == "unexpected binary"
      assert Sanitize.exit_summary(self()) == "unexpected term"

      assert Sanitize.crash_summary(:error, :badarg, stack) == "argument error"

      assert Sanitize.crash_summary(:error, {:badkey, :k, secret}, stack) ==
               "KeyError (key :k not found)"

      assert Sanitize.crash_summary(:error, :custom_err, stack) == "error: :custom_err"
      assert Sanitize.crash_summary(:throw, :stop_now, []) == "throw: :stop_now"
      assert Sanitize.crash_summary(:throw, secret, []) == "throw: unexpected map"
      assert Sanitize.crash_summary(:exit, :gone, []) == "exit: :gone"
      assert Sanitize.crash_summary(:exit, {:secret, secret}, []) == "exit: {:secret, ...}"
    end
  end
end
