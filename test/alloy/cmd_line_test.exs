defmodule Alloy.CmdLineTest do
  use ExUnit.Case, async: true

  alias Alloy.{CmdLine, OSProcess}

  describe "command/4" do
    test "runs the program through cmd.exe with stdin and stderr redirected" do
      assert CmdLine.command(
               ~S(C:\Program Files\codex.exe),
               ["exec", "-"],
               ~S(C:\t\p.txt),
               ~S(C:\t\e.log)
             ) ==
               {:ok,
                ~S(cmd.exe /d /s /c ""C:\Program Files\codex.exe" exec - < "C:\t\p.txt" 2> "C:\t\e.log"")}
    end

    test "caret-escapes a quoted argument so cmd.exe passes it literally" do
      assert {:ok, line} =
               CmdLine.command("codex", ["-c", ~s(sandbox_mode="read-only")], "p", "e")

      assert line =~ ~S("codex" -c ^"sandbox_mode=\^"read-only\^"^" <)
    end

    test "refuses a line break, which cmd.exe cannot carry" do
      assert {:error, message} = CmdLine.command("codex", ["a\r\nb"], "p", "e")
      assert message =~ "line break"
    end
  end

  test "caret_escape/1 escapes every cmd.exe metacharacter" do
    assert CmdLine.caret_escape(~S{a&b|c<d>e^f%g!h(i)"j}) == ~S{a^&b^|c^<d^>e^^f^%g^!h^(i^)^"j}
  end

  describe "argv_quote/1" do
    test "leaves a plain argument alone and quotes empty or spaced ones" do
      assert CmdLine.argv_quote("--json") == "--json"
      assert CmdLine.argv_quote("") == ~s("")
      assert CmdLine.argv_quote("a b") == ~s("a b")
    end

    test "escapes quotes and the backslashes before them, and trailing backslashes" do
      assert CmdLine.argv_quote(~S(say "hi")) == ~S("say \"hi\"")
      assert CmdLine.argv_quote(~S(a\"b c)) == ~S("a\\\"b c")
      assert CmdLine.argv_quote("dir\\ x\\") == ~s("dir\\ x\\\\")
    end
  end

  describe "OSProcess.signal_command/3" do
    test "kills the process tree with taskkill on Windows" do
      for signal <- ["TERM", "KILL"] do
        assert OSProcess.signal_command({:win32, :nt}, 4242, signal) ==
                 {"taskkill", ["/T", "/F", "/PID", "4242"], stderr_to_stdout: true}
      end
    end

    test "signals the process group through sh on unix" do
      assert {"/bin/sh", ["-c", ~S(kill -s "$1" -- "-$2"), "alloy-kill", "TERM", "4242"], opts} =
               OSProcess.signal_command({:unix, :darwin}, 4242, "TERM")

      assert opts[:stderr_to_stdout]
      assert Enum.all?(opts[:env], fn {_name, value} -> is_nil(value) end)
    end
  end
end
