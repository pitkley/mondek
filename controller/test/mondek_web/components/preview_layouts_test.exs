# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewLayoutsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias MondekWeb.PreviewLayouts

  test "one navigation promotes incidents and marks management pages selected" do
    html = render_component(&PreviewLayouts.navigation/1, active: :runners)
    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, "a[aria-current=page]") |> LazyHTML.text() |> String.trim() ==
             "Runners"

    refute html =~ "Open existing UI"
    refute html =~ "Existing pages"
    refute html =~ "Choose theme"
    assert html =~ "Help &amp; setup"

    [_, incidents, checks, maintenance | _] =
      LazyHTML.query(doc, ".pf-v6-c-nav__link") |> Enum.map(&LazyHTML.text/1)

    assert {String.trim(incidents), String.trim(checks), String.trim(maintenance)} ==
             {"Incidents", "Checks", "Maintenance"}

    assert html =~ "Manage"
    assert html =~ "Licenses and credits"
  end

  test "shell owns a named focus target and accessible dismissible feedback" do
    html =
      render_component(&PreviewLayouts.app/1,
        active: :runners,
        page_title: "Runners",
        flash: %{"info" => "Saved", "error" => "Changed"},
        inner_block: [%{inner_block: fn _, _ -> "Page content" end}]
      )

    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, "main#main-content[tabindex='-1'][aria-label=Runners]")
           |> LazyHTML.text() =~ "Page content"

    assert LazyHTML.query(doc, "[role=status]") |> LazyHTML.text() =~ "Saved"
    assert LazyHTML.query(doc, "[role=alert]") |> LazyHTML.text() =~ "Changed"
    assert Enum.count(LazyHTML.query(doc, "button[phx-click='lv:clear-flash']")) == 2
    refute html =~ "class=\"ui-workflow\""
  end
end
