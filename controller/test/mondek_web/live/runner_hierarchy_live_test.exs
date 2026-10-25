# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnerHierarchyLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inspection, ResultStream, Runner}

  @endpoint MondekWeb.Endpoint

  test "connected runners expose actual result coverage and links to collection gaps" do
    now = Monitoring.now()
    assert {:ok, _} = Monitoring.control(control(), now)
    assert disposition(ingest(current_report(now), now)) == "current"
    id = control()["installation_id"]
    {:ok, view, _} = live(build_conn(), "/runners/#{id}")

    assert has_element?(view, "#runner-detail .badge", "Recent contact")
    assert has_element?(view, "#runner-measurements", "1 of 3")

    assert has_element?(
             view,
             "#runner-measurements a[href*='freshness=awaiting'][href*='runner_id=#{id}']",
             "2"
           )

    assert has_element?(
             view,
             "#runner-measurements a[href*='runner_id=#{id}']",
             "Inspect all results"
           )

    assert has_element?(view, "a[href='/configuration?runner_id=#{id}']", "3 scheduled checks")

    failure =
      current_report(now, 2)
      |> Map.merge(%{"complete" => false, "results" => [], "diagnostic" => "Worker exited"})

    assert disposition(ingest(failure, now)) == "current"
    send(view.pid, :tick)
    assert has_element?(view, "#runner-detail .badge", "Recent contact")
    assert has_element?(view, "#runner-measurements", "0 of 3")

    assert has_element?(
             view,
             "#runner-measurements a[href*='freshness=unavailable'][href*='runner_id=#{id}']",
             "1"
           )

    assert Repo.get_by!(ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001").current[
             "health"
           ] == "CRIT"

    navigation =
      view |> element("#runner-measurements a[href*='freshness=unavailable']") |> render_click()

    {:ok, results, _} = follow_redirect(navigation, build_conn())
    assert has_element?(results, "#check-inventory", "1 matching")
    assert has_element?(results, "#inventory-freshness option[selected][value='unavailable']")
    assert has_element?(results, "#inventory-runner option[selected][value='#{id}']")
  end

  test "coverage uses result membership, age and authority rather than runner-reported counters" do
    now = Monitoring.now()

    assert {:ok, _} =
             Monitoring.control(
               control(%{
                 "status" => %{"queue_count" => 0, "scheduler" => %{"active_checks" => 999}}
               }),
               now
             )

    assert disposition(ingest(current_report(now), now)) == "current"
    id = control()["installation_id"]
    stream = Repo.get_by!(ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

    clone =
      Map.from_struct(stream)
      |> Map.drop([:__meta__, :id])
      |> Map.merge(%{id: Ecto.UUID.generate(), result_key: "second", label: "Second subject"})

    Repo.insert_all(ResultStream, [clone])
    [runner] = Inspection.overview(now)["runners"]
    assert runner["check_count"] == 3

    assert runner["coverage"] == %{
             "active" => 4,
             "fresh" => 2,
             "awaiting" => 2,
             "stale" => 0,
             "unavailable" => 0
           }

    [later] = Inspection.overview(DateTime.add(now, 600))["runners"]
    assert later["coverage"]["stale"] == 2
    assert later["coverage"]["fresh"] == 0

    Repo.update_all(from(s in ResultStream, where: s.result_key == "second"),
      set: [retired_at: now]
    )

    Repo.update_all(from(r in Runner, where: r.id == ^id),
      set: [session_id: Ecto.UUID.generate()]
    )

    [restarted] = Inspection.overview(now)["runners"]
    assert restarted["coverage"]["active"] == 3
    assert restarted["coverage"]["awaiting"] == 3
    refute Map.has_key?(hd(Inspection.runners()), "coverage")
  end

  test "missing diagnostics are not fabricated zeros and prior errors are secondary" do
    now = Monitoring.now()

    assert {:ok, _} =
             Monitoring.control(
               control(%{"status" => %{"diagnostic" => "Earlier connection refused"}}),
               now
             )

    id = control()["installation_id"]
    {:ok, view, _} = live(build_conn(), "/runners/#{id}")
    assert has_element?(view, "#runner-diagnostic:not([open])", "Last recorded diagnostic")

    for field <- [
          "Buffered reports",
          "Spool usage",
          "Reports dropped since journal creation",
          "Running checks"
        ] do
      assert has_element?(view, "#runner-last-report .fleet-facts > div", field)
    end

    assert has_element?(view, "#runner-last-report dd", "Not reported")
    assert has_element?(view, "#runner-diagnostic", "Earlier connection refused")
    assert has_element?(view, "#runner-diagnostic", "may describe an earlier problem")
    refute has_element?(view, "#runner-last-report .notice.warn")
    refute has_element?(view, "#notifications")
    assert has_element?(view, "a[href='/notifications']", "Notifications")
  end

  test "reported queue loss and scheduler backlog remain visible without expanding diagnostics" do
    now = Monitoring.now()
    status = %{"queue_count" => 11, "dropped" => 2, "scheduler" => %{"due_waiting_checks" => 7}}
    assert {:ok, _} = Monitoring.control(control(%{"status" => status}), now)
    id = control()["installation_id"]
    {:ok, view, _} = live(build_conn(), "/runners/#{id}")
    assert has_element?(view, "#runner-last-report .fleet-facts > div", "Buffered reports11")

    assert has_element?(
             view,
             "#runner-last-report .fleet-facts > div",
             "Reports dropped since journal creation"
           )

    assert has_element?(view, "#runner-last-report .fleet-facts > div dd", "2")

    assert has_element?(
             view,
             "#runner-last-report .fleet-facts > div",
             "Due, waiting for a slot"
           )

    assert has_element?(view, "#runner-last-report .fleet-facts > div dd", "7")

    assert has_element?(
             view,
             "#runner-last-report .notice",
             "Executions were waiting for capacity"
           )

    assert has_element?(
             view,
             "#runner-last-report .notice",
             "cumulative count records past evidence loss"
           )

    refute has_element?(view, "details#runner-last-report")
  end

  test "all registered runners are paged and the exact owner stays reachable independently of delivery" do
    now = Monitoring.now()
    assert {:ok, _} = Monitoring.control(control(), now)
    assert disposition(ingest(current_report(now), now)) == "current"
    occurrence = Repo.one!(Occurrence)
    Repo.update!(Ecto.Changeset.change(occurrence, status: "exhausted"))
    owner_id = control()["installation_id"]
    Repo.update_all(from(r in Runner, where: r.id == ^owner_id), set: [label: "ZZZ owner"])

    for index <- 1..100 do
      Repo.insert!(%Runner{
        id: Ecto.UUID.generate(),
        label: "Observer #{index}",
        last_seen_at: now,
        session_id: Ecto.UUID.generate(),
        boot: 1,
        status: %{}
      })
    end

    {:ok, view, _} = live(build_conn(), "/runners?sort=name")
    assert has_element?(view, ".fleet-list-heading", "25 shown · 101 matching · 101 registered")
    assert has_element?(view, "#runner-pagination", "Page 1 of 5")
    assert has_element?(view, ".badge", "No active results")
    refute has_element?(view, "#runner-row-#{owner_id}")
    for _ <- 1..4, do: view |> element("#runner-pagination a", "Next") |> render_click()
    assert has_element?(view, "#runner-pagination", "Page 5 of 5")
    assert has_element?(view, "#runner-row-#{owner_id}")

    {:ok, configuration, _} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000003")

    navigation =
      configuration
      |> element("#configuration-adoption-status a", "check runner status")
      |> render_click()

    {:ok, selected, _} = follow_redirect(navigation, build_conn())

    assert has_element?(selected, "#runner-detail", owner_id)
    assert has_element?(selected, "#runner-measurements", "1 of 3")
    assert has_element?(selected, ".back[href='/runners']")
    refute has_element?(selected, "#notifications")
    {:ok, notifications, _} = live(build_conn(), "/notifications?notification_status=exhausted")
    assert has_element?(notifications, "#notification-row-#{occurrence.id}")
    {:ok, invalid, _} = live(build_conn(), "/runners/not-a-uuid")
    assert has_element?(invalid, "h1", "Runner not found")
    refute has_element?(invalid, "#runner-detail")
    {:ok, overview, _} = live(build_conn(), "/")
    assert has_element?(overview, ".panel", "101 of 101")
    assert has_element?(overview, ".panel", "runners have recent controller contact")
    refute has_element?(overview, ".panel", "first 100")
  end

  defp current_report(now, sequence \\ 1) do
    stamp = DateTime.to_iso8601(now)

    measurement("CRIT", sequence, %{
      "started_at" => stamp,
      "evaluated_at" => stamp,
      "results" => [
        %{
          "key" => "capacity",
          "health" => "CRIT",
          "summary" => "Measured disk pressure",
          "source_at" => stamp
        }
      ]
    })
  end
end
