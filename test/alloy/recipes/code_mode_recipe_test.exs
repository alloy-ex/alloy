defmodule Alloy.Recipes.CodeModeTest do
  @moduledoc """
  Verifies the code mode recipe in `docs/recipes/code-mode.md` verbatim.

  If this test breaks, the recipe doc is wrong — fix both together.
  """
  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider

  # ── Recipe module (keep in sync with docs/recipes/code-mode.md) ─────────

  defmodule CodeMode do
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

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defmodule ListOrders do
    @behaviour Alloy.Tool

    @impl true
    def name, do: "list_orders"

    @impl true
    def description, do: "Every order: id, status and total.\nPaginates server-side."

    @impl true
    def input_schema, do: %{type: "object", properties: %{}}

    @impl true
    def result_type, do: :structured

    @impl true
    def execute(_input, %{orders: orders}), do: {:ok, Jason.encode!(orders), orders}
  end

  defmodule GetCustomer do
    @behaviour Alloy.Tool

    @impl true
    def name, do: "get_customer"

    @impl true
    def description, do: "One customer by order id."

    @impl true
    def input_schema,
      do: %{type: "object", properties: %{order_id: %{type: "integer"}}, required: ["order_id"]}

    @impl true
    def execute(%{"order_id" => 2}, _context), do: {:error, "order 2 has no customer"}
    def execute(%{"order_id" => id}, _context), do: {:ok, "customer-#{id}"}
  end

  @orders [
    %{"id" => 1, "status" => "open", "total" => 30},
    %{"id" => 2, "status" => "open", "total" => 12},
    %{"id" => 3, "status" => "shipped", "total" => 99}
  ]

  defp run_script(script) do
    tool = CodeMode.tool([ListOrders, GetCustomer])
    tool.execute.(%{"script" => script}, %{orders: @orders})
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  test "a script composes several tools in one call" do
    script = """
    local open, total = {}, 0
    for _, order in ipairs(list_orders({})) do
      if order.status == "open" then
        total = total + order.total
        local customer, err = get_customer({ order_id = order.id })
        open[#open + 1] = customer or ("unknown: " .. err)
      end
    end
    return { customers = open, total = total }
    """

    assert {:ok, text} = run_script(script)

    assert Jason.decode!(text) == %{
             "customers" => ["customer-1", "unknown: order 2 has no customer"],
             "total" => 42
           }
  end

  test "the description indexes the bound tools by their first line" do
    tool = CodeMode.tool([ListOrders, GetCustomer])

    assert tool.description =~ "- list_orders: Every order: id, status and total.\n"
    assert tool.description =~ "- get_customer: One customer by order id."
    refute tool.description =~ "Paginates"
  end

  test "a script that runs away is stopped by the instruction budget" do
    assert {:error, message} = run_script("while true do end")
    assert message =~ "instruction budget exceeded"
  end

  test "a script cannot build a huge string" do
    assert {:error, message} = run_script(~S|return string.rep("x", 2^24)|)
    assert message =~ "too large"
  end

  test "the host is out of reach" do
    assert {:error, message} = run_script(~S|return os.getenv("HOME")|)
    assert message =~ "sandboxed"
  end

  test "an agent calls tools through run_script" do
    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([
          %{
            type: "tool_use",
            id: "call_1",
            name: "run_script",
            input: %{"script" => "return #list_orders({})"}
          }
        ]),
        TestProvider.text_response("There are 3 orders.")
      ])

    {:ok, result} =
      Alloy.run("How many orders?",
        provider: {TestProvider, agent_pid: provider},
        tools: [CodeMode.tool([ListOrders, GetCustomer])],
        context: %{orders: @orders}
      )

    assert result.status == :completed
    assert result.text == "There are 3 orders."

    assert Enum.any?(result.messages, fn
             %{content: [%{type: "tool_result", content: "3"} | _]} -> true
             _ -> false
           end)
  end
end
