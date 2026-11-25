defmodule Alloy.OutputSchema do
  @moduledoc """
  Normalized representation of a portable `:output_schema` option.

  Built by `Alloy.Agent.Config.from_opts/1` and `Alloy.Agent.State.prepare/2`
  from either a plain JSON Schema map or a wrapper map
  `%{name: ..., schema: ..., strict: ...}`. Stored on `state.config.output_schema`
  so middleware can inspect it and built-in providers can translate it into
  their wire formats without re-normalizing per request.
  """

  alias Alloy.Provider
  alias Alloy.Tool.Validation

  @default_name "alloy_output"
  @name_pattern ~r/^[a-zA-Z0-9_-]{1,64}$/
  @wrapper_keys [:name, :schema, :strict, "name", "schema", "strict"]

  @enforce_keys [:name, :schema, :strict]
  defstruct [:name, :schema, :strict]

  @type t :: %__MODULE__{
          name: String.t(),
          schema: map(),
          strict: boolean()
        }

  @doc """
  Normalizes `:output_schema` into `%Alloy.OutputSchema{}` or `nil`.

  Accepts `nil`, a `%Alloy.OutputSchema{}` struct (re-validated), a plain JSON
  Schema map (defaulting `name: "alloy_output"` and `strict: true`), or a
  wrapper map `%{schema: map, name: ..., strict: ...}`. Raises `ArgumentError`
  on invalid shapes, non-JSON-encodable schemas, or invalid local `$ref`s /
  schemas when `:ex_json_schema` is loaded.
  """
  @spec normalize!(term()) :: t() | nil
  def normalize!(nil), do: nil

  def normalize!(%__MODULE__{name: name, schema: schema, strict: strict}) do
    normalize_wrapper!(%{name: name, schema: schema, strict: strict})
  end

  def normalize!(%_{} = struct) do
    raise ArgumentError,
          "output_schema must be a JSON Schema map or nil, got struct: #{inspect(struct.__struct__)}"
  end

  def normalize!(spec) when is_map(spec) and map_size(spec) > 0 do
    if wrapper_map?(spec) do
      normalize_wrapper!(spec)
    else
      %__MODULE__{
        name: @default_name,
        schema: normalize_schema!(spec, @default_name),
        strict: true
      }
    end
  end

  def normalize!(other) do
    raise ArgumentError,
          "output_schema must be a non-empty JSON Schema map or nil, got: #{inspect(other)}"
  end

  @doc false
  @spec wire(term()) :: t() | nil
  def wire(nil), do: nil
  def wire(%__MODULE__{} = spec), do: spec
  def wire(raw), do: normalize!(raw)

  @doc false
  @spec merge_extra_body(map(), map(), String.t()) :: map()
  def merge_extra_body(body, extra_body, nested_key)
      when is_map(body) and is_map(extra_body) and is_binary(nested_key) do
    case {Map.get(body, nested_key), Map.get(extra_body, nested_key)} do
      {base_nested, extra_nested} when is_map(base_nested) and is_map(extra_nested) ->
        body
        |> Map.merge(extra_body)
        |> Map.put(nested_key, Map.merge(base_nested, extra_nested))

      _other ->
        Map.merge(body, extra_body)
    end
  end

  @doc """
  Decodes final assistant text as JSON and validates it against `spec`.

  Uses full Draft 4/6/7 validation via optional `:ex_json_schema` when loaded
  and the schema dialect is supported; falls back to top-level JSON `"type"`
  and `"required"` checks otherwise.
  """
  @spec decode_and_validate(String.t() | nil, t()) :: {:ok, term()} | {:error, String.t()}
  def decode_and_validate(text, %__MODULE__{name: name, schema: schema}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} ->
        validate_decoded(decoded, schema, name)

      {:error, reason} ->
        {:error, "Structured output is not valid JSON: #{Exception.message(reason)}"}
    end
  end

  def decode_and_validate(_other, _spec) do
    {:error, "Structured output is missing assistant text"}
  end

  # ── Normalization ────────────────────────────────────────────────────────

  defp wrapper_map?(map) do
    has_schema? = Map.has_key?(map, :schema) or Map.has_key?(map, "schema")
    has_type? = Map.has_key?(map, :type) or Map.has_key?(map, "type")
    only_wrapper_keys? = Enum.all?(Map.keys(map), &(&1 in @wrapper_keys))
    has_schema? and not has_type? and only_wrapper_keys?
  end

  defp normalize_wrapper!(spec) do
    name = fetch_unique_key!(spec, :name, "name", @default_name)
    strict = fetch_unique_key!(spec, :strict, "strict", true)
    raw_schema = fetch_unique_key!(spec, :schema, "schema", nil)

    validate_name!(name)
    validate_strict!(strict)

    if is_map(raw_schema) and not is_struct(raw_schema) and map_size(raw_schema) > 0 do
      %__MODULE__{
        name: name,
        schema: normalize_schema!(raw_schema, name),
        strict: strict
      }
    else
      raise ArgumentError,
            "output_schema :schema must be a non-empty JSON Schema map, got: #{inspect(raw_schema)}"
    end
  end

  defp fetch_unique_key!(map, atom_key, string_key, default) do
    case {Map.fetch(map, atom_key), Map.fetch(map, string_key)} do
      {{:ok, _}, {:ok, _}} ->
        raise ArgumentError,
              "output_schema cannot specify both #{inspect(atom_key)} and #{inspect(string_key)}"

      {{:ok, val}, :error} ->
        val

      {:error, {:ok, val}} ->
        val

      {:error, :error} ->
        default
    end
  end

  defp validate_name!(name) when is_binary(name) do
    unless Regex.match?(@name_pattern, name) do
      raise ArgumentError,
            "output_schema :name must match ^[a-zA-Z0-9_-]{1,64}$, got: #{inspect(name)}"
    end
  end

  defp validate_name!(name) do
    raise ArgumentError,
          "output_schema :name must be a string matching ^[a-zA-Z0-9_-]{1,64}$, got: #{inspect(name)}"
  end

  defp validate_strict!(strict) when is_boolean(strict), do: :ok

  defp validate_strict!(strict) do
    raise ArgumentError, "output_schema :strict must be a boolean, got: #{inspect(strict)}"
  end

  defp normalize_schema!(schema, name) do
    # Encode strictly BEFORE stringifying keys so duplicate atom/string keys
    # (e.g. %{type: "object", "type" => "array"}) fail loudly instead of silently
    # colliding in Provider.stringify_keys/1.
    normalized =
      try do
        schema
        |> Jason.encode!(maps: :strict)
        |> Jason.decode!()
        |> Provider.stringify_keys()
      rescue
        e in [Jason.EncodeError, ArgumentError] ->
          reraise ArgumentError,
                  "Invalid output_schema #{inspect(name)}: #{Exception.message(e)}",
                  __STACKTRACE__
      end

    Validation.preflight_output_schema!(normalized, name)
    normalized
  end

  # ── Validation ───────────────────────────────────────────────────────────

  defp validate_decoded(decoded, schema, name) do
    case Validation.validate_output(schema, decoded, name) do
      :ok -> {:ok, decoded}
      {:error, reason} -> {:error, reason}
      :fallback -> validate_basic(decoded, schema)
    end
  end

  defp validate_basic(decoded, schema) do
    with :ok <- check_type(decoded, Map.get(schema, "type")),
         :ok <- check_required(decoded, Map.get(schema, "required")) do
      {:ok, decoded}
    end
  end

  defp check_type(_val, nil), do: :ok
  defp check_type(val, "object") when is_map(val), do: :ok
  defp check_type(val, "array") when is_list(val), do: :ok
  defp check_type(val, "string") when is_binary(val), do: :ok
  defp check_type(val, "integer") when is_integer(val), do: :ok
  defp check_type(val, "integer") when is_float(val) and trunc(val) == val, do: :ok
  defp check_type(val, "number") when is_number(val), do: :ok
  defp check_type(val, "boolean") when is_boolean(val), do: :ok
  defp check_type(nil, "null"), do: :ok

  defp check_type(val, types) when is_list(types) do
    if Enum.any?(types, &(check_type(val, &1) == :ok)) do
      :ok
    else
      {:error, "Structured output did not match any expected JSON type #{inspect(types)}"}
    end
  end

  defp check_type(_val, expected) when is_binary(expected) do
    {:error, "Structured output expected JSON type #{inspect(expected)}"}
  end

  defp check_type(_val, _other), do: :ok

  defp check_required(val, required) when is_map(val) and is_list(required) do
    missing = Enum.filter(required, &(is_binary(&1) and not Map.has_key?(val, &1)))

    case missing do
      [] -> :ok
      keys -> {:error, "Structured output missing required keys: #{Enum.join(keys, ", ")}"}
    end
  end

  defp check_required(_val, _required), do: :ok
end
