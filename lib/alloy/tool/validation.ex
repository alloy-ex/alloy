defmodule Alloy.Tool.Validation do
  @moduledoc false

  alias Alloy.Internal.Sanitize
  alias Alloy.Tool.Registry
  alias ExJsonSchema.Schema
  alias ExJsonSchema.Schema.{Ref, Root}
  alias ExJsonSchema.Validator

  require Logger

  # Optional dependency: consumers using required-key validation need not install it.
  @compile {:no_warn_undefined, [Schema, Ref, Root, Validator]}

  @literal_keywords ~w(const enum default examples)
  @schema_map_keywords ~w(properties patternProperties definitions $defs dependencies dependentSchemas)
  @max_output_validation_errors 10
  @max_output_validation_bytes 1_000

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
              local_refs!(schema, :tool)
              resolved = resolve_schema!(schema, name)
              resolved = normalize_literal_property_schemas!(resolved, :tool)
              {source, resolved}
          end

        {name, entry}
      end)

    {Map.new(cache, fn {name, {_source, resolved}} -> {name, resolved} end), cache}
  end

  @doc false
  # Preflights an `:output_schema` at config/prepare time: always rejects
  # external `$ref`s (even without `:ex_json_schema`), and resolves Draft 4/6/7
  # schemas eagerly when `:ex_json_schema` is loaded (returning `:fallback` for
  # newer dialects such as Draft 2020-12 or when `:ex_json_schema` is absent).
  @spec prepare_output_schema!(map(), String.t()) :: {:ok, term()} | :fallback
  def prepare_output_schema!(schema, name) when is_map(schema) do
    validate_schema_dialect!(schema, name)
    local_refs!(schema, :output)

    if Code.ensure_loaded?(Schema) do
      try do
        resolved = schema |> Schema.resolve() |> normalize_literal_property_schemas!(:output)
        {:ok, resolved}
      rescue
        error ->
          cond do
            error.__struct__ == ExJsonSchema.Schema.UnsupportedSchemaVersionError ->
              Logger.warning(
                "output_schema #{inspect(name)} uses unsupported $schema dialect " <>
                  "#{inspect(Map.get(schema, "$schema"))} for :ex_json_schema; " <>
                  "falling back to top-level JSON type and required checks only"
              )

              :fallback

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
      :fallback
    end
  end

  defp validate_schema_dialect!(schema, name) do
    case Map.fetch(schema, "$schema") do
      :error ->
        :ok

      {:ok, dialect} when is_binary(dialect) ->
        if String.trim(dialect) != "" do
          :ok
        else
          raise ArgumentError,
                "Invalid output_schema #{inspect(name)}: \"$schema\" must be a non-empty string, " <>
                  "got: #{Sanitize.inspect_bounded(dialect)}"
        end

      {:ok, bad_dialect} ->
        raise ArgumentError,
              "Invalid output_schema #{inspect(name)}: \"$schema\" must be a non-empty string, " <>
                "got: #{Sanitize.inspect_bounded(bad_dialect)}"
    end
  end

  @doc false
  # Returns true when a cached resolution term matches the current runtime
  # environment and struct shape (preventing forged caches or missing optional
  # dependency crashes).
  @spec valid_resolved_output?(term()) :: boolean()
  def valid_resolved_output?(:fallback), do: true

  def valid_resolved_output?({:ok, root}) do
    Code.ensure_loaded?(Validator) and is_map(root) and Map.get(root, :__struct__) == Root
  end

  def valid_resolved_output?(_other), do: false

  @doc false
  # Validates decoded structured output against an already-resolved schema.
  @spec validate_resolved_output(term(), term()) ::
          :ok | {:error, String.t()} | {:error, :invalid_schema, String.t()}
  def validate_resolved_output(resolved, decoded) do
    case Validator.validate(resolved, decoded) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         "Structured output failed schema validation: #{format_validation_errors(errors)}"}
    end
  rescue
    error ->
      case rescue_schema_error(error, :output) do
        {:ok, message} -> {:error, :invalid_schema, message}
        :reraise -> reraise error, __STACKTRACE__
      end
  end

  defp format_validation_errors(errors) do
    total = length(errors)

    summary =
      errors
      |> Enum.take(@max_output_validation_errors)
      |> Enum.map_join("; ", fn {error, path} -> "#{path}: #{error}" end)

    summary =
      if total > @max_output_validation_errors do
        "#{summary} (+#{total - @max_output_validation_errors} more)"
      else
        summary
      end

    Sanitize.cap_bytes(summary, @max_output_validation_bytes)
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
      case rescue_schema_error(error, {:tool, name}) do
        {:ok, message} -> {:error, message, nil}
        :reraise -> reraise error, __STACKTRACE__
      end
  end

  defp rescue_schema_error(error, target) do
    prefix =
      case target do
        :output -> "Invalid output_schema"
        {:tool, name} -> "Invalid schema for #{name}"
      end

    cond do
      error.__struct__ in [
        ExJsonSchema.Schema.InvalidReferenceError,
        ExJsonSchema.Schema.InvalidSchemaError
      ] ->
        {:ok, "#{prefix}: #{Exception.message(error)}"}

      error.__struct__ == ExJsonSchema.Schema.MissingJsonDecoderError ->
        {:ok,
         if(target == :output,
           do: missing_json_decoder_message(),
           else: "#{prefix}: #{missing_json_decoder_message()}"
         )}

      true ->
        :reraise
    end
  end

  defp missing_json_decoder_message do
    "Schema uses contentMediaType \"application/json\", which requires " <>
      "`config :ex_json_schema, decode_json: &Jason.decode/1`"
  end

  defp validate(schema, input, name) do
    case Validator.validate(schema, input) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, "Invalid input for #{name}: #{format_validation_errors(errors)}", nil}
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

  defp local_refs!(schema, subject) do
    {defined_ids, refs} = collect_scopes_and_refs(schema, "", MapSet.new(), [], true)

    # Dynamic struct!/2 avoids a compile-time dependency on optional ex_json_schema.
    root =
      if Code.ensure_loaded?(Schema),
        do: struct!(Root, refs: Map.new(defined_ids, &{&1, true})),
        else: nil

    Enum.each(refs, &validate_local_ref!(&1, defined_ids, root, subject))
  end

  # Tracks $id/id scopes across schema maps and descends into schema-map
  # containers (properties, $defs, etc.) including literal-named property keys
  # and container-level $ref entries, while skipping schema-level literal
  # keywords (const/enum/default/examples) and nested non-map list elements.
  # Inside literal-named properties (e.g. properties.default), $ref entries are
  # still collected and checked, but $id/id values are not added to defined_ids
  # because ExJsonSchema does not cache them during Schema.resolve/1.
  defp collect_scopes_and_refs(map, scope, defined_ids, refs, record_ids?) when is_map(map) do
    {next_scope, defined_ids} = advance_scope(map, scope, defined_ids, record_ids?)

    Enum.reduce(map, {defined_ids, refs}, fn
      {key, _value}, acc when key in @literal_keywords ->
        acc

      {key, value}, {ids, ref_acc} when key in @schema_map_keywords and is_map(value) ->
        {map_scope, ids} = advance_scope(value, next_scope, ids, record_ids?)

        Enum.reduce(value, {ids, ref_acc}, fn
          {"$ref", ref}, {i, r} when is_binary(ref) ->
            {i, [{ref, map_scope} | r]}

          {prop, subschema}, {i, r} when is_map(subschema) ->
            collect_scopes_and_refs(
              subschema,
              map_scope,
              i,
              r,
              record_ids? and prop not in @literal_keywords
            )

          {prop, subschemas}, {i, r} when is_list(subschemas) ->
            collect_map_list(
              subschemas,
              map_scope,
              i,
              r,
              record_ids? and prop not in @literal_keywords
            )

          {_prop, _other}, inner ->
            inner
        end)

      {"$ref", ref}, {ids, ref_acc} when is_binary(ref) ->
        {ids, [{ref, next_scope} | ref_acc]}

      {_key, value}, {ids, ref_acc} when is_map(value) ->
        collect_scopes_and_refs(value, next_scope, ids, ref_acc, record_ids?)

      {_key, values}, {ids, ref_acc} when is_list(values) ->
        collect_map_list(values, next_scope, ids, ref_acc, record_ids?)

      {_key, _value}, acc ->
        acc
    end)
  end

  defp collect_scopes_and_refs(_value, _scope, defined_ids, refs, _record_ids?),
    do: {defined_ids, refs}

  defp collect_map_list(values, scope, ids, ref_acc, record_ids?) do
    Enum.reduce(values, {ids, ref_acc}, fn
      item, {i, r} when is_map(item) -> collect_scopes_and_refs(item, scope, i, r, record_ids?)
      _non_map, acc -> acc
    end)
  end

  # ExJsonSchema skips @literal_keywords during resolve_property/3 even when
  # used as property/definition names inside @schema_map_keywords. That skips
  # both $ref resolution (losing enclosing $id/id scope or raising at call time)
  # and attribute sanitization (e.g. adding "properties": %{} for
  # additionalProperties: false). Resolve skipped $refs against their inherited
  # scope, reject unsupported nested $id/id and non-schema $ref targets, and
  # apply the same attribute sanitization across resolved.schema and resolved.refs.
  defp normalize_literal_property_schemas!(%{schema: root_schema, refs: refs} = resolved, subject) do
    normalized = normalize_node!(root_schema, resolved, "", false, subject)

    normalized_refs =
      Map.new(refs, fn
        # Each resolved.refs key is already the post-$id scope for its value.
        {url, v} when is_map(v) and not is_struct(v) ->
          {url, normalize_map_entries!(v, resolved, url, false, subject)}

        {url, v} ->
          {url, v}
      end)

    %{resolved | schema: normalized, refs: normalized_refs}
  end

  defp normalize_node!(value, _resolved, _scope, _skipped?, _subject) when is_struct(value),
    do: value

  defp normalize_node!(map, resolved, scope, skipped?, subject) when is_map(map) do
    if skipped? and has_nested_id?(map) do
      raise ArgumentError,
            "#{schema_subject(subject, :do_not)} support $id/id inside properties named const/enum/default/examples"
    end

    next_scope = advance_scope_only(map, scope)
    normalize_map_entries!(map, resolved, next_scope, skipped?, subject)
  end

  defp normalize_node!(values, resolved, scope, skipped?, subject) when is_list(values) do
    Enum.map(values, &normalize_node!(&1, resolved, scope, skipped?, subject))
  end

  defp normalize_node!(other, _resolved, _scope, _skipped?, _subject), do: other

  defp normalize_map_entries!(map, resolved, scope, skipped?, subject) do
    updated =
      Map.new(map, fn
        {key, value} when key in @literal_keywords ->
          {key, value}

        {key, value}
        when key in @schema_map_keywords and is_map(value) and not is_struct(value) ->
          {key, normalize_schema_map!(value, resolved, scope, skipped?, subject)}

        {"$ref", ref} when is_struct(ref) ->
          assert_valid_ref_target!(ref, to_string(ref), resolved, subject)
          {"$ref", ref}

        {"$ref", ref} when skipped? and is_binary(ref) ->
          {"$ref", resolve_skipped_ref!(ref, scope, resolved, subject)}

        {key, value} ->
          {key, normalize_node!(value, resolved, scope, skipped?, subject)}
      end)

    if skipped?, do: sanitize_ex_json_schema_attributes(updated), else: updated
  end

  defp normalize_schema_map!(map, resolved, scope, skipped?, subject) do
    if skipped? and has_nested_id?(map) do
      raise ArgumentError,
            "#{schema_subject(subject, :do_not)} support $id/id inside properties named const/enum/default/examples"
    end

    next_scope = advance_scope_only(map, scope)

    Map.new(map, fn
      {key, value} ->
        {key,
         normalize_node!(
           value,
           resolved,
           next_scope,
           skipped? or key in @literal_keywords,
           subject
         )}
    end)
  end

  defp has_nested_id?(%{"$ref" => ref}) when is_binary(ref) or is_struct(ref), do: false
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

  defp resolve_skipped_ref!("#" <> _ = ref, scope, resolved, subject) do
    scoped_str = scoped_ref_string(ref, scope)
    parsed_ref = Ref.from_string(scoped_str, resolved)

    unless Ref.cached?(parsed_ref, resolved) do
      raise ArgumentError,
            "#{schema_subject(subject, :require)} local $ref values, got: #{inspect(ref)} " <>
              "(resolves to uncached #{inspect(scoped_str)} under $id scope #{inspect(scope)})"
    end

    assert_valid_ref_target!(parsed_ref, ref, resolved, subject)
    parsed_ref
  end

  defp resolve_skipped_ref!(ref, _scope, _resolved, subject) do
    raise ArgumentError,
          "#{schema_subject(subject, :require)} local $ref values, got: #{inspect(ref)}"
  end

  defp assert_valid_ref_target!(parsed_ref, display_ref, resolved, subject) do
    case Schema.get_fragment(resolved, parsed_ref) do
      {:ok, target} when is_map(target) or is_boolean(target) ->
        :ok

      {:ok, target} ->
        raise ArgumentError,
              "#{schema_subject(subject, :singular)} $ref #{inspect(display_ref)} must target a schema object or boolean, got: #{Sanitize.inspect_bounded(target)}"

      {:error, _reason} ->
        raise ArgumentError,
              "#{schema_subject(subject, :singular)} contains unresolved local $ref: #{inspect(display_ref)}"
    end
  end

  defp advance_scope(map, scope, defined_ids, record_ids?) do
    next = advance_scope_only(map, scope)

    if record_ids? and has_nested_id?(map),
      do: {next, MapSet.put(defined_ids, next)},
      else: {next, defined_ids}
  end

  defp advance_scope_only(%{"$ref" => ref}, scope) when is_binary(ref) or is_struct(ref),
    do: scope

  defp advance_scope_only(%{"$id" => id}, scope) when is_binary(id), do: merge_scope(scope, id)
  defp advance_scope_only(%{"id" => id}, scope) when is_binary(id), do: merge_scope(scope, id)
  defp advance_scope_only(_map, scope), do: scope

  # Mirrors ExJsonSchema.Schema.resolve_with_id/4.
  defp merge_scope(scope, id) do
    case URI.parse(scope) do
      %URI{host: nil} = uri -> to_string(%URI{uri | fragment: nil}) <> id
      uri -> uri |> URI.merge(id) |> to_string()
    end
  end

  # Mirrors ExJsonSchema.Schema.resolve_property/3 and delegates cache-key
  # matching to ExJsonSchema.Schema.Ref when loaded (falling back to the
  # defined_ids URI base check when :ex_json_schema is absent).
  defp validate_local_ref!({"#" <> _ = ref, ref_scope}, defined_ids, root, subject) do
    scoped_str = scoped_ref_string(ref, ref_scope)

    cached? =
      if root do
        scoped_str |> Ref.from_string(root) |> Ref.cached?(root)
      else
        base = scoped_str |> URI.parse() |> Map.put(:fragment, nil) |> to_string()
        base == "" or MapSet.member?(defined_ids, base)
      end

    unless cached? do
      raise ArgumentError,
            "#{schema_subject(subject, :require)} local $ref values, got: #{inspect(ref)} " <>
              "(resolves to uncached #{inspect(scoped_str)} under $id scope #{inspect(ref_scope)})"
    end
  end

  defp validate_local_ref!({ref, _ref_scope}, _defined_ids, _root, subject) do
    raise ArgumentError,
          "#{schema_subject(subject, :require)} local $ref values, got: #{inspect(ref)}"
  end

  defp schema_subject(:tool, :require), do: "tool schemas require"
  defp schema_subject(:output, :require), do: "output_schema requires"
  defp schema_subject(:tool, :do_not), do: "tool schemas do not"
  defp schema_subject(:output, :do_not), do: "output_schema does not"
  defp schema_subject(:tool, :singular), do: "tool schema"
  defp schema_subject(:output, :singular), do: "output_schema"

  defp scoped_ref_string(ref, ref_scope) do
    ref_uri = URI.parse(ref)

    case URI.parse(ref_scope) do
      %URI{host: nil} -> ref_uri
      scope_uri -> URI.merge(scope_uri, ref_uri)
    end
    |> to_string()
  end
end
