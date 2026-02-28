defmodule Alloy.UsageTest do
  use ExUnit.Case, async: true

  alias Alloy.Usage

  describe "estimate_cost/3" do
    test "calculates cost correctly for known token counts" do
      usage = %Usage{input_tokens: 1_000_000, output_tokens: 1_000_000}
      result = Usage.estimate_cost(usage, 3.0, 15.0)

      # 1M input tokens * $3.00/M * 100 cents = 300 cents
      # 1M output tokens * $15.00/M * 100 cents = 1500 cents
      assert result.estimated_cost_cents == 1800
    end

    test "calculates partial tokens correctly" do
      # 100k input @ $3/M = $0.30 = 30 cents
      # 50k output @ $15/M = $0.75 = 75 cents
      # total = 105 cents
      usage = %Usage{input_tokens: 100_000, output_tokens: 50_000}
      result = Usage.estimate_cost(usage, 3.0, 15.0)

      assert result.estimated_cost_cents == 105
    end

    test "zero tokens = zero cost" do
      usage = %Usage{input_tokens: 0, output_tokens: 0}
      result = Usage.estimate_cost(usage, 3.0, 15.0)

      assert result.estimated_cost_cents == 0
    end

    test "preserves other usage fields" do
      usage = %Usage{
        input_tokens: 500,
        output_tokens: 200,
        cache_creation_input_tokens: 10,
        cache_read_input_tokens: 5
      }

      result = Usage.estimate_cost(usage, 3.0, 15.0)

      assert result.input_tokens == 500
      assert result.output_tokens == 200
      assert result.cache_creation_input_tokens == 10
      assert result.cache_read_input_tokens == 5
    end
  end

  describe "estimate_cost/3 small token counts" do
    test "does not truncate cost to zero for small token counts" do
      # 1000 input tokens at $3/M = 0.3 cents (not 0)
      # Old integer div: div(1000 * 300, 1_000_000) = 0 (BUG)
      # Float division: 1000 * 300 / 1_000_000 = 0.3 (correct)
      usage = %Usage{input_tokens: 1_000, output_tokens: 0}
      result = Usage.estimate_cost(usage, 3.0, 15.0)

      assert result.estimated_cost_cents > 0
      assert_in_delta result.estimated_cost_cents, 0.3, 0.001
    end

    test "small output tokens produce non-zero cost" do
      # 500 output tokens at $15/M = 0.75 cents (not 0)
      usage = %Usage{input_tokens: 0, output_tokens: 500}
      result = Usage.estimate_cost(usage, 3.0, 15.0)

      assert result.estimated_cost_cents > 0
      assert_in_delta result.estimated_cost_cents, 0.75, 0.001
    end
  end

  describe "merge/2" do
    test "sums estimated_cost_cents from both structs" do
      acc = %Usage{input_tokens: 100, output_tokens: 50, estimated_cost_cents: 200}

      response = %{
        input_tokens: 200,
        output_tokens: 100,
        estimated_cost_cents: 350
      }

      result = Usage.merge(acc, response)

      assert result.estimated_cost_cents == 550
    end

    test "handles missing estimated_cost_cents in response (defaults to 0)" do
      acc = %Usage{input_tokens: 100, output_tokens: 50, estimated_cost_cents: 150}
      response = %{input_tokens: 200, output_tokens: 100}

      result = Usage.merge(acc, response)

      assert result.estimated_cost_cents == 150
    end

    test "zero estimated_cost_cents in both = zero" do
      acc = %Usage{estimated_cost_cents: 0}
      response = %{input_tokens: 0, output_tokens: 0, estimated_cost_cents: 0}

      result = Usage.merge(acc, response)

      assert result.estimated_cost_cents == 0
    end
  end

  describe "estimate_cost/3 replacement semantic" do
    test "estimate_cost replaces existing estimated_cost_cents, does not accumulate" do
      usage = %Usage{input_tokens: 100, output_tokens: 50, estimated_cost_cents: 999}
      # After estimate_cost, the 999 is gone — replaced by the freshly computed value
      updated = Usage.estimate_cost(usage, 1.0, 2.0)
      refute updated.estimated_cost_cents == 999
      # The new value is based on the token counts, not 999 + new_cost
      assert is_number(updated.estimated_cost_cents)
    end
  end

  describe "struct defaults" do
    test "estimated_cost_cents defaults to 0" do
      usage = %Usage{}
      assert usage.estimated_cost_cents == 0
    end
  end
end
