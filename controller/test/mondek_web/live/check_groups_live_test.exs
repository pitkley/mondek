# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckGroupsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Inventory
  alias MondekWeb.CheckInventory

  @endpoint MondekWeb.Endpoint

  test "declared groups collect distinct targets while keeping exact target investigation" do
    publish([
      check("controller", "Node", "node"),
      check("database", "Node", "node"),
      check("deadline", "Miscellaneous", "misc"),
      check("un-grouped", nil, nil)
    ])

    {:ok, view, _} = live(build_conn(), "/checks?search=browse-")
    assert has_element?(view, "#inventory-view-targets", "By group")
    assert length(elements(view, "#inventory-target-options > button")) == 3
    view |> element("#inventory-view-list") |> render_click()
    assert length(elements(view, ".checks-result-group")) == 3
    assert has_element?(view, ".checks-group-heading h3", "Node")
    assert has_element?(view, ".checks-resource-link", "Resource controller")
    view |> element("#inventory-view-targets") |> render_click()
    view |> element("#inventory-target-options > button", "Node") |> render_click()
    assert length(elements(view, ".checks-results-table tbody tr")) == 2
    assert has_element?(view, ".checks-group-heading h3", "Node")
    refute has_element?(view, ".checks-group-heading .target-context-link")
    assert has_element?(view, ".checks-resource-link", "Resource controller")
    assert has_element?(view, ".checks-resource-link", "Resource database")

    view |> element(".checks-resource-link", "Resource database") |> render_click()
    assert has_element?(view, "#checks-target-context", "Resource database")
    assert length(elements(view, ".checks-results-table tbody tr")) == 1
    assert has_element?(view, "#checks-investigation-return")
    refute has_element?(view, ".checks-resource-link")
  end

  test "local group search finds unloaded groups without changing the open results or global filters" do
    publish(
      for index <- 1..107, do: check(padded(index), "Group #{padded(index)}", padded(index))
    )

    {:ok, view, _} = live(build_conn(), "/checks?search=browse-")
    assert length(elements(view, "#inventory-target-options > button")) == 100
    assert has_element?(view, "#inventory-group-loader", "100 of 107 groups shown")
    assert has_element?(view, "#inventory-load-more-groups")
    selected = row_ids(view)

    selected_group =
      attribute(view, "#inventory-target-options > button[aria-pressed='true']", "id")

    view |> form("#inventory-group-search-form", group_search: "Group 107") |> render_change()
    assert length(elements(view, "#inventory-target-options > button")) == 1
    assert has_element?(view, "#inventory-target-options > button", "Group 107")
    assert has_element?(view, "#inventory-search[value='browse-']")
    assert row_ids(view) == selected
    assert has_element?(view, ".checks-group-heading h3", "Group 001")
    refute has_element?(view, "#inventory-load-more-groups")

    view |> form("#inventory-group-search-form", group_search: "No such group") |> render_change()
    assert has_element?(view, ".checks-group-search-empty", "The selected results remain open")
    assert row_ids(view) == selected
    send(view.pid, :tick)
    assert row_ids(view) == selected
    assert has_element?(view, "#inventory-group-search[value='No such group']")

    view |> form("#inventory-group-search-form", group_search: "") |> render_change()
    assert has_element?(view, "##{selected_group}[aria-pressed='true']")
    assert length(elements(view, "#inventory-target-options > button")) == 100
  end

  test "cumulative loading survives updates, recovered forms, details and fresh connections" do
    publish(
      for index <- 1..107, do: check(padded(index), "Group #{padded(index)}", padded(index))
    )

    {:ok, view, _} = live(build_conn(), "/checks?search=browse-")
    selected = row_ids(view)
    view |> element("#inventory-load-more-groups") |> render_click()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["group_limit"] == "200"
    assert row_ids(view) == selected
    assert length(elements(view, "#inventory-target-options > button")) == 107
    refute has_element?(view, "#inventory-load-more-groups")
    assert has_element?(view, "#inventory-group-loader", "107 of 107 groups shown")

    render_change(view, "group_search", %{"group_search" => ""})
    refute_patched(view)
    send(view.pid, :tick)
    assert length(elements(view, "#inventory-target-options > button")) == 107
    assert row_ids(view) == selected

    result_link = view |> element(".checks-result-link") |> render_click()
    {:ok, detail, _} = follow_redirect(result_link, build_conn())
    assert has_element?(detail, ".back[href='#{path}']")

    {:ok, returned, _} =
      follow_redirect(detail |> element(".back") |> render_click(), build_conn())

    assert length(elements(returned, "#inventory-target-options > button")) == 107
    assert row_ids(returned) == selected

    {:ok, reconnected, _} = live(build_conn(), path)
    assert length(elements(reconnected, "#inventory-target-options > button")) == 107
    assert row_ids(reconnected) == selected
  end

  test "group searches survive presentation changes and remain distinct from global search" do
    publish([check("one", "Node", "node"), check("two", "Miscellaneous", "misc")])
    {:ok, view, _} = live(build_conn(), "/checks?search=browse-&group_search=Node")
    assert has_element?(view, "#inventory-group-search[value='Node']")
    view |> element("#inventory-view-list") |> render_click()
    assert length(elements(view, ".checks-results-table tbody tr")) == 2
    refute has_element?(view, "#inventory-group-search")
    view |> element("#inventory-view-targets") |> render_click()
    assert has_element?(view, "#inventory-group-search[value='Node']")
    assert length(elements(view, "#inventory-target-options > button")) == 1
  end

  test "group loading URL bounds remain independent of result paging and legacy view links" do
    filters =
      CheckInventory.normalize(%{"view" => "targets", "group_limit" => "5000", "page" => "3"})

    assert filters["group_limit"] == "1000"
    assert filters["page"] == "3"
    assert filters["view"] == "targets"

    for value <- ["all", "-100", "0", "100", "120tail"] do
      refute CheckInventory.normalize(%{"group_limit" => value})["group_limit"]
    end

    refute CheckInventory.normalize(%{"group_search" => String.duplicate("x", 201)})[
             "group_search"
           ]
  end

  defp row_ids(view),
    do: Enum.map(elements(view, ".checks-results-table tbody tr"), &LazyHTML.attribute(&1, "id"))

  defp elements(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

  defp attribute(view, selector, name),
    do: view |> elements(selector) |> hd() |> LazyHTML.attribute(name) |> hd()

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
