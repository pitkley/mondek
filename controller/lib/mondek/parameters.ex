# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Parameters do
  @moduledoc "The bounded scalar contract exported by a consumer, without executable code."

  def normalized_schema(%{"fields" => fields} = schema) when is_map(fields) do
    fields =
      Map.new(fields, fn {key, field} ->
        value =
          if field["type"] == "string", do: Map.put_new(field, "max_length", 2048), else: field

        {key, value}
      end)

    schema |> Map.put("fields", fields) |> Map.put_new("comparisons", []) |> normalized_json()
  end

  def normalized_schema(schema), do: schema

  def schema_fingerprint(schema) do
    :crypto.hash(:sha256, :erlang.term_to_binary(normalized_schema(schema), [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "Compare JSON values using the exact decimal numbers sent on the wire."
  def same_json?(first, second), do: normalized_json(first) === normalized_json(second)

  @doc "Normalize integral JSON floats without rounding their wire decimal value."
  def normalized_json(value) when is_float(value) do
    decimal = Decimal.from_float(value)
    if Decimal.integer?(decimal), do: Decimal.to_integer(decimal), else: value
  end

  def normalized_json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalized_json(item)} end)

  def normalized_json(value) when is_list(value), do: Enum.map(value, &normalized_json/1)
  def normalized_json(value), do: value

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp compare(first, second), do: Decimal.compare(decimal(first), decimal(second))

  def text?(value, maximum) when is_binary(value),
    do:
      String.valid?(value) and byte_size(String.trim(value)) in 1..maximum and
        not String.match?(value, ~r/[\x00-\x1f\x7f]/)

  def text?(_, _), do: false

  def validate(schema, params) do
    cond do
      not (Mondek.Protocol.json_numbers?(schema) and Mondek.Protocol.json_numbers?(params)) ->
        {:error, "JSON integer literals must contain at most 4096 decimal digits."}

      not (schema?(schema) and values?(schema, params)) ->
        {:error,
         "Supply the complete parameter set matching the current source schema and its comparisons."}

      encoded_parameter_size(params) > 16_384 ->
        {:error, "The complete parameter set must fit within 16 KiB of JSON."}

      true ->
        :ok
    end
  end

  defp encoded_parameter_size(params) do
    params = normalized_json(params)
    # Python's canonical JSON escapes non-ASCII text. Float spelling differs
    # across runtimes, so reserve the full 24-byte finite binary64 literal bound.
    float_reserve =
      Enum.reduce(params, 0, fn
        {_key, value}, total when is_float(value) ->
          total + max(0, 24 - byte_size(Jason.encode!(value)))

        _, total ->
          total
      end)

    byte_size(Jason.encode!(params, escape: :unicode_safe)) + float_reserve
  end

  def schema?(%{"fields" => fields} = schema) when is_map(fields) do
    comparisons = Map.get(schema, "comparisons", [])

    map_size(fields) <= 32 and is_list(comparisons) and length(comparisons) <= 32 and
      Enum.all?(fields, fn {name, field} -> text?(name, 128) and field?(field) end) and
      Enum.all?(comparisons, fn
        %{"left" => left, "right" => right, "op" => op} ->
          op in ["lt", "lte"] and get_in(fields, [left, "type"]) in ["number", "integer"] and
            get_in(fields, [right, "type"]) in ["number", "integer"]

        _ ->
          false
      end)
  end

  def schema?(_), do: false

  defp field?(field) when is_map(field) do
    type = field["type"]

    type in ["number", "integer", "string", "boolean"] and
      optional?(field, "label", &text?(&1, 200)) and optional?(field, "unit", &text?(&1, 64)) and
      optional?(field, "minimum", &(type in ["number", "integer"] and is_number(&1))) and
      optional?(field, "maximum", &(type in ["number", "integer"] and is_number(&1))) and
      (not Map.has_key?(field, "minimum") or not Map.has_key?(field, "maximum") or
         compare(field["minimum"], field["maximum"]) != :gt) and
      optional?(field, "max_length", &(type == "string" and is_integer(&1) and &1 in 1..2048)) and
      optional?(
        field,
        "choices",
        &(is_list(&1) and length(&1) in 1..32 and
            Enum.all?(&1, fn v -> value?(Map.delete(field, "choices"), v) end))
      )
  end

  defp field?(_), do: false
  defp optional?(map, key, check), do: not Map.has_key?(map, key) or check.(map[key])

  defp values?(schema, params) when is_map(params) do
    fields = schema["fields"]

    Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(params)) and
      Enum.all?(fields, fn {name, field} -> value?(field, params[name]) end) and
      Enum.all?(Map.get(schema, "comparisons", []), fn c ->
        if c["op"] == "lt",
          do: compare(params[c["left"]], params[c["right"]]) == :lt,
          else: compare(params[c["left"]], params[c["right"]]) != :gt
      end)
  end

  defp values?(_, _), do: false

  defp value?(field, value) do
    typed =
      case field["type"] do
        "number" ->
          is_number(value)

        "integer" ->
          is_integer(value)

        "boolean" ->
          is_boolean(value)

        "string" ->
          is_binary(value) and String.valid?(value) and
            byte_size(value) <= Map.get(field, "max_length", 2048) and
            not String.match?(value, ~r/[\x00-\x1f\x7f]/)

        _ ->
          false
      end

    typed and optional?(field, "minimum", &(compare(value, &1) != :lt)) and
      optional?(field, "maximum", &(compare(value, &1) != :gt)) and
      optional?(field, "choices", &Enum.any?(&1, fn choice -> same_json?(choice, value) end))
  end
end
