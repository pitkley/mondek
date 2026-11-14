# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckGroupsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory}
  @endpoint MondekWeb.Endpoint

  test "declared group chip gathers distinct targets without merging result identities" do
    publish([
      check("controller", "Node", "node"),
      check("database", "Node", "node"),
      check("deadline", "Miscellaneous", "misc"),
      check("ungrouped", nil, nil)
    ])

    [node] = Mondek.ChecksFilters.options("group", "Node")
    {:ok, view, _} = live(build_conn(), "/checks?group=" <> node.key)
    assert rows(view) == 2
    assert has_element?(view, "#preview-check-results", "Resource controller")
    assert has_element?(view, "#preview-check-results", "Resource database")
    refute has_element?(view, "#preview-check-results", "Resource deadline")
    render_click(view, "filter_open", %{"field" => "target"})
    render_change(view, "filter_query", %{"search" => "database"})
    render_click(view, "filter_select", %{"key" => "database", "kind" => "container"})
    assert rows(view) == 1
  end

  test "bounded group suggestions search beyond the initial twenty choices" do
    publish(
      for index <- 1..107, do: check(padded(index), "Group #{padded(index)}", padded(index))
    )

    assert length(Mondek.ChecksFilters.options("group", "")) == 20
    {:ok, view, _} = live(build_conn(), "/checks?search=browse-")
    before = rows(view)
    render_click(view, "filter_open", %{"field" => "group"})
    render_change(view, "filter_query", %{"search" => "Group 107"})
    assert has_element?(view, "[role=option]", "Group 107")
    assert rows(view) == before
    send(view.pid, :tick)
    assert has_element?(view, "[role=option]", "Group 107")
  end

  test "selected group survives result paging, a panel and a fresh connection" do
    publish(for index <- 1..67, do: check(padded(index), "Nodes", "node"))
    [group] = Mondek.ChecksFilters.options("group", "Nodes")
    path = "/checks?group=" <> group.key <> "&page=2"
    {:ok, view, _} = live(build_conn(), path)
    assert rows(view) == 30

    view
    |> element("#preview-check-results tbody tr:first-child a[data-overview-open]")
    |> render_click()

    panel_path = assert_patch(view)
    assert has_element?(view, "#overview-panel")
    {:ok, reopened, _} = live(build_conn(), panel_path)
    assert rows(reopened) == 30
    assert has_element?(reopened, ".preview-filter-chip", "Nodes")
  end

  test "group picker queries are separate from applied text search" do
    publish([check("one", "Node", "node"), check("two", "Miscellaneous", "misc")])
    {:ok, view, _} = live(build_conn(), "/checks?search=browse-")
    render_click(view, "filter_open", %{"field" => "group"})
    render_change(view, "filter_query", %{"search" => "Node"})
    assert rows(view) == 2

    assert has_element?(view, "form[phx-hook='PreviewFilterPicker'][data-search='browse-']")

    render_click(view, "filter_close", %{})
    assert rows(view) == 2
  end

  test "group identity rejects malformed selection and does not accept retired explorer controls" do
    valid = "group-" <> String.duplicate("a", 64)
    assert Mondek.ChecksFilters.params(%{"group" => valid, "page" => "3"})["group"] == valid

    for value <- ["invalid", "group-" <> String.duplicate("g", 64), "target-x"] do
      refute Mondek.ChecksFilters.params(%{"group" => value})["group"]
    end

    refute Mondek.ChecksFilters.params(%{"group_limit" => "5000", "group_search" => "Node"})[
             "group_limit"
           ]
  end

  defp rows(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#preview-check-results tbody > tr")
      |> Enum.count()

  defp padded(index), do: String.pad_leading(to_string(index), 3, "0")

  defp publish(checks) do
    assert {:ok, _} =
             Inventory.reconcile(
               control(%{
                 "installation_id" => Ecto.UUID.generate(),
                 "session_id" => Ecto.UUID.generate(),
                 "runner_label" => "Group observer",
                 "source_id" => "ui.groups",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               DateTime.utc_now()
             )
  end

  defp check(key, group_label, group_key) do
    output = %{
      "key" => key,
      "label" => "browse-#{key} result",
      "target" => %{"key" => key, "kind" => "container", "label" => "Resource #{key}"}
    }

    output =
      if group_key,
        do: Map.put(output, "group", %{"key" => group_key, "label" => group_label}),
        else: output

    %{
      "key" => key,
      "label" => "browse-#{key}",
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" => [output],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60
    }
  end
end
