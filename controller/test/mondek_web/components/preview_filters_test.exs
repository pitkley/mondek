# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewFiltersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MondekWeb.PreviewFilters

  test "independent instances own their listboxes, options, and input IDs" do
    document =
      LazyHTML.from_document(picker(id: "incidents-filter") <> picker(id: "results-filter"))

    for id <- ["incidents-filter", "results-filter"] do
      input = LazyHTML.query(document, "##{id}-input")
      assert LazyHTML.attribute(input, "aria-controls") == ["#{id}-options"]
      assert Enum.count(LazyHTML.query(document, "##{id}-options[role=listbox]")) == 1

      assert Enum.count(LazyHTML.query(document, "##{id}-options ##{id}-field-environment")) ==
               1
    end

    ids = document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
    assert Enum.uniq(ids) == ids
  end

  test "editing an applied chip moves the only input into that chip's slot" do
    document =
      picker(
        id: "results-filter",
        chips: [%{field: "environment", name: "Environment", label: "Production"}],
        picker: %{
          field: "environment",
          title: "Environment",
          value: "Production",
          options: [%{key: "staging", label: "Staging", kind: ""}]
        }
      )
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "[role=combobox]")) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               ".preview-filter-chip #results-filter-input[value=Production]"
             )
           ) == 1

    assert Enum.empty?(LazyHTML.query(document, "#results-filter-chip-environment"))

    assert Enum.count(LazyHTML.query(document, "#results-filter-option-0[phx-value-key=staging]")) ==
             1
  end

  defp picker(overrides) do
    assigns = [
      picker: nil,
      chips: [],
      fields: [{"environment", "Environment", "globe"}],
      search: nil,
      remove: fn _ -> "/filters" end,
      clear_search: "/filters",
      form_label: "Filters",
      label: "Search",
      placeholder: "Search"
    ]

    render_component(&PreviewFilters.filter_picker/1, Keyword.merge(assigns, overrides))
  end
end
