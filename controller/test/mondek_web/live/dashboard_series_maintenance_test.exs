# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DashboardSeriesMaintenanceTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Maintenance, MaintenanceSchedules, MaintenanceTime, MaintenanceWindow}
  @endpoint MondekWeb.Endpoint

  test "check detail summarizes a long upcoming series without hiding ordinary windows" do
    now = Monitoring.now()
    series = series(now, 3600, 26)
    ordinary(now)
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert length(elements(view, "#maintenance-summary-10000000-0000-4000-8000-000000000001 li")) ==
             2

    assert length(elements(view, ".maintenance-series-link")) == 1

    assert has_element?(
             view,
             "a[href='/maintenance/series/#{series["id"]}']",
             "All dates in series"
           )

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001",
             "next upcoming window"
           )

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001",
             "Independent one-off work"
           )

    assert Repo.aggregate(MaintenanceWindow, :count) == 27
  end

  test "an active series window remains primary over its future dates" do
    now = Monitoring.now()
    series = series(now, -60, 3)
    [active | _] = series["occurrences"]
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert length(elements(view, "#maintenance-summary-10000000-0000-4000-8000-000000000001 li")) ==
             1

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001 a[href='/maintenance/#{active["id"]}']"
           )

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001",
             "Active"
           )

    assert has_element?(view, "a[href='/maintenance/series/#{series["id"]}']")
  end

  test "individually edited overlapping active windows are both shown" do
    now = Monitoring.now()
    series = series(now, -60, 3)
    [first, second | _] = series["occurrences"]
    created = DateTime.add(now, -8 * 86_400)
    {:ok, child} = Maintenance.get(second["id"], created)

    proposal =
      Map.merge(child["proposal"], %{
        "starts_local" => MaintenanceTime.local(DateTime.add(now, -30), "UTC"),
        "ends_local" => MaintenanceTime.local(DateTime.add(now, 900), "UTC"),
        "reason" => "Move this one window to overlap the active window"
      })

    {:ok, preview} = Maintenance.preview(proposal, 1, created)
    {:ok, _} = Maintenance.apply(preview["review_token"], preview["proposal"], created)
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert length(elements(view, "#maintenance-summary-10000000-0000-4000-8000-000000000001 li")) ==
             2

    for window <- [first, second] do
      assert has_element?(
               view,
               "#maintenance-summary-10000000-0000-4000-8000-000000000001 a[href='/maintenance/#{window["id"]}']"
             )
    end
  end

  test "separate series retain separate next windows" do
    now = Monitoring.now()
    first = series(now, 3600, 3)
    second = series(now, 7200, 3)
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert length(elements(view, "#maintenance-summary-10000000-0000-4000-8000-000000000001 li")) ==
             2

    for series <- [first, second] do
      assert has_element?(view, "a[href='/maintenance/series/#{series["id"]}']")
    end
  end

  test "long series cannot crowd other maintenance out before detail compaction" do
    now = Monitoring.now()
    first = series(now, 3600, 52)
    second = series(now, 7200, 52)
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, now)
    starts = DateTime.add(now, 365 * 86_400)

    proposal =
      Map.merge(seed["proposal"], %{
        "name" => "Later independent maintenance",
        "reason" => "Must remain reachable after two long series",
        "start_mode" => "scheduled",
        "starts_local" => MaintenanceTime.local(starts, "UTC"),
        "ends_local" => MaintenanceTime.local(DateTime.add(starts, 3600), "UTC")
      })

    {:ok, preview} = Maintenance.preview(proposal, 1, now)
    {:ok, ordinary} = Maintenance.apply(preview["review_token"], preview["proposal"], now)
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert length(elements(view, "#maintenance-summary-10000000-0000-4000-8000-000000000001 li")) ==
             3

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001 a[href='/maintenance/#{ordinary["id"]}']"
           )

    for series <- [first, second] do
      assert has_element?(view, "a[href='/maintenance/series/#{series["id"]}']")
    end
  end

  defp series(now, start_offset, count) do
    created = DateTime.add(now, -8 * 86_400)
    starts = DateTime.add(now, start_offset)
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, created)

    proposal =
      Map.merge(seed["proposal"], %{
        "name" => "Weekly filesystem work",
        "reason" => "Inspect independently saved windows",
        "timezone" => "UTC",
        "start_mode" => "scheduled",
        "starts_local" => MaintenanceTime.local(starts, "UTC"),
        "ends_local" => MaintenanceTime.local(DateTime.add(starts, 3600), "UTC"),
        "recurrence" => %{"frequency" => "weekly", "interval" => 1, "count" => count}
      })

    {:ok, preview} = MaintenanceSchedules.preview(proposal, 1, 1, created)

    {:ok, result} =
      MaintenanceSchedules.apply(preview["review_token"], preview["proposal"], created)

    result
  end

  defp ordinary(now) do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, now)

    proposal =
      Map.merge(seed["proposal"], %{
        "name" => "Independent one-off work",
        "reason" => "Keep separate notification holds visible"
      })

    {:ok, preview} = Maintenance.preview(proposal, 1, now)
    {:ok, _} = Maintenance.apply(preview["review_token"], preview["proposal"], now)
  end

  defp elements(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_tree()
end
