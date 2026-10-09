defmodule Alloy.TestingRequireTest do
  # Uses `require` instead of `use Alloy.Testing`: the assertion macros
  # must not depend on Alloy.Testing's functions being imported.
  use ExUnit.Case, async: true

  require Alloy.Testing

  test "assert_tool_called/3 works when Alloy.Testing is only required" do
    result =
      Alloy.Testing.run_with_responses("Echo", [
        Alloy.Testing.tool_response("echo", %{text: "hi"}),
        Alloy.Testing.text_response("Done")
      ])

    Alloy.Testing.assert_tool_called(result, "echo")
    Alloy.Testing.assert_tool_called(result, "echo", %{"text" => "hi"})
    Alloy.Testing.assert_tool_called(result, "echo", %{text: "hi"})
    Alloy.Testing.refute_tool_called(result, "bash")
  end
end
