# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ScalarFilterPicker do
  @moduledoc "Pure suggestions and chip labels for scalar list filters; owners apply their own URL/default policy."

  def draft(fields, choices, field, query, empty_values \\ [nil, "", "all"])
      when is_function(choices, 1) do
    with {^field, title, _icon} <- List.keyfind(fields, field, 0) do
      value = text(query)
      needle = value |> String.trim() |> String.downcase()

      options =
        for {key, label} <- choices.(field),
            key not in empty_values,
            String.contains?(String.downcase(label), needle),
            do: %{key: key, label: label, kind: "", show_key: false}

      %{field: field, title: title, value: value, options: options}
    else
      _ -> nil
    end
  end

  def chips(fields, filters, choices, empty_values \\ [nil, "", "all"]) do
    for {field, name, _icon} <- fields,
        key = filters[field],
        key not in empty_values_for(empty_values, field),
        do: %{field: field, name: name, label: label(choices.(field), key)}
  end

  defp empty_values_for(values, field) when is_function(values, 1), do: values.(field)
  defp empty_values_for(values, _field), do: values

  def label(choices, key) do
    case List.keyfind(choices, key, 0) do
      {_, label} -> label
      nil -> to_string(key || "")
    end
  end

  def text(value) when is_binary(value) do
    if String.valid?(value),
      do: value |> String.replace(<<0>>, "") |> String.slice(0, 200),
      else: ""
  end

  def text(_), do: ""
end
