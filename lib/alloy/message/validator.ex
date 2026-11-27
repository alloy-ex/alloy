defmodule Alloy.Message.Validator do
  @moduledoc false
  # Validates message lists and content blocks returned by runtime callbacks
  # (such as `:steering` and `:follow_up`) before appending them to loop state,
  # keeping message block schema rules next to `Alloy.Message`.

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, Transcript}

  @doc """
  Invokes a 1-arity message callback (such as `:steering` or `:follow_up`),
  validating its returned messages and redacting crashes or invalid payloads.
  """
  @spec poll_callback(atom() | String.t(), (term() -> term()), term()) ::
          {:ok, [Message.t()]} | {:error, String.t()}
  def poll_callback(name, callback, state) when is_function(callback, 1) do
    validate_callback_messages(name, callback.(state))
  rescue
    e ->
      {:error, "#{name} callback failed (#{Sanitize.exception_summary(e, :redact)})"}
  catch
    kind, reason ->
      {:error, "#{name} callback #{kind}: #{Sanitize.exit_summary(reason, :redact)}"}
  end

  @doc """
  Validates a message list returned by a named callback, checking every message
  and content block shape plus transcript tool pairing.
  """
  @spec validate_callback_messages(atom() | String.t(), term()) ::
          {:ok, [Message.t()]} | {:error, String.t()}
  def validate_callback_messages(name, msgs) when is_list(msgs) do
    cond do
      not Enum.all?(msgs, &valid_message?/1) ->
        {:error,
         "#{name} callback returned invalid messages: expected a list of Alloy.Message structs, got #{Sanitize.shape_summary(msgs)}"}

      Transcript.validate(msgs) != :ok ->
        {:error, "#{name} callback returned messages with invalid tool pairing"}

      true ->
        {:ok, msgs}
    end
  end

  def validate_callback_messages(name, other) do
    {:error,
     "#{name} callback returned invalid messages: expected a list of Alloy.Message structs, got #{Sanitize.shape_summary(other)}"}
  end

  @doc """
  Returns `true` when `message` is a well-formed `Alloy.Message` struct with
  valid metadata and content (valid UTF-8 string or non-empty list of valid
  JSON-compatible content blocks).
  """
  @spec valid_message?(term()) :: boolean()
  def valid_message?(%Message{role: role, content: content} = msg)
      when role in [:user, :assistant] do
    (is_nil(msg.provider) or is_atom(msg.provider)) and
      optional_utf8?(msg, :model) and
      optional_utf8?(msg, :origin) and
      (valid_utf8?(content) or
         (is_list(content) and content != [] and Enum.all?(content, &valid_block?/1)))
  end

  def valid_message?(_other), do: false

  @doc """
  Returns `true` when `block` is a plain JSON-compatible content block map
  matching one of Alloy's supported block schemas.
  """
  @spec valid_block?(term()) :: boolean()
  def valid_block?(block) when is_map(block) and not is_struct(block) do
    json_compatible?(block) and
      case Map.get(block, :type) do
        "text" -> valid_text?(block)
        "thinking" -> valid_thinking?(block)
        "redacted_thinking" -> valid_utf8?(Map.get(block, :data))
        "tool_use" -> valid_tool_use?(block)
        "tool_result" -> valid_tool_result?(block)
        "image" -> valid_image?(block)
        "audio" -> valid_media?(block)
        "video" -> valid_media?(block)
        "document" -> valid_document?(block)
        _other -> false
      end
  end

  def valid_block?(_other), do: false

  defp valid_text?(block) do
    valid_utf8?(Map.get(block, :text)) and
      optional_boolean?(block, :refusal) and
      optional_utf8?(block, :phase) and
      optional_utf8?(block, :signature) and
      optional_utf8?(block, :thought_signature)
  end

  defp valid_thinking?(block) do
    valid_utf8?(Map.get(block, :thinking)) and
      optional_utf8?(block, :signature) and
      optional_utf8?(block, :thought_signature) and
      optional_utf8?(block, :source)
  end

  defp valid_tool_use?(block) do
    id = Map.get(block, :id)
    name = Map.get(block, :name)
    input = Map.get(block, :input)

    non_empty_utf8?(id) and non_empty_utf8?(name) and
      plain_map?(input) and
      optional_utf8?(block, :signature) and
      optional_utf8?(block, :thought_signature) and
      optional_plain_map?(block, :caller)
  end

  defp valid_tool_result?(block) do
    id = Map.get(block, :tool_use_id)
    content = Map.get(block, :content)

    non_empty_utf8?(id) and valid_utf8?(content) and optional_boolean?(block, :is_error)
  end

  # Reject mixed inline (:data) and URL (:url) sources and validate every
  # supplied source/metadata field so providers never crash on malformed maps.
  defp valid_image?(%{data: _, url: _}), do: false

  defp valid_image?(%{data: data} = block) do
    non_empty_utf8?(Map.get(block, :mime_type)) and valid_utf8?(data)
  end

  defp valid_image?(%{url: url} = block) do
    valid_utf8?(url) and optional_utf8?(block, :mime_type)
  end

  defp valid_image?(_block), do: false

  defp valid_media?(block) do
    not Map.has_key?(block, :url) and
      not Map.has_key?(block, :uri) and
      non_empty_utf8?(Map.get(block, :mime_type)) and
      valid_utf8?(Map.get(block, :data))
  end

  defp valid_document?(block) do
    sources = Enum.filter([:data, :uri, :file_id], &Map.has_key?(block, &1))

    non_empty_utf8?(Map.get(block, :mime_type)) and
      length(sources) == 1 and
      valid_utf8?(Map.get(block, hd(sources))) and
      optional_utf8?(block, :filename) and
      optional_utf8?(block, :title) and
      optional_utf8?(block, :origin)
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp valid_utf8?(value), do: is_binary(value) and String.valid?(value)
  defp non_empty_utf8?(value), do: valid_utf8?(value) and byte_size(value) > 0

  defp json_compatible?(value) when is_nil(value) or is_boolean(value) or is_number(value),
    do: true

  defp json_compatible?(value) when is_binary(value), do: String.valid?(value)

  defp json_compatible?(value) when is_list(value),
    do: not List.improper?(value) and Enum.all?(value, &json_compatible?/1)

  defp json_compatible?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} ->
      (valid_utf8?(k) or is_atom(k)) and json_compatible?(v)
    end)
  end

  defp json_compatible?(_other), do: false

  defp optional_utf8?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> valid_utf8?(value)
    end
  end

  defp optional_boolean?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> is_boolean(value)
    end
  end

  defp optional_plain_map?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> plain_map?(value)
    end
  end
end
