defmodule Alloy.Agent.ConfigDeprecationTest do
  # Synchronous: the deprecation warning is logged once per node, so this
  # module resets that node-wide flag and must not overlap async tests that
  # set :max_budget_cents themselves (ExUnit runs sync modules after them).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alloy.Agent.Config

  setup do
    :persistent_term.erase({Config, :max_budget_cents_warned})
    :ok
  end

  test "max_budget_cents logs a deprecation warning once per node and keeps the value" do
    config_opts = [provider: {Alloy.Provider.Test, []}, max_budget_cents: 50]

    first =
      capture_log(fn -> assert %Config{max_budget_cents: 50} = Config.from_opts(config_opts) end)

    second =
      capture_log(fn -> assert %Config{max_budget_cents: 50} = Config.from_opts(config_opts) end)

    assert first =~ ":max_budget_cents is deprecated"
    assert first =~ "0.13"
    refute second =~ "max_budget_cents"
  end

  test "nothing is logged when max_budget_cents is unset" do
    log = capture_log(fn -> Config.from_opts(provider: {Alloy.Provider.Test, []}) end)

    refute log =~ "max_budget_cents"
  end
end
