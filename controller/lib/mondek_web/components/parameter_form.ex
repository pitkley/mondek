# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ParameterForm do
  @moduledoc "Shared scalar parameter inputs for individual and compatible bulk edits."
  use Phoenix.Component

  attr :id_prefix, :string, required: true
  attr :name_prefix, :string, default: "params"

  attr :fixed_hint, :string,
    default: "Fixed by the source. This binding stays with its existing history."

  attr :schema, :map, required: true
  attr :values, :map, default: %{}
  attr :mixed_fields, :list, default: []
  attr :resolved_fields, :list, default: []
  attr :error, :any, default: nil
  attr :error_id, :string, default: nil

  def fields(assigns) do
    assigns = assign(assigns, fields: ordered_fields(assigns.schema))

    ~H"""
    <div class="form-grid">
      <div :for={{key, field} <- @fields} class="field">
        <label for={@id_prefix <> "-" <> key}>
          {field_label(@schema, key)}<span :if={field["unit"]}> ({field["unit"]})</span>
        </label>
        <label :if={key in @mixed_fields} class="bulk-mixed-choice">
          <input type="hidden" name={"resolved[" <> key <> "]"} value="false" />
          <input
            type="checkbox"
            name={"resolved[" <> key <> "]"}
            value="true"
            checked={key in @resolved_fields}
          /> Current values differ. Set one value for all selected checks.
        </label>
        <select
          :if={field["type"] == "boolean" && !field["choices"]}
          id={@id_prefix <> "-" <> key}
          name={@name_prefix <> "[" <> key <> "]"}
          disabled={unresolved?(key, @mixed_fields, @resolved_fields)}
          aria-invalid={if @error, do: "true"}
          aria-describedby={help_ids(@id_prefix, key, @error, @error_id)}
        >
          <option :if={!Map.has_key?(@values, key)} value="" disabled selected>Choose a value</option>
          <option value="true" selected={input_value(@values[key]) == "true"}>Enabled</option>
          <option value="false" selected={input_value(@values[key]) == "false"}>Disabled</option>
        </select>
        <input
          :if={field["type"] != "boolean" && !field["choices"]}
          id={@id_prefix <> "-" <> key}
          name={@name_prefix <> "[" <> key <> "]"}
          type={if field["type"] in ["number", "integer"], do: "number", else: "text"}
          value={@values[key]}
          disabled={unresolved?(key, @mixed_fields, @resolved_fields)}
          required={field["type"] in ["number", "integer"]}
          min={field["minimum"]}
          max={field["maximum"]}
          step={
            if field["type"] == "integer", do: "1", else: if(field["type"] == "number", do: "any")
          }
          maxlength={field["max_length"]}
          aria-invalid={if @error, do: "true"}
          aria-describedby={help_ids(@id_prefix, key, @error, @error_id)}
        />
        <select
          :if={is_list(field["choices"]) && length(field["choices"]) > 1}
          id={@id_prefix <> "-" <> key}
          name={@name_prefix <> "[" <> key <> "]"}
          disabled={unresolved?(key, @mixed_fields, @resolved_fields)}
          aria-invalid={if @error, do: "true"}
          aria-describedby={help_ids(@id_prefix, key, @error, @error_id)}
        >
          <option :if={!Map.has_key?(@values, key)} value="" disabled selected>Choose a value</option>
          <option
            :for={choice <- field["choices"]}
            value={input_value(choice)}
            selected={input_value(@values[key]) == input_value(choice)}
          >
            {input_value(choice)}
          </option>
        </select>
        <input
          :if={is_list(field["choices"]) && length(field["choices"]) == 1}
          id={@id_prefix <> "-" <> key}
          name={@name_prefix <> "[" <> key <> "]"}
          value={input_value(hd(field["choices"]))}
          readonly
          aria-describedby={help_ids(@id_prefix, key, @error, @error_id)}
        />
        <small id={@id_prefix <> "-" <> key <> "-help"}>
          {if is_list(field["choices"]) && length(field["choices"]) == 1,
            do: @fixed_hint,
            else: hint(field)}
        </small>
      </div>
    </div>
    <p :for={comparison <- @schema["comparisons"] || []} class="footnote space-top">
      {field_label(@schema, comparison["left"])} must be {if comparison["op"] == "lt",
        do: "less than",
        else: "at most"} {field_label(@schema, comparison["right"])}.
    </p>
    """
  end

  def parse(schema, params, mixed_fields \\ [], resolved_fields \\ []) do
    unresolved = mixed_fields -- resolved_fields

    cond do
      unresolved != [] ->
        {:error,
         "Choose one proposed value for #{Enum.map_join(unresolved, ", ", &field_label(schema, &1))}."}

      !is_map(params) ->
        {:error, "Supply the complete parameter set."}

      true ->
        Enum.reduce_while(schema["fields"] || %{}, {:ok, %{}}, fn {key, field}, {:ok, typed} ->
          case parse_value(field["type"], params[key]) do
            {:ok, value} ->
              {:cont, {:ok, Map.put(typed, key, value)}}

            :error ->
              {:halt, {:error, "Enter a valid #{field["type"]} for #{field_label(schema, key)}."}}
          end
        end)
    end
  end

  def field_label(schema, key),
    do: get_in(schema, ["fields", key, "label"]) || humanize(key)

  def input_value(nil), do: ""
  def input_value(value) when is_binary(value), do: value
  def input_value(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp ordered_fields(schema) do
    fields = schema["fields"] || %{}

    comparisons =
      for %{"left" => left, "right" => right} <- schema["comparisons"] || [],
          Map.has_key?(fields, left) && Map.has_key?(fields, right),
          do: {left, right}

    # A comparison reads naturally in the same order as its inputs. Keep unrelated
    # fields deterministic, then move fixed bindings below values people can edit.
    {editable, fixed} =
      fields
      |> Map.keys()
      |> Enum.sort()
      |> comparison_order(comparisons)
      |> Enum.map(&{&1, Map.fetch!(fields, &1)})
      |> Enum.split_with(fn {_key, field} -> !match?(%{"choices" => [_]}, field) end)

    editable ++ fixed
  end

  defp comparison_order([], _comparisons), do: []

  defp comparison_order(keys, comparisons) do
    case Enum.find(keys, fn key -> Enum.all?(comparisons, fn {_, right} -> right != key end) end) do
      nil ->
        # Cyclic comparisons cannot define a display order. Preserve every field
        # in stable key order rather than dropping inputs or recursing forever.
        keys

      key ->
        [
          key
          | comparison_order(
              List.delete(keys, key),
              Enum.reject(comparisons, fn {left, _} -> left == key end)
            )
        ]
    end
  end

  defp parse_value("number", value) when is_number(value), do: {:ok, value}
  defp parse_value("integer", value) when is_integer(value), do: {:ok, value}
  defp parse_value("boolean", value) when value in ["true", true], do: {:ok, true}
  defp parse_value("boolean", value) when value in ["false", false], do: {:ok, false}
  defp parse_value("string", value) when is_binary(value), do: {:ok, value}

  defp parse_value(type, value) when type in ["number", "integer"] and is_binary(value) do
    parsed = if type == "integer", do: Integer.parse(value), else: Float.parse(value)

    case parsed do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_value(_, _), do: :error

  defp unresolved?(key, mixed, resolved), do: key in mixed && key not in resolved

  defp help_ids(prefix, key, error, error_id),
    do: prefix <> "-" <> key <> "-help" <> if(error && error_id, do: " " <> error_id, else: "")

  defp hint(field) do
    [
      if(field["type"] == "integer", do: "Whole number.", else: humanize(field["type"]) <> "."),
      if(field["minimum"] != nil, do: "Minimum #{field["minimum"]}."),
      if(field["maximum"] != nil, do: "Maximum #{field["maximum"]}."),
      if(field["max_length"] != nil, do: "Up to #{field["max_length"]} bytes.")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()
end
