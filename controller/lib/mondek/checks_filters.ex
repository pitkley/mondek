# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ChecksFilters do
  @moduledoc false

  alias Mondek.{Inspection, OverviewFilters}

  @choices %{
    "health" => [
      {"OK", "Healthy"},
      {"WARN", "Warning"},
      {"CRIT", "Critical"},
      {"UNKNOWN", "Unknown"},
      {"not_measured", "Not measured"}
    ],
    "freshness" => [
      {"fresh", "Fresh"},
      {"stale", "Overdue measurement"},
      {"unavailable", "Collection unavailable"},
      {"awaiting", "Awaiting measurement"}
    ],
    "status" => [{"active", "Active"}, {"retired", "Retired"}, {"all", "All results"}]
  }

  def fields do
    OverviewFilters.fields() ++
      [
        {"group", "Group"},
        {"health", "Health"},
        {"freshness", "Measurement"},
        {"status", "Inventory"}
      ]
  end

  def params(values) do
    params =
      Enum.reduce(@choices, OverviewFilters.params(values), fn {field, choices}, params ->
        value = values[field]
        if List.keymember?(choices, value, 0), do: Map.put(params, field, value), else: params
      end)

    case values["group"] do
      value when is_binary(value) and byte_size(value) in [70, 71] ->
        if Regex.match?(~r/\A(?:group|target)-[0-9a-f]{64}\z/, value),
          do: Map.put(params, "group", value),
          else: params

      _ ->
        params
    end
  end

  defdelegate reset_pages(filters), to: OverviewFilters

  def remove(filters, field) when field in ["environment", "target"],
    do: OverviewFilters.remove(filters, field)

  def remove(filters, field), do: Map.delete(filters, field)

  def selected(filters, field) when field in ["environment", "target"],
    do: OverviewFilters.selected(filters, field)

  def selected(filters, field), do: if(filters[field], do: {filters[field], ""})

  def put(filters, field, value) when field in ["environment", "target"],
    do: OverviewFilters.put(filters, field, value)

  def put(filters, field, {key, ""}), do: Map.put(filters, field, key)

  def options(field, search, selected \\ nil)

  def options(field, search, selected) when field in ["environment", "target"],
    do: OverviewFilters.options(field, search, selected, :checks)

  def options("group", search, selected) do
    search
    |> Inspection.check_group_options(selected)
    |> Enum.map(&Map.put(&1, :show_key, false))
  end

  def options(field, search, selected) do
    for {key, label} <- Map.fetch!(@choices, field),
        if(selected,
          do: selected == {key, ""},
          else: String.contains?(String.downcase(label), String.downcase(search))
        ) do
      %{key: key, kind: "", label: label}
    end
  end
end
