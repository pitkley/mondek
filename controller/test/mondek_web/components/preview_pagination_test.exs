# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewPaginationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias MondekWeb.PreviewPagination

  test "component paging uses the same numbered range and explicit target without submitting its form" do
    html =
      render_component(&PreviewPagination.pagination/1,
        page: 2,
        size: 25,
        total: 80,
        label: "Review pages",
        event: "page",
        target: "#bulk-configuration"
      )

    document = LazyHTML.from_document(html)
    buttons = LazyHTML.query(document, "button")
    assert Enum.all?(LazyHTML.attribute(buttons, "type"), &(&1 == "button"))
    assert Enum.all?(LazyHTML.attribute(buttons, "phx-target"), &(&1 == "#bulk-configuration"))

    assert LazyHTML.query(document, "[aria-current=page]") |> LazyHTML.text() |> String.trim() ==
             "2"

    assert LazyHTML.query(document, ".preview-page-range > span:not([aria-hidden])")
           |> LazyHTML.text()
           |> String.trim() == "26–50 of 80"

    assert Enum.count(LazyHTML.query(document, "a")) == 0
  end

  test "URL paging retains patch navigation and stable range reservation" do
    html =
      render_component(&PreviewPagination.pagination/1,
        page: 1,
        size: 25,
        total: 103,
        label: "Check pages",
        url: &"/configuration?page=#{&1}"
      )

    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "a[href='/configuration?page=2']") |> Enum.count() == 2

    assert LazyHTML.query(document, ".preview-page-range > span[aria-hidden]")
           |> LazyHTML.text()
           |> String.trim() == "103–103 of 103"

    assert Enum.count(LazyHTML.query(document, "button")) == 0
  end
end
