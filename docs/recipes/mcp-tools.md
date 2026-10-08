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

This example uses the client's 2025 protocol contract. Anubis 1.5 itself
requires Elixir 1.18 or later; this optional application dependency has a
higher floor than Alloy. The current Anubis 2.1 documentation still lists
protocol support only through 2025-11-25. The 2026 MCP revision changes the
client lifecycle and requires more than editing `protocol_version`.
[Client versions](https://anubis-mcp.hexdocs.pm/readme.html),
[protocol changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog).

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

  # Static-server example only. Refresh this cache when the server's tool
  # list changes; wire the client's discovery notifications in your app.
  def refresh_tools do
    :persistent_term.erase({__MODULE__, :tools})
    cached_tools()
  end

  # Fetch once and cache until explicitly refreshed.
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

## Remote MCP without a client

For remote HTTP MCP servers on Anthropic, you can also mount the server
provider-side instead of running a client in your app. Pass Anthropic's
`mcp_servers` body field and the matching beta header through `extra_body` /
`extra_headers` on the provider config. The client-side gateway above remains
the right pattern for local or stdio MCP servers and for providers without a
server-side MCP connector.

The current connector requires a matching `mcp_toolset` in `tools` and the
`mcp-client-2025-11-20` beta header; the April beta is deprecated.
[Official contract](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector).

```elixir
Alloy.run("Search the connected documentation",
  tools: [],
  provider: {Alloy.Provider.Anthropic,
    api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    model: "claude-sonnet-5-5",
    extra_headers: [{"anthropic-beta", "mcp-client-2025-11-20"}],
    extra_body: %{
      "mcp_servers" => [%{
        "type" => "url", "name" => "docs",
        "url" => "https://your-mcp-server.example/mcp"
      }],
      "tools" => [%{"type" => "mcp_toolset", "mcp_server_name" => "docs"}]
    }
  }
)
```

`extra_body` merges last, so its `tools` array replaces generated local tool
definitions. This example explicitly uses only provider-side MCP tools. When
combining local and remote tools, include both definitions in the final array.
Server authorization and tool allowlisting belong in your application. The
connector supports remote tool calls and is not eligible for zero data
retention; local stdio and other MCP features need an application client.

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
