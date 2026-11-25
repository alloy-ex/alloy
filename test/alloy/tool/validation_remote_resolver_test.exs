defmodule Alloy.Tool.ValidationRemoteResolverTest do
  use ExUnit.Case, async: false

  alias Alloy.OutputSchema
  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Tool
  alias Alloy.Tool.Validation

  @moduletag :ex_json_schema

  setup do
    test_pid = self()
    previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)

    Application.put_env(:ex_json_schema, :remote_schema_resolver, fn url ->
      send(test_pid, {:remote_resolver_called, url})
      raise "remote schema resolver must never be invoked for #{url}"
    end)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ex_json_schema, :remote_schema_resolver)
        val -> Application.put_env(:ex_json_schema, :remote_schema_resolver, val)
      end
    end)

    :ok
  end

  defp schema_tool(schema) do
    Tool.inline(
      name: "submit",
      description: "Submit",
      input_schema: schema,
      execute: fn _input, _ctx -> {:ok, "ok"} end
    )
  end

  test "rejects $id with fragment plus $ref property referencing #/definitions without calling remote resolver" do
    schema = %{
      "$id" => "https://example.invalid/schema#anchor",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "properties" => %{"$ref" => %{"$ref" => "#/definitions/x"}}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(schema)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}
  end

  test "rejects draft-04 id with fragment plus local pointer $ref without calling remote resolver" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-04/schema#",
      "id" => "https://example.invalid/schema#anchor",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "properties" => %{"value" => %{"$ref" => "#/definitions/x"}}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(schema)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}
  end

  test "rejects nested relative $id with fragment that shifts $ref scope to uncached location" do
    schema = %{
      "$id" => "https://example.invalid/dir/root.json",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "properties" => %{
        "nested" => %{
          "$id" => "sub.json#part",
          "type" => "object",
          "properties" => %{"val" => %{"$ref" => "#/definitions/x"}}
        }
      }
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(schema)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}
  end

  test "accepts $id without fragment and property literally named $ref without calling remote resolver" do
    schema = %{
      "$id" => "https://example.invalid/schema",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "properties" => %{"$ref" => %{"$ref" => "#/definitions/x"}},
      "required" => ["$ref"]
    }

    {schemas, _cache} = Validation.prepare(%{"submit" => schema_tool(schema)}, :schema, %{})
    assert :ok = Validation.check(%{"$ref" => "hello"}, "submit", schemas)
    assert {:error, _, nil} = Validation.check(%{"$ref" => 123}, "submit", schemas)
    refute_received {:remote_resolver_called, _}
  end

  test "accepts exact locally defined anchor $ref under $id without calling remote resolver" do
    schema = %{
      "$id" => "https://example.invalid/schema",
      "type" => "object",
      "definitions" => %{
        "str" => %{"$id" => "#str_anchor", "type" => "string"}
      },
      "properties" => %{"value" => %{"$ref" => "#str_anchor"}}
    }

    {schemas, _cache} = Validation.prepare(%{"submit" => schema_tool(schema)}, :schema, %{})
    assert :ok = Validation.check(%{"value" => "ok"}, "submit", schemas)
    assert {:error, _, nil} = Validation.check(%{"value" => 42}, "submit", schemas)
    refute_received {:remote_resolver_called, _}
  end

  test "ignores $id inside ignored keyword names in properties and dependencies so uncached IDs are never trusted" do
    for ignored_name <- ~w(default const enum examples) do
      schema_in_properties = %{
        "$id" => "https://example.invalid/schema#anchor",
        "type" => "object",
        "definitions" => %{"x" => %{"type" => "string"}},
        "properties" => %{
          ignored_name => %{"$id" => "https://example.invalid/schema", "type" => "string"},
          "value" => %{"$ref" => "#/definitions/x"}
        }
      }

      assert_raise ArgumentError, ~r/local \$ref/, fn ->
        Validation.prepare(%{"submit" => schema_tool(schema_in_properties)}, :schema, %{})
      end

      refute_received {:remote_resolver_called, _}

      schema_in_dependencies = %{
        "$id" => "https://example.invalid/schema#anchor",
        "type" => "object",
        "definitions" => %{"x" => %{"type" => "string"}},
        "dependencies" => %{
          ignored_name => %{"$id" => "https://example.invalid/schema", "type" => "object"}
        },
        "properties" => %{
          "value" => %{"$ref" => "#/definitions/x"}
        }
      }

      assert_raise ArgumentError, ~r/local \$ref/, fn ->
        Validation.prepare(%{"submit" => schema_tool(schema_in_dependencies)}, :schema, %{})
      end

      refute_received {:remote_resolver_called, _}
    end
  end

  test "ignores $id and draft-04 id inside nested lists that ExJsonSchema does not traverse" do
    nested_dollar_id = %{
      "$id" => "https://example.invalid/schema#anchor",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "x-data" => [[%{"$id" => "https://example.invalid/schema"}]],
      "properties" => %{"value" => %{"$ref" => "#/definitions/x"}}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(nested_dollar_id)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}

    nested_draft4_id = %{
      "$schema" => "http://json-schema.org/draft-04/schema#",
      "id" => "https://example.invalid/schema#anchor",
      "type" => "object",
      "definitions" => %{"x" => %{"type" => "string"}},
      "x-data" => [[%{"id" => "https://example.invalid/schema"}]],
      "properties" => %{"value" => %{"$ref" => "#/definitions/x"}}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(nested_draft4_id)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}
  end

  test "rejects empty-fragment $id with # ref and accepts fragmentless $id with # self-ref" do
    empty_frag = %{
      "$id" => "https://example.invalid/schema#",
      "type" => "object",
      "properties" => %{"child" => %{"$ref" => "#"}}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(empty_frag)}, :schema, %{})
    end

    refute_received {:remote_resolver_called, _}

    valid_self_ref = %{
      "$id" => "https://example.invalid/schema",
      "type" => "object",
      "properties" => %{"child" => %{"$ref" => "#"}}
    }

    {schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(valid_self_ref)}, :schema, %{})

    assert :ok = Validation.check(%{"child" => %{}}, "submit", schemas)
    assert {:error, _, nil} = Validation.check(%{"child" => "not-an-object"}, "submit", schemas)
    refute_received {:remote_resolver_called, _}
  end

  test "distinguishes literal keyword values from identically named properties containing prohibited $ref" do
    # Literal schema-level keywords hold data values, not schemas, so $ref strings inside them are allowed.
    for {kw, kw_value, valid_input} <- [
          {"default", %{"$ref" => "https://example.invalid/literal"}, %{"ok" => "yes"}},
          {"const", %{"$ref" => "https://example.invalid/literal"},
           %{"$ref" => "https://example.invalid/literal"}},
          {"enum", [%{"$ref" => "https://example.invalid/literal"}],
           %{"$ref" => "https://example.invalid/literal"}},
          {"examples", [%{"$ref" => "https://example.invalid/literal"}], %{"ok" => "yes"}}
        ] do
      literal_schema = %{
        "type" => "object",
        kw => kw_value,
        "properties" => %{"ok" => %{"type" => "string"}}
      }

      {schemas, _cache} =
        Validation.prepare(%{"submit" => schema_tool(literal_schema)}, :schema, %{})

      assert :ok = Validation.check(valid_input, "submit", schemas)
    end

    # Property names matching literal keywords are still property schemas and must reject prohibited $ref at prepare/3.
    for prop <- ~w(default const enum examples) do
      prop_ref_schema = %{
        "type" => "object",
        "properties" => %{
          prop => %{"$ref" => "https://example.invalid/schema"}
        }
      }

      assert_raise ArgumentError, ~r/local \$ref/, fn ->
        Validation.prepare(%{"submit" => schema_tool(prop_ref_schema)}, :schema, %{})
      end
    end

    # Dangling local $ref inside literal-named property fails at prepare/3, while valid local $ref succeeds.
    dangling_prop_ref = %{
      "type" => "object",
      "properties" => %{"const" => %{"$ref" => "#/definitions/missing"}}
    }

    assert_raise ArgumentError, ~r/unresolved local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(dangling_prop_ref)}, :schema, %{})
    end

    valid_prop_ref = %{
      "type" => "object",
      "definitions" => %{"s" => %{"type" => "string"}},
      "properties" => %{"default" => %{"$ref" => "#/definitions/s"}}
    }

    {valid_schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(valid_prop_ref)}, :schema, %{})

    assert :ok = Validation.check(%{"default" => "hi"}, "submit", valid_schemas)
    assert {:error, _, nil} = Validation.check(%{"default" => 123}, "submit", valid_schemas)

    refute_received {:remote_resolver_called, _}
  end

  test "rejects container-level $ref and $id inside $defs while keeping literal $ref property names working" do
    defs_remote_ref = %{
      "type" => "object",
      "$defs" => %{"$ref" => "https://example.invalid/remote"}
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(defs_remote_ref)}, :schema, %{})
    end

    defs_remote_id = %{
      "type" => "object",
      "$defs" => %{
        "$id" => "https://example.invalid/remote#",
        "a" => %{"$ref" => "#"}
      }
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(defs_remote_id)}, :schema, %{})
    end

    literal_ref_prop = %{
      "type" => "object",
      "properties" => %{"$ref" => %{"type" => "string"}}
    }

    {schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(literal_ref_prop)}, :schema, %{})

    assert :ok = Validation.check(%{"$ref" => "ok"}, "submit", schemas)
    refute_received {:remote_resolver_called, _}
  end

  test "enforces additionalProperties: false beneath properties named default, const, enum, and examples" do
    test_pid = self()

    for prop <- ~w(default const enum examples) do
      schema = %{
        "type" => "object",
        "properties" => %{
          prop => %{"type" => "object", "additionalProperties" => false}
        }
      }

      tool =
        Alloy.Tool.inline(
          name: "submit",
          description: "test",
          input_schema: schema,
          execute: fn input, _ctx ->
            send(test_pid, {:executed, prop, input})
            {:ok, "ok"}
          end
        )

      {schemas, _cache} = Validation.prepare(%{"submit" => tool}, :schema, %{})

      assert :ok = Validation.check(%{prop => %{}}, "submit", schemas)

      assert {:error, err, nil} =
               Validation.check(%{prop => %{"unexpected" => "rejected"}}, "submit", schemas)

      assert err =~ "additional properties"

      # Executor-level regression: invalid input never reaches the tool.
      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "c1", name: "submit", input: %{prop => %{"unexpected" => "rejected"}}}
          ]),
          TestProvider.text_response("done")
        ])

      assert {:ok, _result} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [tool],
                 tool_validation: :schema
               )

      refute_received {:executed, ^prop, _}
    end

    # A local $ref targeting literal data with an unresolved $ref returns a
    # clean validation error instead of crashing.
    literal_target_schema = %{
      "type" => "object",
      "default" => %{"$ref" => "https://example.invalid/x"},
      "properties" => %{"a" => %{"$ref" => "#/default"}}
    }

    {literal_schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(literal_target_schema)}, :schema, %{})

    assert {:error, err, nil} = Validation.check(%{"a" => %{}}, "submit", literal_schemas)
    assert err =~ "Invalid schema for submit"
    refute_received {:remote_resolver_called, _}
  end

  test "preserves nested $id scope for $ref under properties named default, const, enum, and examples" do
    test_pid = self()

    for prop <- ~w(default const enum examples) do
      scoped_schema = %{
        "$id" => "https://example.invalid/root",
        "type" => "object",
        "definitions" => %{"x" => %{"type" => "string"}},
        "properties" => %{
          "nested" => %{
            "$id" => "nested",
            "type" => "object",
            "definitions" => %{"x" => %{"type" => "integer"}},
            "properties" => %{
              "ordinary" => %{"$ref" => "#/definitions/x"},
              prop => %{"$ref" => "#/definitions/x"}
            }
          }
        }
      }

      tool =
        Alloy.Tool.inline(
          name: "submit",
          description: "test",
          input_schema: scoped_schema,
          execute: fn input, _ctx ->
            send(test_pid, {:scoped_executed, prop, input})
            {:ok, "ok"}
          end
        )

      {schemas, _cache} = Validation.prepare(%{"submit" => tool}, :schema, %{})

      assert :ok =
               Validation.check(%{"nested" => %{"ordinary" => 1, prop => 2}}, "submit", schemas)

      assert {:error, _, nil} =
               Validation.check(
                 %{"nested" => %{"ordinary" => 1, prop => "invalid"}},
                 "submit",
                 schemas
               )

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{
              id: "c1",
              name: "submit",
              input: %{"nested" => %{"ordinary" => 1, prop => "invalid"}}
            }
          ]),
          TestProvider.text_response("done")
        ])

      assert {:ok, _result} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [tool],
                 tool_validation: :schema
               )

      refute_received {:scoped_executed, ^prop, _}
    end

    # Rejects nested $id inside a literal-named property schema and rejects $ref targeting scalar literals.
    nested_id_in_default = %{
      "type" => "object",
      "properties" => %{
        "default" => %{
          "$id" => "https://example.invalid/inner",
          "type" => "string"
        }
      }
    }

    assert_raise ArgumentError, ~r/do not support \$id\/id/, fn ->
      Validation.prepare(%{"submit" => schema_tool(nested_id_in_default)}, :schema, %{})
    end

    scalar_target_ref = %{
      "type" => "object",
      "properties" => %{
        "x" => %{"const" => 42},
        "default" => %{"$ref" => "#/properties/x/const"}
      }
    }

    assert_raise ArgumentError, ~r/must target a schema object or boolean/, fn ->
      Validation.prepare(%{"submit" => schema_tool(scalar_target_ref)}, :schema, %{})
    end

    ordinary_scalar_target_ref = %{
      "type" => "object",
      "properties" => %{
        "x" => %{"const" => 42},
        "y" => %{"$ref" => "#/properties/x/const"}
      }
    }

    assert_raise ArgumentError, ~r/must target a schema object or boolean/, fn ->
      Validation.prepare(%{"submit" => schema_tool(ordinary_scalar_target_ref)}, :schema, %{})
    end

    # Boolean subschema $ref targets remain valid per JSON Schema Draft 6/7.
    bool_target_ref = %{
      "type" => "object",
      "definitions" => %{"always_ok" => true},
      "properties" => %{"default" => %{"$ref" => "#/definitions/always_ok"}}
    }

    {bool_schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(bool_target_ref)}, :schema, %{})

    assert :ok = Validation.check(%{"default" => "anything"}, "submit", bool_schemas)

    refute_received {:remote_resolver_called, _}
  end

  test "validates https:// draft-07 $schema and raises ArgumentError naming unsupported $schema dialects" do
    https_draft7_schema = %{
      "$schema" => "https://json-schema.org/draft-07/schema#",
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}}
    }

    {draft7_schemas, _cache} =
      Validation.prepare(%{"submit" => schema_tool(https_draft7_schema)}, :schema, %{})

    assert :ok = Validation.check(%{"a" => "ok"}, "submit", draft7_schemas)
    assert {:error, _, nil} = Validation.check(%{"a" => 1}, "submit", draft7_schemas)

    draft_2020_schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}}
    }

    assert_raise ArgumentError,
                 ~r/unsupported JSON Schema \$schema dialect "https:\/\/json-schema\.org\/draft\/2020-12\/schema".*drafts 4, 6, and 7/,
                 fn ->
                   Validation.prepare(%{"submit" => schema_tool(draft_2020_schema)}, :schema, %{})
                 end

    refute_received {:remote_resolver_called, _}
  end

  test "ex_json_schema 0.11.x internal API contract used by Validation preflight remains intact" do
    root_mod = ExJsonSchema.Schema.Root
    ref_mod = ExJsonSchema.Schema.Ref
    schema_mod = ExJsonSchema.Schema

    assert Code.ensure_loaded?(root_mod)
    assert Code.ensure_loaded?(ref_mod)
    assert Code.ensure_loaded?(schema_mod)
    assert function_exported?(ref_mod, :from_string, 2)
    assert function_exported?(ref_mod, :cached?, 2)
    assert function_exported?(schema_mod, :get_fragment, 2)

    root = struct!(root_mod, schema: %{"type" => "object"}, refs: %{}, version: 7)
    assert Map.has_key?(root, :schema)
    assert Map.has_key?(root, :refs)
    assert Map.has_key?(root, :version)
  end

  test "rejects remote $ref inside list values under properties and dependencies even with custom $id" do
    schema_with_list_ref = %{
      "$id" => "http://json-schema.org/custom",
      "type" => "object",
      "properties" => %{
        "a" => [%{"$ref" => "https://169.254.169.254/latest/meta-data/"}]
      }
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(schema_with_list_ref)}, :schema, %{})
    end

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      OutputSchema.normalize!(schema_with_list_ref)
    end

    dep_list_ref = %{
      "$id" => "http://json-schema.org/custom",
      "type" => "object",
      "dependencies" => %{
        "a" => [%{"$ref" => "https://169.254.169.254/latest/meta-data/"}]
      }
    }

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Validation.prepare(%{"submit" => schema_tool(dep_list_ref)}, :schema, %{})
    end

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      OutputSchema.normalize!(dep_list_ref)
    end

    refute_received {:remote_resolver_called, _}
  end

  test "OutputSchema.decode_and_validate/2 rescues runtime InvalidReferenceError on #/default -> literal $ref" do
    schema = %{
      "type" => "object",
      "default" => %{"$ref" => "https://example.invalid/x"},
      "properties" => %{
        "a" => %{"$ref" => "#/default"}
      }
    }

    spec = OutputSchema.normalize!(schema)

    assert {:error, %{kind: :invalid_schema, decoded: nil, message: msg}} =
             OutputSchema.decode_and_validate(~s({"a":"x"}), spec)

    assert msg =~ "Invalid output_schema"
    refute_received {:remote_resolver_called, _}
  end
end
