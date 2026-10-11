# Recipe: Code mode

Hand an agent one `run_script` tool in place of a long tool list. The agent
writes a short Lua script, your tools are bound inside it as functions, and
the script's return value is the tool result.

Two costs go away. The first is the tool list itself: every definition is
sent on every turn whether it is used or not. At CodeMySpec, where this
recipe comes from, agents were handed 111 tools, about 21,500 tokens, to make
three or four calls per task. The second is composition. "List the orders,
keep the open ones, look up each customer" is a round trip per call, with
every intermediate list carried in context and the arithmetic done by the
model. As a script it is one call:

```lua
local open, total = {}, 0
for _, order in ipairs(list_orders({})) do
  if order.status == "open" then
    total = total + order.total
    local customer, err = get_customer({ order_id = order.id })
    open[#open + 1] = customer or ("unknown: " .. err)
  end
end
return { customers = open, total = total }
```

This works with every provider, because to the model `run_script` is an
ordinary tool. It is the local counterpart of Anthropic's server-side code
execution (`code_execution: true` with `allowed_callers: [:code_execution]`,
see the README): the script runs in your BEAM, beside your data, and the
tools it calls are your `execute/2` functions with your context.

Lua runs through the [`lua`](https://hex.pm/packages/lua) package, a Lua VM
written in Elixir with no native code and no dependencies. Add
`{:lua, "~> 1.0"}` to your deps.

## The tool

```elixir
defmodule MyApp.CodeMode do
  @moduledoc "One tool that runs a Lua script against other tools."

  # Each bounds what the others miss: CPU, recursion, and a string built
  # in memory (the library's default allows 256 MiB).
  @limits [max_instructions: 1_000_000, max_call_depth: 100, max_string_bytes: 256 * 1024]

  def tool(tools) do
    Alloy.Tool.inline(
      name: "run_script",
      description: description(tools),
      input_schema: %{
        type: "object",
        properties: %{
          script: %{type: "string", description: "Lua source. `return` the answer."}
        },
        required: ["script"]
      },
      max_result_chars: 24_000,
      execute: fn %{"script" => script}, context -> run(script, tools, context) end
    )
  end

  defp description(tools) do
    index = Enum.map_join(tools, "\n", &"- #{&1.name()}: #{first_line(&1.description())}")

    """
    Run a Lua script with these tools bound as functions. Each takes one
    table and returns its result; a tool that fails returns nil and an error
    message, so the script can carry on past it. `return` the answer.

    A loop, a filter and a summary in one script cost one call, where the
    same work as separate tool calls costs a turn each.

    #{index}
    """
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp run(script, tools, context) do
    lua = Enum.reduce(tools, Lua.new(@limits), &bind(&2, &1, context))
    {values, _lua} = Lua.eval!(lua, script)
    {:ok, render(values)}
  rescue
    error in [Lua.CompilerException, Lua.RuntimeException] ->
      {:error, Exception.message(error)}
  end

  # The context is closed over here, so a script supplies arguments and
  # nothing else: it acts with exactly the authority of the agent.
  defp bind(lua, tool, context) do
    Lua.set!(lua, [tool.name()], fn args, state ->
      case tool.execute(input(state, args), context) do
        {:ok, _text, data} -> encode(state, [data])
        {:ok, text} -> encode(state, [text])
        {:error, reason} -> encode(state, [nil, reason])
      end
    end)
  end

  defp input(state, [table | _]) do
    case state |> Lua.decode!(table) |> from_lua() do
      %{} = input -> input
      _empty_or_not_a_table -> %{}
    end
  end

  defp input(_state, []), do: %{}

  defp encode(state, values) do
    {encoded, state} =
      Enum.map_reduce(values, state, fn value, state -> Lua.encode!(state, value) end)

    {encoded, state}
  end

  defp render([]), do: "nil"
  defp render([value]), do: value |> from_lua() |> to_text()
  defp render(values), do: values |> Enum.map(&from_lua/1) |> to_text()

  defp to_text(text) when is_binary(text), do: text
  defp to_text(value), do: Jason.encode!(value, pretty: true)

  # A Lua table decodes as `{key, value}` pairs. Keys 1..n are an array.
  defp from_lua([{_, _} | _] = pairs) do
    keys = pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    if keys == Enum.to_list(1..length(keys)),
      do: pairs |> Enum.sort() |> Enum.map(&from_lua(elem(&1, 1))),
      else: Map.new(pairs, fn {key, value} -> {to_string(key), from_lua(value)} end)
  end

  defp from_lua(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp from_lua(value), do: value
end
```

## Using it

```elixir
{:ok, result} =
  Alloy.run("What do the open orders add up to, and whose are they?",
    provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-5-5"},
    tools: [MyApp.CodeMode.tool([MyApp.Tools.ListOrders, MyApp.Tools.GetCustomer])],
    context: %{tenant_id: tenant_id}
  )
```

The bound tools are ordinary `Alloy.Tool` modules. A tool that returns
`{:ok, text, data}` hands the script `data` as a table, so a script can loop
over records instead of parsing text; one that returns `{:ok, text}` hands it
the string.

## Design notes

**Errors are values, not raises.** A failed tool returns `nil, message`, Lua's
usual idiom, rather than ending the script. Much of what code mode is for is a
script that reads twenty things and reports the three that were missing, and
it cannot do that if the first miss kills it. A script that would rather stop
can write `assert(get_customer({ order_id = 7 }))`.

**Bound every resource the script can touch.** `Lua.new/1` already refuses
`io`, `os.execute`, `os.getenv`, `require`, `load` and the rest: they exist,
and calling one raises "is sandboxed". The three limits each stop a case the
others miss: `:max_instructions` a loop, `:max_call_depth` a recursion, and
`:max_string_bytes` a string built in one call (`string.rep("x", 2^28)` is
neither a loop nor a host call, and the library allows 256 MiB by default).
The wall clock comes from Alloy: each tool runs in its own task under
`:tool_timeout`, which also covers a bound tool that blocks.

**Make a fresh VM per call.** A reused VM keeps whatever globals the last
script set, and two agents sharing one would leak state into each other.

**Authority comes from the closure, not the arguments.** `context` is captured
when the tools are bound, so a script can only pass arguments, and arguments
are not where scope comes from. A script acts with exactly the authority of
the agent that sent it.

**Cap the answer, and say so.** `max_result_chars` keeps one result from
becoming the whole turn, and Alloy's truncation marks the cut. An agent that
gets a silently cut answer reasons about a fragment as though it were the
whole thing.

**Keep some tools out of the script.** Never bind `run_script` itself: each
nested call would get a fresh VM with fresh limits, and no limit would see the
recursion. Leave out tools whose meaning changes in a loop too: one that waits
on a person is twenty questions nobody agreed to answer, and one that starts
background work is a queue. Keep those as direct tools beside `run_script`.

**Index the tools, document on demand.** The description lists each bound
tool by name and the first line of its description, which is enough to write
most scripts. For a large catalog, add a `tool_docs` tool that returns one
tool's full description and schema by name, so arguments are looked up when
needed instead of carried on every turn.

**Help with wrong names.** The likeliest failure is a call to a function that
isn't bound, often a name the model knows from another API. Lua reports it as
"attempt to call a nil value (global 'x')", which reads like a typo. Matching
that message and suggesting the closest bound names (`String.jaro_distance/2`
works) turns a stuck agent into a one-line fix.
