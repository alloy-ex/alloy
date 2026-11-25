defmodule Alloy.Tool.Validation do
  @moduledoc false

  alias Alloy.Tool.Registry
  alias ExJsonSchema.Schema
  alias ExJsonSchema.Schema.{Ref, Root}
  alias ExJsonSchema.Validator

  # Optional dependency: consumers using required-key validation need not install it.
  @compile {:no_warn_undefined, [Schema, Ref, Root, Validator]}

  @literal_keywords ~w(const enum default examples)
  @schema_map_keywords ~w(properties patternProperties definitions $defs dependencies)

  @spec prepare(map(), :required | :schema, map()) :: {map(), map()}
  def prepare(_tools, :required, _cache), do: {%{}, %{}}

  def prepare(tools, :schema, cache) do
    unless Code.ensure_loaded?(Schema) do
      raise ArgumentError,
            "tool_validation: :schema requires the optional :ex_json_schema dependency"
    end

    # Retain only the current tool set, keyed by exact schema contents. Comparing
    # before JSON normalization preserves duplicate-key rejection on cache misses.
    cache =
      Map.new(tools, fn {name, tool} ->
        source = tool |> Registry.to_inline() |> Map.fetch!(:input_schema)

        entry =
          case Map.get(cache, name) do
            {^source, resolved} ->
              {source, resolved}

            _ ->
              schema = json(source)
              local_refs!(schema)
              resolved = resolve_schema!(schema, name)
              resolved = normalize_literal_property_schemas!(resolved)
              {source, resolved}
          end

        {name, entry}
      end)

    {Map.new(cache, fn {name, {_source, resolved}} -> {name, resolved} end), cache}
  end

  @doc false
  # Preflights an `:output_schema` at config/prepare time when `:ex_json_schema`
  # is available: always rejects external `$ref`s so the remote resolver is never
  # invoked, and validates Draft 4/6/7 schemas eagerly (allowing newer dialects
  # such as Draft 2020-12 to pass through to native provider enforcement).
  @spec preflight_output_schema!(map(), String.t()) :: :ok
  def preflight_output_schema!(schema, name) when is_map(schema) do
    if Code.ensure_loaded?(Schema) do
      local_refs!(schema)

      try do
        _resolved = schema |> Schema.resolve() |> normalize_literal_property_schemas!()
        :ok
      rescue
        error ->
          cond do
            error.__struct__ == ExJsonSchema.Schema.UnsupportedSchemaVersionError ->
              :ok

            error.__struct__ in [
              ExJsonSchema.Schema.InvalidReferenceError,
              ExJsonSchema.Schema.InvalidSchemaError
            ] ->
              reraise ArgumentError,
                      "Invalid output_schema #{inspect(name)}: #{Exception.message(error)}",
                      __STACKTRACE__

            true ->
              reraise error, __STACKTRACE__
          end
      end
    else
      :ok
    end
  end

  @doc false
  # Validates decoded structured output against `schema` using `:ex_json_schema`
  # when available and supported, or returns `:fallback` for basic structural
  # validation when the optional dep is absent or the dialect is unsupported.
  @spec validate_output(map(), term(), String.t()) :: :ok | {:error, String.t()} | :fallback
  def validate_output(schema, decoded, _name) when is_map(schema) do
    if Code.ensure_loaded?(Schema) do
      local_refs!(schema)

      try do
        resolved = schema |> Schema.resolve() |> normalize_literal_property_schemas!()

        case Validator.validate(resolved, decoded) do
          :ok ->
            :ok

          {:error, errors} ->
            details = Enum.map_join(errors, "; ", fn {error, path} -> "#{path}: #{error}" end)
            {:error, "Structured output failed schema validation: #{details}"}
        end
      rescue
        error ->
          if error.__struct__ == ExJsonSchema.Schema.UnsupportedSchemaVersionError do
            :fallback
          else
            reraise error, __STACKTRACE__
          end
      end
    else
      :fallback
    end
  end

  @spec check(map(), String.t(), map()) :: :ok | {:error, String.t(), nil}
  def check(input, name, schemas) do
    case Map.fetch(schemas, name) do
      :error -> :ok
      {:ok, schema} -> validate(schema, json(input), name)
    end
  rescue
    error in Jason.EncodeError ->
      {:error, "Invalid input for #{name}: #{Exception.message(error)}", nil}

    error ->
      if error.__struct__ in [
           ExJsonSchema.Schema.InvalidReferenceError,
           ExJsonSchema.Schema.InvalidSchemaError
         ] do
        {:error, "Invalid schema for #{name}: #{Exception.message(error)}", nil}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp validate(schema, input, name) do
    case Validator.validate(schema, input) do
      :ok ->
        :ok

      {:error, errors} ->
        details = Enum.map_join(errors, "; ", fn {error, path} -> "#{path}: #{error}" end)
        {:error, "Invalid input for #{name}: #{details}", nil}
    end
  end

  defp json(value), do: value |> Jason.encode!(maps: :strict) |> Jason.decode!()

  defp resolve_schema!(schema, name) do
    Schema.resolve(schema)
  rescue
    error ->
      if error.__struct__ == ExJsonSchema.Schema.UnsupportedSchemaVersionError do
        dialect = Map.get(schema, "$schema")

        reraise ArgumentError,
                "tool #{inspect(name)} uses an unsupported JSON Schema $schema dialect " <>
                  "#{inspect(dialect)} (tool_validation: :schema supports drafts 4, 6, and 7)",
                __STACKTRACE__
      else
        reraise error, __STACKTRACE__
      end
  end

  defp local_refs!(schema) do
    {defined_ids, refs} = collect_scopes_and_refs(schema, "", MapSet.new(), [])
    # Dynamic struct!/2 avoids a compile-time dependency on optional ex_json_schema.
    root = struct!(Root, refs: Map.new(defined_ids, &{&1, true}))
    Enum.each(refs, &validate_local_ref!(&1, root))
  end

  # Mirrors ExJsonSchema.Schema.resolve_with_root/3 and resolve_property/3
  # (verified against ex_json_schema 0.11.x): tracks $id/id scopes on every map
  # (including schema-map containers like $defs/properties), skips
  # const/enum/default/examples everywhere, and only descends into maps directly
  # inside lists (leaving nested lists untouched).
  defp collect_scopes_and_refs(map, scope, defined_ids, refs) when is_map(map) do
    {next_scope, defined_ids} = advance_scope(map, scope, defined_ids)

    Enum.reduce(map, {defined_ids, refs}, fn
      {key, _value}, acc when key in @literal_keywords ->
        acc

      {"$ref", ref}, {ids, ref_acc} when is_binary(ref) ->
        {ids, [{ref, next_scope} | ref_acc]}

      {_key, value}, {ids, ref_acc} when is_map(value) ->
        collect_scopes_and_refs(value, next_scope, ids, ref_acc)

      {_key, values}, {ids, ref_acc} when is_list(values) ->
        Enum.reduce(values, {ids, ref_acc}, fn
          item, {i, r} when is_map(item) -> collect_scopes_and_refs(item, next_scope, i, r)
          _non_map, acc -> acc
        end)

      {_key, _value}, acc ->
        acc
    end)
  end

  defp collect_scopes_and_refs(_value, _scope, defined_ids, refs), do: {defined_ids, refs}

  # ExJsonSchema skips @literal_keywords during resolve_property/3 even when
  # used as property/definition names inside @schema_map_keywords. That skips
  # both $ref resolution (losing enclosing $id/id scope or raising at call time)
  # and attribute sanitization (e.g. adding "properties": %{} for
  # additionalProperties: false). Resolve skipped $refs against their inherited
  # scope, reject unsupported nested $id/id and non-schema $ref targets, and
  # apply the same attribute sanitization across resolved.schema and resolved.refs.
  defp normalize_literal_property_schemas!(%{schema: root_schema, refs: refs} = resolved) do
    normalized = normalize_node!(root_schema, resolved, "", false)

    normalized_refs =
      Map.new(refs, fn
        # Each resolved.refs key is already the post-$id scope for its value.
        {url, v} when is_map(v) and not is_struct(v) ->
          {url, normalize_map_entries!(v, resolved, url, false)}

        {url, v} ->
          {url, v}
      end)

    %{resolved | schema: normalized, refs: normalized_refs}
  end

  defp normalize_node!(value, _resolved, _scope, _skipped?) when is_struct(value), do: value

  defp normalize_node!(map, resolved, scope, skipped?) when is_map(map) do
    if skipped? and has_nested_id?(map) do
      raise ArgumentError,
            "tool schemas do not support $id/id inside properties named const/enum/default/examples"
    end

    next_scope = advance_scope_only(map, scope)
    normalize_map_entries!(map, resolved, next_scope, skipped?)
  end

  defp normalize_node!(values, resolved, scope, skipped?) when is_list(values) do
    Enum.map(values, &normalize_node!(&1, resolved, scope, skipped?))
  end

  defp normalize_node!(other, _resolved, _scope, _skipped?), do: other

  defp normalize_map_entries!(map, resolved, scope, skipped?) do
    updated =
      Map.new(map, fn
        {key, value} when key in @literal_keywords ->
          {key, value}

        {key, value}
        when key in @schema_map_keywords and is_map(value) and not is_struct(value) ->
          {key, normalize_schema_map!(value, resolved, scope, skipped?)}

        {"$ref", ref} when is_struct(ref) ->
          assert_valid_ref_target!(ref, to_string(ref), resolved)
          {"$ref", ref}

        {"$ref", ref} when skipped? and is_binary(ref) ->
          {"$ref", resolve_skipped_ref!(ref, scope, resolved)}

        {key, value} ->
          {key, normalize_node!(value, resolved, scope, skipped?)}
      end)

    if skipped?, do: sanitize_ex_json_schema_attributes(updated), else: updated
  end

  defp normalize_schema_map!(map, resolved, scope, skipped?) do
    if skipped? and has_nested_id?(map) do
      raise ArgumentError,
            "tool schemas do not support $id/id inside properties named const/enum/default/examples"
    end

    next_scope = advance_scope_only(map, scope)

    Map.new(map, fn
      {key, value} ->
        {key, normalize_node!(value, resolved, next_scope, skipped? or key in @literal_keywords)}
    end)
  end

  defp has_nested_id?(%{"$ref" => ref}) when is_binary(ref), do: false
  defp has_nested_id?(%{"$id" => id}) when is_binary(id), do: true
  defp has_nested_id?(%{"id" => id}) when is_binary(id), do: true
  defp has_nested_id?(_map), do: false

  # Mirrors ExJsonSchema.Schema.sanitize_attributes/1 for subschemas skipped
  # under @literal_keywords property names.
  defp sanitize_ex_json_schema_attributes(schema) do
    schema
    |> maybe_add_empty_properties()
    |> maybe_add_additional_items()
    |> maybe_add_content_encoding()
  end

  defp maybe_add_empty_properties(schema) do
    if Enum.any?(~w(patternProperties additionalProperties), &Map.has_key?(schema, &1)) and
         not Map.has_key?(schema, "properties") do
      Map.put(schema, "properties", %{})
    else
      schema
    end
  end

  defp maybe_add_additional_items(schema) do
    if is_list(schema["items"]) and not Map.has_key?(schema, "additionalItems") do
      Map.put(schema, "additionalItems", true)
    else
      schema
    end
  end

  defp maybe_add_content_encoding(schema) do
    if Map.has_key?(schema, "contentMediaType") and not Map.has_key?(schema, "contentEncoding") do
      Map.put(schema, "contentEncoding", nil)
    else
      schema
    end
  end

  defp resolve_skipped_ref!("#" <> _ = ref, scope, resolved) do
    scoped_str = scoped_ref_string(ref, scope)
    parsed_ref = Ref.from_string(scoped_str, resolved)

    unless Ref.cached?(parsed_ref, resolved) do
      raise ArgumentError,
            "tool schemas require local $ref values, got: #{inspect(ref)} " <>
              "(resolves to uncached #{inspect(scoped_str)} under $id scope #{inspect(scope)})"
    end

    assert_valid_ref_target!(parsed_ref, ref, resolved)
    parsed_ref
  end

  defp resolve_skipped_ref!(ref, _scope, _resolved) do
    raise ArgumentError, "tool schemas require local $ref values, got: #{inspect(ref)}"
  end

  defp assert_valid_ref_target!(parsed_ref, display_ref, resolved) do
    case Schema.get_fragment(resolved, parsed_ref) do
      {:ok, target} when is_map(target) or is_boolean(target) ->
        :ok

      {:ok, target} ->
        raise ArgumentError,
              "tool schema $ref #{inspect(display_ref)} must target a schema object or boolean, got: #{inspect(target)}"

      {:error, _reason} ->
        raise ArgumentError,
              "tool schema contains unresolved local $ref: #{inspect(display_ref)}"
    end
  end

  defp advance_scope_only(%{"$ref" => ref}, scope) when is_binary(ref) or is_struct(ref),
    do: scope

  defp advance_scope_only(%{"$id" => id}, scope) when is_binary(id), do: merge_scope(scope, id)
  defp advance_scope_only(%{"id" => id}, scope) when is_binary(id), do: merge_scope(scope, id)
  defp advance_scope_only(_map, scope), do: scope

  defp advance_scope(%{"$ref" => ref}, scope, defined_ids) when is_binary(ref),
    do: {scope, defined_ids}

  defp advance_scope(%{"$id" => id}, scope, defined_ids) when is_binary(id) do
    next = merge_scope(scope, id)
    {next, MapSet.put(defined_ids, next)}
  end

  defp advance_scope(%{"id" => id}, scope, defined_ids) when is_binary(id) do
    next = merge_scope(scope, id)
    {next, MapSet.put(defined_ids, next)}
  end

  defp advance_scope(_map, scope, defined_ids), do: {scope, defined_ids}

  # Mirrors ExJsonSchema.Schema.resolve_with_id/4.
  defp merge_scope(scope, id) do
    case URI.parse(scope) do
      %URI{host: nil} = uri -> to_string(%URI{uri | fragment: nil}) <> id
      uri -> uri |> URI.merge(id) |> to_string()
    end
  end

  # Mirrors ExJsonSchema.Schema.resolve_property/3 and delegates cache-key
  # matching to ExJsonSchema.Schema.Ref so preflight and resolution cannot drift.
  defp validate_local_ref!({"#" <> _ = ref, ref_scope}, root) do
    scoped_str = scoped_ref_string(ref, ref_scope)
    parsed_ref = Ref.from_string(scoped_str, root)

    unless Ref.cached?(parsed_ref, root) do
      raise ArgumentError,
            "tool schemas require local $ref values, got: #{inspect(ref)} " <>
              "(resolves to uncached #{inspect(scoped_str)} under $id scope #{inspect(ref_scope)})"
    end
  end

  defp validate_local_ref!({ref, _ref_scope}, _root) do
    raise ArgumentError, "tool schemas require local $ref values, got: #{inspect(ref)}"
  end

  defp scoped_ref_string(ref, ref_scope) do
    ref_uri = URI.parse(ref)

    case URI.parse(ref_scope) do
      %URI{host: nil} -> ref_uri
      scope_uri -> URI.merge(scope_uri, ref_uri)
    end
    |> to_string()
  end
end
