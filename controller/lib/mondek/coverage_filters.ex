# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CoverageFilters do
  @moduledoc false

  alias Mondek.{ObserverFilters, OverviewFilters}

  def params(values) do
    filters = Map.merge(OverviewFilters.params(values), ObserverFilters.params(values))

    filters =
      case values["diagnostic_page"] do
        page when is_binary(page) and byte_size(page) <= 7 ->
          case Integer.parse(page) do
            {number, ""} when number > 1 ->
              Map.put(filters, "diagnostic_page", Integer.to_string(number))

            _ ->
              filters
          end

        _ ->
          filters
      end

    if values["status"] == "attention",
      do: Map.put(filters, "status", "attention"),
      else: filters
  end

  def fields, do: OverviewFilters.fields() ++ ObserverFilters.fields() ++ [{"status", "Coverage"}]

  def reset_pages(filters),
    do: filters |> OverviewFilters.reset_pages() |> Map.delete("diagnostic_page")

  def selected(%{"status" => "attention"}, "status"), do: {"attention", ""}
  def selected(_, "status"), do: nil

  def selected(filters, field) when field in ~w(runner_id source_id),
    do: ObserverFilters.selected(filters, field)

  def selected(filters, field), do: OverviewFilters.selected(filters, field)

  def options(field, query, selection \\ nil)

  def options(field, query, selection) when field in ~w(runner_id source_id),
    do: ObserverFilters.options(field, query, selection)

  def options("status", query, selection) do
    label = "Needs attention"

    if selection == {"attention", ""} ||
         (is_nil(selection) && String.contains?(String.downcase(label), String.downcase(query))) do
      [%{key: "attention", kind: "", label: label, show_key: false}]
    else
      []
    end
  end

  def options(field, query, selection),
    do: OverviewFilters.options(field, query, selection, :coverage)

  def remove(filters, "status"), do: Map.delete(filters, "status")

  def remove(filters, field) when field in ~w(runner_id source_id),
    do: ObserverFilters.remove(filters, field)

  def remove(filters, field), do: OverviewFilters.remove(filters, field)

  def put(filters, "status", {"attention", ""}), do: Map.put(filters, "status", "attention")

  def put(filters, field, selection) when field in ~w(runner_id source_id),
    do: ObserverFilters.put(filters, field, selection)

  def put(filters, field, selection), do: OverviewFilters.put(filters, field, selection)
end
