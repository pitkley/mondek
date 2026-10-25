# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ChecksPresentationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "task defaults expose independent health and gaps without changing the evidence" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    assert selected?(view, "all")
    assert view?(view, "targets")
    assert length(elements(view, ".target-group")) == 1
    assert length(elements(view, ".checks-target-index button[id^='inventory-target-']")) == 2
    assert has_element?(view, "#inventory-tab-all", "6")
    assert has_element?(view, "#inventory-tab-attention", "5")
    assert has_element?(view, "#inventory-tab-critical", "2")
    assert has_element?(view, "#inventory-tab-gaps", "3")

    click(view, "#inventory-tab-critical")
    assert view?(view, "list")
    critical = stream("critical")
    retained = stream("retained")
    assert row_ids(view) |> Enum.sort() == Enum.sort([critical.id, retained.id])
    assert has_element?(view, "#result-#{critical.id} .badge.crit", "Critical")
    assert has_element?(view, "#result-#{retained.id} .badge.crit", "Critical")
    assert has_element?(view, "#result-#{retained.id} .badge.stale", "Stale")
    assert has_element?(view, ".target-group-size", "1 of 4 results match")
    assert has_element?(view, ".target-group-size", "1 of 2 results match")
    refute has_element?(view, ".target-health-counts")
    refute has_element?(view, ".target-knowledge-counts")
    refute has_element?(view, "#inventory-pagination-top")
    refute has_element?(view, "#inventory-pagination-bottom")

    click(view, "#inventory-tab-attention")
    assert view?(view, "list")
    assert length(row_ids(view)) == 5
    refute has_element?(view, "#result-#{stream("healthy").id}")
    click(view, "#inventory-tab-gaps")
    assert view?(view, "list")

    assert row_ids(view) |> Enum.sort() ==
             Enum.sort(Enum.map(["pending-a", "pending-b", "retained"], &stream(&1).id))

    assert Repo.get!(ResultStream, retained.id).current == retained.current
  end

  test "manual views belong to each tab and survive URL reopening and equivalent form recovery" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    click(view, "#inventory-view-list")
    click(view, "#inventory-tab-critical")
    assert view?(view, "list")
    click(view, "#inventory-view-targets")
    click(view, "#inventory-tab-all")
    assert view?(view, "list")
    path = click(view, "#inventory-tab-critical")
    assert view?(view, "targets")
    query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["all_view"] == "list"
    assert query["critical_view"] == "targets"

    {:ok, reopened, _} = live(build_conn(), path)
    before = row_ids(reopened)
    assert selected?(reopened, "critical")
    assert view?(reopened, "targets")
    render_change(reopened, "recover_filters", filters("presentation-", "CRIT"))
    refute_patched(reopened)
    send(reopened.pid, :tick)
    assert selected?(reopened, "critical")
    assert view?(reopened, "targets")
    assert row_ids(reopened) == before
    click(reopened, "#inventory-tab-all")
    assert view?(reopened, "list")
    click(reopened, "#inventory-tab-critical")
    assert view?(reopened, "targets")
  end

  test "search and Clear preserve the health task and explicit view even with no matches" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-&tab=critical")
    click(view, "#inventory-view-targets")
    view |> form("#inventory-filters", search: "no-matching-monitor") |> render_change()
    assert_patch(view)
    assert selected?(view, "critical")
    assert view?(view, "targets")
    assert has_element?(view, "#check-inventory", "No matching results")
    view |> element("#inventory-filters button", "Clear") |> render_click()
    assert_patch(view)
    assert selected?(view, "critical")
    assert view?(view, "targets")
    assert has_element?(view, "#inventory-search[value='']")
    assert has_element?(view, "#inventory-tab-critical", "2")
  end

  test "target selection has its own bounded results and survives list detours and reload" do
    publish(
      for(index <- 1..12, do: check("a-#{pad(index)}", "a")) ++
        for(index <- 1..3, do: check("b-#{pad(index)}", "b"))
    )

    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-&page_size=10")
    assert view?(view, "targets")
    select_target(view, "Target a")
    assert has_element?(view, ".target-group-size", "12 matching results")
    assert length(row_ids(view)) == 10
    click(view, "#inventory-pagination-bottom a", "Next")
    assert length(row_ids(view)) == 2
    assert has_element?(view, ".target-group-range", "11–12 of 12")
    path = select_target(view, "Target b")
    assert length(row_ids(view)) == 3
    refute has_element?(view, "#inventory-pagination-top")

    target =
      path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("target")

    click(view, "#inventory-view-list")
    assert length(row_ids(view)) == 10
    path = click(view, "#inventory-view-targets")
    assert has_element?(view, ".target-group h3", "Target b")
    assert length(row_ids(view)) == 3
    assert has_element?(view, "#inventory-target-#{target}[aria-pressed='true']")
    {:ok, reopened, _} = live(build_conn(), path)
    assert has_element?(reopened, ".target-group h3", "Target b")
    assert row_ids(reopened) == row_ids(view)

    reopened |> form("#inventory-filters", search: "presentation-a-") |> render_change()
    assert_patch(reopened)
    assert view?(reopened, "targets")
    assert has_element?(reopened, ".target-group h3", "Target a")
    refute has_element?(reopened, ".target-group h3", "Target b")
  end

  test "a changed search cannot replay stale dropdown values from before a tab patch" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-&tab=critical&view=targets")

    # A browser can serialize the old form while a preceding tab patch is
    # still in flight. Only search changed; the old health value is incidental.
    render_change(
      view,
      "filter",
      Map.put(filters("presentation-critical", ""), "_target", ["search"])
    )

    assert_patch(view)
    assert selected?(view, "critical")
    assert view?(view, "targets")
    assert has_element?(view, "#inventory-search[value='presentation-critical']")
    assert row_ids(view) == [stream("critical").id]

    view |> element("#inventory-clear-scope") |> render_click()
    assert_patch(view)
    assert selected?(view, "critical")
    assert view?(view, "targets")

    # Explicit health edits still change the task, without replaying a stale
    # search value from the same form.
    render_change(view, "filter", Map.put(filters("old-search", ""), "_target", ["health"]))
    assert_patch(view)
    assert selected?(view, "all")
    assert has_element?(view, "#inventory-search[value='']")
  end

  test "alphabetical group navigation and selected results remain stable through health changes" do
    publish([check("a", "a"), check("b", "b")])
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    assert has_element?(view, ".target-group h3", "Target a")
    measure("b", "CRIT", "fresh")
    send(view.pid, :tick)
    assert has_element?(view, ".target-group h3", "Target a")
    assert has_element?(view, "#inventory-tab-critical", "1")

    {:ok, fallback, _} =
      live(build_conn(), "/checks?search=presentation-&target=no-longer-present")

    assert has_element?(fallback, ".target-group h3", "Target a")
    measure("a", "CRIT", "fresh")
    send(fallback.pid, :tick)
    assert has_element?(fallback, ".target-group h3", "Target a")
    assert has_element?(fallback, "#inventory-tab-critical", "2")

    assert fallback
           |> elements(".checks-target-index button[id^='inventory-target-'] .checks-target-name")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&hd(Regex.run(~r/Target [ab]/, &1))) == ["Target a", "Target b"]

    select_target(fallback, "Target b")
    measure("a", "WARN", "fresh")
    send(fallback.pid, :tick)
    assert has_element?(fallback, ".target-group h3", "Target b")
    assert has_element?(fallback, "#inventory-tab-critical", "1")
  end

  test "same-named results from one observer expose their distinct scheduled checks" do
    publish(
      for key <- ["os-disk", "api-disk"] do
        check(key, "a")
        |> Map.put("label", "Disk usage")
        |> put_in(["outputs", Access.at(0), "label"], "Disk usage")
      end
    )

    {:ok, view, _} = live(build_conn(), "/checks?environment=production&view=list")
    assert length(row_ids(view)) == 2

    for key <- ["os-disk", "api-disk"] do
      result = stream(key)
      row = "#result-#{result.id}"
      assert has_element?(view, row <> " .checks-result-link", "Disk usage")
      assert has_element?(view, row <> " .checks-scheduled-check", key)

      assert has_element?(
               view,
               row <> " .checks-scheduled-check[href^='/configuration/#{result.assignment_id}?']"
             )
    end
  end

  defp selected?(view, tab),
    do: has_element?(view, "#inventory-tab-#{tab}[aria-pressed='true']")

  defp view?(view, layout),
    do: has_element?(view, "#inventory-view-#{layout}[aria-pressed='true']")

  defp click(view, selector, text \\ nil) do
    view |> element(selector, text) |> render_click()
    assert_patch(view)
  end

  defp select_target(view, label),
    do: click(view, ".checks-target-index button[id^='inventory-target-']", label)

  defp elements(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

  defp row_ids(view) do
    for row <- elements(view, "#check-inventory tr[id^='result-']") do
      row |> LazyHTML.attribute("id") |> hd() |> String.replace_prefix("result-", "")
    end
  end

  defp filters(search, health) do
    %{
      "search" => search,
      "runner_id" => "",
      "environment" => "",
      "status" => "active",
      "health" => health,
      "freshness" => ""
    }
  end

  defp mixed_inventory do
    publish([
      check("critical", "a"),
      check("warning", "a"),
      check("healthy", "a"),
      check("pending-a", "a"),
      check("retained", "b"),
      check("pending-b", "b")
    ])

    measure("critical", "CRIT", "fresh")
    measure("warning", "WARN", "fresh")
    measure("healthy", "OK", "fresh")
    measure("retained", "CRIT", "stale")
  end

  defp stream(key), do: Repo.one!(from s in ResultStream, where: s.result_key == ^key)

  defp measure(key, health, knowledge) do
    stream = stream(key)
    assignment = Repo.get!(Assignment, stream.assignment_id)
    runner = Repo.get!(Mondek.Runner, assignment.runner_id)
    now = DateTime.utc_now()
    measured_at = if knowledge == "stale", do: DateTime.add(now, -120), else: now
    iso = DateTime.to_iso8601(measured_at)
    observation_id = Ecto.UUID.generate()
    Monitoring.change(assignment, %{authorized_generation: 1})

    payload =
      measurement(health, 1, %{
        "id" => observation_id,
        "assignment_id" => assignment.id,
        "installation_id" => runner.id,
        "session_id" => runner.session_id,
        "started_at" => iso,
        "evaluated_at" => iso
      })
      |> put_in(["results", Access.at(0), "key"], key)
      |> put_in(["results", Access.at(0), "source_at"], iso)

    Repo.insert!(%Observation{
      id: observation_id,
      assignment_id: assignment.id,
      installation_id: runner.id,
      session_id: runner.session_id,
      generation: 1,
      sequence: 1,
      started_at: measured_at,
      evaluated_at: measured_at,
      received_at: now,
      payload: payload,
      disposition: "current"
    })

    current = %{
      "health" => health,
      "knowledge" => knowledge,
      "summary" => "Independent #{key} evidence",
      "generation" => 1,
      "session_id" => runner.session_id,
      "source_at" => iso,
      "confirmed_observation_id" => observation_id,
      "confirmed_generation" => 1
    }

    Repo.update_all(from(s in ResultStream, where: s.id == ^stream.id), set: [current: current])
  end

  defp publish(checks) do
    assert {:ok, _} =
             Inventory.reconcile(
               control(%{
                 "installation_id" => Ecto.UUID.generate(),
                 "session_id" => Ecto.UUID.generate(),
                 "runner_label" => "Presentation observer",
                 "source_id" => "presentation.source",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               DateTime.utc_now()
             )
  end

  defp check(key, target) do
    %{
      "key" => key,
      "label" => "presentation-" <> key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" => [
        %{
          "key" => key,
          "label" => "presentation-" <> key <> " result",
          "target" => %{"key" => target, "kind" => "host", "label" => "Target " <> target}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60
    }
  end

  defp pad(index), do: String.pad_leading(to_string(index), 3, "0")
end
