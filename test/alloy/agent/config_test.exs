defmodule Alloy.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Config

  describe "code_execution option" do
    test "defaults to false when not specified" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []})
      assert config.code_execution == false
    end

    test "accepts code_execution: true" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, code_execution: true)
      assert config.code_execution == true
    end

    test "accepts code_execution: false explicitly" do
      config = Config.from_opts(provider: {Alloy.Provider.Test, []}, code_execution: false)
      assert config.code_execution == false
    end
  end
end
