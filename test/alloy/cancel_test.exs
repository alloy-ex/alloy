defmodule Alloy.CancelTest do
  use ExUnit.Case, async: true

  alias Alloy.Cancel

  describe "new/0, cancel/1, and cancelled?/1" do
    test "nil token is never cancelled" do
      refute Cancel.cancelled?(nil)
    end

    test "marks token cancelled idempotently" do
      token = Cancel.new()
      refute Cancel.cancelled?(token)

      assert :ok = Cancel.cancel(token)
      assert Cancel.cancelled?(token)

      assert :ok = Cancel.cancel(token)
      assert Cancel.cancelled?(token)
    end
  end

  describe "combine/2" do
    test "handles nil operands and returns the non-nil token directly" do
      outer = Cancel.new()
      inner = Cancel.new()

      assert Cancel.combine(nil, nil) == nil
      assert Cancel.combine(nil, inner) == inner
      assert Cancel.combine(outer, nil) == outer

      combined_outer = Cancel.combine(outer, nil)
      Cancel.cancel(combined_outer)
      assert Cancel.cancelled?(outer)

      shared = Cancel.new()
      combined_shared = Cancel.combine(shared, shared)
      Cancel.cancel(combined_shared)
      assert Cancel.cancelled?(shared)
    end

    test "propagates outer cancellation without mutating outer when inner is cancelled" do
      outer = Cancel.new()
      inner = Cancel.new()
      combined = Cancel.combine(outer, inner)

      refute Cancel.cancelled?(combined)

      Cancel.cancel(combined)
      assert Cancel.cancelled?(combined)
      assert Cancel.cancelled?(inner)
      refute Cancel.cancelled?(outer)

      outer2 = Cancel.new()
      inner2 = Cancel.new()
      combined2 = Cancel.combine(outer2, inner2)

      Cancel.cancel(outer2)
      assert Cancel.cancelled?(combined2)
      refute Cancel.cancelled?(inner2)
    end

    test "deduplicates repeated parent tokens across nested combinations" do
      a = Cancel.new()
      b = Cancel.new()
      c = Cancel.new()

      combined = a |> Cancel.combine(b) |> Cancel.combine(Cancel.combine(a, c))
      assert length(combined.parents) == 2

      Cancel.cancel(a)
      assert Cancel.cancelled?(combined)
    end
  end

  describe "valid?/1 and valid_atomics_ref?/1" do
    test "accepts valid standalone and combined tokens" do
      outer = Cancel.new()
      inner = Cancel.new()
      combined = Cancel.combine(outer, inner)

      assert Cancel.valid?(outer)
      assert Cancel.valid?(combined)
      assert Cancel.valid_atomics_ref?(outer.ref)
    end

    test "rejects forged structs, non-tokens, and invalid atomics refs" do
      refute Cancel.valid?(nil)
      refute Cancel.valid?(:token)
      refute Cancel.valid?(%Cancel{ref: make_ref()})
      refute Cancel.valid?(%Cancel{ref: Cancel.new().ref, parents: :not_a_list})
      refute Cancel.valid?(%Cancel{ref: Cancel.new().ref, parents: [%Cancel{ref: make_ref()}]})

      refute Cancel.valid_atomics_ref?(make_ref())
      refute Cancel.valid_atomics_ref?(:not_a_ref)
    end
  end
end
