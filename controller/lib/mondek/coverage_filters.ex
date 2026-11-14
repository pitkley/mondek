# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CoverageFilters do
  @moduledoc false

  alias Mondek.OverviewFilters

  def params(values) do
    filters = OverviewFilters.params(values)

    if values["status"] == "attention",
      do: Map.put(filters, "status", "attention"),
      else: filters
  end

  def fields, do: OverviewFilters.fields() ++ [{"status", "Coverage"}]

  defdelegate reset_pages(filters), to: OverviewFilters

  def selected(%{"status" => "attention"}, "status"), do: {"attention", ""}
  def selected(_, "status"), do: nil
  def selected(filters, field), do: OverviewFilters.selected(filters, field)

  def options(field, query, selection \\ nil)

  def options("status", query, selection) do
    label = "Needs attention"

    if selection == {"attention", ""} ||
         (is_nil(selection) && String.contains?(String.downcase(label), String.downcase(query))) do
      [%{key: "attention", kind: "", label: label, show_key: false}]
    else
      []
    end
  end

  def options(field, query, selection), do: OverviewFilters.options(field, query, selection)

  def remove(filters, "status"), do: Map.delete(filters, "status")
  def remove(filters, field), do: OverviewFilters.remove(filters, field)

  def put(filters, "status", {"attention", ""}), do: Map.put(filters, "status", "attention")
  def put(filters, field, selection), do: OverviewFilters.put(filters, field, selection)
end
