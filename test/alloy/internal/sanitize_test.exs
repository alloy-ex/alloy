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
end
