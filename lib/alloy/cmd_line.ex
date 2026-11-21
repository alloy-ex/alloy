defmodule Alloy.CmdLine do
  @moduledoc false
  # A cmd.exe command line that runs a program with stdin from one file and
  # stderr to another: the Windows counterpart of the `sh` launchers. A port
  # cannot send EOF, and the CLIs read their prompt from stdin to EOF, so a
  # shell has to wire the redirects. cmd.exe also runs a `.cmd` shim (npm's
  # installs) and resolves a bare name through PATHEXT.

  @doc """
  The command line for `Port.open({:spawn, line}, ...)`, which hands it to
  Windows verbatim. Each argument is quoted for the program's own argv parser,
  then every cmd.exe metacharacter is caret-escaped, so cmd passes it through
  literally and never enters quote mode. The executable and the redirect
  targets are plainly quoted: cmd must read them, and paths hold no quotes.
  `/s` strips only the outermost pair. A line break ends a cmd.exe line and
  cannot be escaped, so it is refused rather than truncating the command.
  """
  @spec command(String.t(), [String.t()], String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def command(executable, args, stdin_path, stderr_path) do
    case Enum.find([executable | args], &String.contains?(&1, ["\n", "\r"])) do
      nil ->
        line =
          Enum.join(
            [quote_path(executable) | Enum.map(args, &(&1 |> argv_quote() |> caret_escape()))],
            " "
          )

        {:ok,
         ~s(cmd.exe /d /s /c ") <>
           line <>
           " < " <> quote_path(stdin_path) <> " 2> " <> quote_path(stderr_path) <> ~s(")}

      arg ->
        {:error,
         "argument cannot pass through cmd.exe, it holds a line break: " <>
           String.slice(arg, 0, 80)}
    end
  end

  defp quote_path(path), do: ~s(") <> path <> ~s(")

  @doc """
  The MSVCRT rules: backslashes are literal unless they precede a quote,
  where each is doubled and the quote escaped; trailing ones are doubled
  before the closing quote.
  """
  @spec argv_quote(String.t()) :: String.t()
  def argv_quote(""), do: ~s("")

  def argv_quote(arg) do
    if String.contains?(arg, [" ", "\t", "\v", "\""]) do
      quoted =
        Regex.replace(~r/(\\*)("|$)/, arg, fn _all, slashes, tail ->
          doubled = slashes <> slashes
          if tail == "\"", do: doubled <> "\\\"", else: doubled
        end)

      ~s(") <> quoted <> ~s(")
    else
      arg
    end
  end

  @spec caret_escape(String.t()) :: String.t()
  def caret_escape(text), do: Regex.replace(~r/[()%!^"<>&|]/, text, "^\\0")
end
