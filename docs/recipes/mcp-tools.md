# Recipe: MCP servers as tools

Alloy has no MCP support in core, on purpose. The context-economy argument
is real: a typical MCP server dumps every tool definition into every request —
Playwright's server costs ~13,700 tokens of tool schemas before the
conversation starts. Most Elixir applications also don't need MCP to expose
their own functions to an agent; a plain `Alloy.Tool` module is cheaper and
type-checked.

When you do need a third-party MCP server, the gateway pattern below wraps it
in **one** tool definition using
[`anubis_mcp`](https://hex.pm/packages/anubis_mcp) — so the context cost is a
short tool list, not N full schemas.

## Setup

Add the client to your deps and supervision tree:

```elixir
# mix.exs
{:anubis_mcp, "~> 1.5"}

# application.ex
children = [
  {Anubis.Client,
   name: MyApp.MCPClient,
   transport: {:streamable_http, base_url: "http://localhost:8000"},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: "2025-06-18"}
]
```

## The gateway tool

```elixir
defmodule MyApp.Tools.MCP do
  @behaviour Alloy.Tool

  @client MyApp.MCPClient

  @impl true
  def name, do: "mcp"

  @impl true
  def description do
    tools =
      for %{"name" => name, "description" => desc} <- cached_tools() do
        "- #{name}: #{String.slice(desc || "", 0, 200)}"
      end

    """
    Call a tool on the connected MCP server. Pass the tool name and its
    arguments. Available tools:

    #{Enum.join(tools, "\n")}
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        tool: %{type: "string", description: "Name of the MCP tool to call"},
        arguments: %{
          type: "object",
          description: "Arguments for the tool, matching its schema"
        }
      },
      required: ["tool"]
    }
  end

  # Cap what a chatty server can dump into your context.
  @impl true
  def max_result_chars, do: 16_000

  @impl true
  def execute(%{"tool" => tool} = input, _context) do
    arguments = Map.get(input, "arguments", %{})

    case Anubis.Client.call_tool(@client, tool, arguments) do
      {:ok, %Anubis.MCP.Response{is_error: false, result: result}} ->
        {:ok, render_content(result)}

      {:ok, %Anubis.MCP.Response{result: result}} ->
        {:error, render_content(result)}

      {:error, error} ->
        {:error, "MCP transport error: #{inspect(error)}"}
    end
  end

  # Tool list rarely changes; fetch once and cache for the VM's lifetime.
  defp cached_tools do
    case :persistent_term.get({__MODULE__, :tools}, :missing) do
      :missing ->
        {:ok, %Anubis.MCP.Response{result: %{"tools" => tools}}} =
          Anubis.Client.list_tools(@client)

        :persistent_term.put({__MODULE__, :tools}, tools)
        tools

      tools ->
        tools
    end
  end

  defp render_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp render_content(result), do: inspect(result)
end
```

Then just add it to `tools:`:

```elixir
{:ok, result} =
  Alloy.run("Search the docs for compaction and summarize what you find",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: model},
    tools: [MyApp.Tools.MCP]
  )
```

## Variant: one tool per MCP tool

When you want the model to see full per-tool schemas (better argument
validation, at the cost of more context), build inline tools from the
server's discovery response with `Alloy.Tool.inline/1`:

```elixir
defmodule MyApp.MCPTools do
  @client MyApp.MCPClient

  @doc "One Alloy tool per tool exposed by the MCP server."
  def all do
    {:ok, %Anubis.MCP.Response{result: %{"tools" => tools}}} =
      Anubis.Client.list_tools(@client)

    for %{"name" => name} = tool <- tools do
      Alloy.Tool.inline(
        name: name,
        description: tool["description"] || name,
        input_schema: tool["inputSchema"] || %{type: "object", properties: %{}},
        max_result_chars: 16_000,
        execute: fn arguments, _context ->
          case Anubis.Client.call_tool(@client, name, arguments) do
            {:ok, %Anubis.MCP.Response{is_error: false, result: result}} ->
              {:ok, render_content(result)}

            {:ok, %Anubis.MCP.Response{result: result}} ->
              {:error, render_content(result)}

            {:error, error} ->
              {:error, "MCP transport error: #{inspect(error)}"}
          end
        end
      )
    end
  end

  defp render_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp render_content(result), do: inspect(result)
end

{:ok, result} =
  Alloy.run("Search the docs for compaction",
    provider: provider,
    tools: MyApp.MCPTools.all() ++ [Alloy.Tool.Core.Read]
  )
```

## Trade-offs, honestly

**Gateway vs. one-tool-per-MCP-tool.** The gateway costs one tool definition
and a compact name/description list — the right default, and the reason this
recipe exists. The per-tool variant gives the model full schemas (provider-
side argument validation) but pays the context cost the gateway avoids: every
tool's complete schema rides along on every request. Measure before choosing
it for servers with more than a handful of tools, and consider filtering the
discovery list to the tools you actually want exposed.

**Trust.** An MCP server is remote code with a marketing page. Its tool
descriptions enter your prompt (prompt-injection surface) and its results
enter your context. Use `max_result_chars`, prefer servers you operate, and
consider a middleware hook to block specific tool names.

**Don't use this for your own code.** If the functions live in your
application, write `Alloy.Tool` modules directly — no transport, no JSON-RPC,
no second process tree, and the compiler checks your schema helpers.
