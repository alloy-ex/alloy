defmodule Alloy.Internal.DeadlineTest do
  use ExUnit.Case, async: true

  alias Alloy.Internal.Deadline

  describe "expired?/1" do
    test "returns false for nil deadline" do
      refute Deadline.expired?(nil)
    end

    test "returns false for future deadline and true for past or current deadline" do
      now = System.monotonic_time(:millisecond)

      refute Deadline.expired?(now + 60_000)
      assert Deadline.expired?(now - 1)
      assert Deadline.expired?(now)
    end
  end

  describe "min/2" do
    test "handles nil operands and picks the earlier integer deadline" do
      assert Deadline.min(nil, nil) == nil
      assert Deadline.min(nil, 500) == 500
      assert Deadline.min(500, nil) == 500
      assert Deadline.min(100, 250) == 100
      assert Deadline.min(250, 100) == 100
      assert Deadline.min(-10, 5) == -10
    end
  end

  describe "remaining_ms/1" do
    test "returns :infinity for nil" do
      assert Deadline.remaining_ms(nil) == :infinity
    end

    test "returns 0 for expired deadlines and positive remaining time for future ones" do
      now = System.monotonic_time(:millisecond)

      assert Deadline.remaining_ms(now - 50) == 0
      assert Deadline.remaining_ms(now) == 0

      remaining = Deadline.remaining_ms(now + 5_000)
      assert is_integer(remaining)
      assert remaining > 0 and remaining <= 5_000
    end
  end

  describe "next_wait_ms/2" do
    test "passes max_wait_ms through when deadline is nil" do
      assert Deadline.next_wait_ms(nil, :infinity) == :infinity
      assert Deadline.next_wait_ms(nil, 25) == 25
      assert Deadline.next_wait_ms(nil, 0) == 0
    end

    test "bounds wait time by remaining deadline" do
      now = System.monotonic_time(:millisecond)

      assert Deadline.next_wait_ms(now - 10, 25) == 0
      assert Deadline.next_wait_ms(now - 10, :infinity) == 0
      assert Deadline.next_wait_ms(now + 60_000, 25) == 25

      bounded = Deadline.next_wait_ms(now + 5_000, :infinity)
      assert is_integer(bounded)
      assert bounded > 0 and bounded <= 5_000

      tight = Deadline.next_wait_ms(now + 50, 10_000)
      assert is_integer(tight)
      assert tight >= 0 and tight <= 50
    end
  end
end
