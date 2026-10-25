# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckDiagnosticsTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint

  defp ready(status \\ %{}) do
    now = Monitoring.now()

    assert {:ok, _} =
             Monitoring.control(
               control(%{
                 "status" => status,
                 "active" => %{"10000000-0000-4000-8000-000000000001" => 1}
               }),
               now
             )

    now
  end

  defp measure(health, sequence, at, extra \\ %{}) do
    time = DateTime.to_iso8601(at)

    data =
      measurement(
        health,
        sequence,
        Map.merge(
          %{
            "started_at" => time,
            "evaluated_at" => time,
            "results" => [
              %{
                "key" => "capacity",
                "health" => health,
                "source_at" => time,
                "summary" => "Current result",
                "details" => "Original confirmed details"
              }
            ]
          },
          extra
        )
      )

    assert disposition(ingest(data, at)) == "current"
    data
  end

  defp stream do
    Repo.one!(
      from s in Mondek.ResultStream,
        where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
    )
  end

  test "failed collection preserves the selected result, error evidence and filtered return path" do
    now = ready()
    measure("CRIT", 1, now)

    measure("UNKNOWN", 2, DateTime.add(now, 1), %{
      "results" => [
        %{
          "key" => "capacity",
          "health" => "UNKNOWN",
          "summary" => "Datasource unavailable",
          "details" =>
            "Connection refused <script>unsafe()</script>\nCheck datasource network access"
        }
      ],
      "diagnostic" => "Collection failed",
      "complete" => false
    })

    id = stream().id
    return_to = "/checks?freshness=unavailable&view=list"
    suffix = "?" <> URI.encode_query(%{"return_to" => return_to})
    {:ok, result, _} = live(build_conn(), "/checks/#{id}" <> suffix)

    canonical_return =
      result
      |> element("a.back")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    assert URI.decode_query(URI.parse(canonical_return).query) |> Map.take(~w(freshness view)) ==
             %{"freshness" => "unavailable", "view" => "list"}

    suffix = "?" <> URI.encode_query(%{"return_to" => canonical_return})

    assert has_element?(
             result,
             "a[href='/checks/#{id}/diagnostics#{suffix}']",
             "Investigate measurement"
           )

    refute has_element?(result, "a", "Inspect runner")

    {:ok, view, html} = live(build_conn(), "/checks/#{id}/diagnostics" <> suffix)
    assert has_element?(view, "#investigation-finding h2", "Collection unavailable")

    assert has_element?(
             view,
             "#investigation-next-action a[href='#latest-execution']",
             "Read collection error"
           )

    assert has_element?(
             view,
             ".investigation-section:first-child #latest-execution[tabindex='-1']"
           )

    assert has_element?(view, "#latest-execution", "Connection refused <script>unsafe()</script>")
    refute html =~ "<script>unsafe()"
    refute has_element?(view, "#latest-execution", "Original confirmed details")
    assert has_element?(view, "#investigation-back[href='/checks/#{id}#{suffix}']")
    incident = Repo.one!(Incident)
    assert has_element?(view, "#notification-boundary a[href^='/incidents/#{incident.id}?']")
    assert has_element?(view, "#notification-boundary", "separate monitoring-loss incident")

    assert has_element?(
             view,
             "#notification-boundary a[href^='/monitoring-incidents?runner_id=']"
           )

    prompt = view |> element("#collection-agent-prompts-collection-text") |> render()
    assert prompt =~ id
    assert prompt =~ control()["installation_id"]
    refute prompt =~ "Connection refused"
    refute prompt =~ "Original confirmed details"
  end

  test "contact expiry replaces a collection finding without pretending runner telemetry is live" do
    now =
      ready(%{
        "queue_count" => 3,
        "dropped" => 2,
        "diagnostic" => "Earlier upload failure",
        "scheduler" => %{"due_waiting_checks" => 4, "running_checks" => 2}
      })

    measure("OK", 1, now)
    {:ok, view, _} = live(build_conn(), "/checks/#{stream().id}/diagnostics")
    assert has_element?(view, "#investigation-finding h2", "Measurement current")
    assert has_element?(view, "#runner-signals", "may predate its last contact")

    assert has_element?(
             view,
             "#runner-signals",
             "cumulative counter alone does not show a current outage"
           )

    assert has_element?(view, "#runner-signals", "may describe an earlier problem")

    Repo.update_all(Mondek.Runner,
      set: [last_seen_at: DateTime.add(now, -Mondek.MonitoringLoss.contact_seconds())]
    )

    send(view.pid, :tick)
    assert has_element?(view, "#investigation-finding h2", "Runner contact overdue")
    assert has_element?(view, ".investigation-section:first-child #runner-signals")

    assert has_element?(
             view,
             "#investigation-next-action a[href^='/runners/#{control()["installation_id"]}?']",
             "Inspect runner connection"
           )

    assert has_element?(view, "#runner-signals", "3")
    ready()
    send(view.pid, :tick)
    assert has_element?(view, "#investigation-finding h2", "Measurement current")
  end

  test "old datasource evidence with current runner contact is distinct from transport loss" do
    now = ready()
    old = DateTime.add(now, -100)
    measure("OK", 1, old)
    {:ok, view, _} = live(build_conn(), "/checks/#{stream().id}/diagnostics")
    assert has_element?(view, "#investigation-finding h2", "Measurement overdue")
    assert has_element?(view, "#investigation-finding", "cached or delayed datasource evidence")
    assert has_element?(view, "#latest-execution time[datetime='#{DateTime.to_iso8601(old)}']")
  end

  test "waiting and retired source checks have different next steps" do
    now = ready()

    Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"), %{
      desired_generation: 2
    })

    {:ok, waiting, _} =
      live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001/diagnostics")

    assert has_element?(waiting, "#investigation-finding h2", "Waiting for configuration")

    assert has_element?(
             waiting,
             "#investigation-next-action a[href^='/configuration/10000000-0000-4000-8000-000000000001?']",
             "Review pending configuration"
           )

    {:ok, settings, _} =
      waiting
      |> element("#investigation-next-action a")
      |> render_click()
      |> follow_redirect(build_conn())

    assert has_element?(
             settings,
             ".back[href='/resources/10000000-0000-4000-8000-000000000001/diagnostics']",
             "Back to investigation"
           )

    Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"), %{
      retired_at: now,
      retirement_reason: "Removed from source"
    })

    {:ok, retired, _} =
      live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001/diagnostics")

    assert has_element?(retired, "#investigation-finding h2", "Result retired")
  end

  test "a selected runner is inspected even beyond the fleet list limit" do
    now = ready()
    runner = Repo.get!(Mondek.Runner, control()["installation_id"])
    Monitoring.change(runner, %{label: "zz selected owner"})

    for index <- 1..101 do
      Repo.insert!(%Mondek.Runner{
        id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        boot: 1,
        last_seen_at: now,
        label: "aa unrelated #{index}"
      })
    end

    {:ok, view, html} =
      live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001/diagnostics")

    assert has_element?(view, "#measurement-investigation", "zz selected owner")
    assert has_element?(view, "#runner-signals", "Recent controller contact")
    refute html =~ "aa unrelated"
  end

  test "unknown identities and forged return destinations stay local" do
    {:ok, missing, _} = live(build_conn(), "/checks/not-an-id/diagnostics")
    assert has_element?(missing, ".notice", "This check is not configured")

    {:ok, view, _} =
      live(
        build_conn(),
        "/resources/10000000-0000-4000-8000-000000000001/diagnostics?return_to=https%3A%2F%2Fevil.example"
      )

    assert has_element?(
             view,
             "#investigation-back[href='/resources/10000000-0000-4000-8000-000000000001']"
           )
  end

  test "an incident opens missing evidence directly and survives the runner detour" do
    now = ready()
    measure("CRIT", 1, now)

    measure("UNKNOWN", 2, DateTime.add(now, 1), %{
      "results" => [
        %{"key" => "capacity", "health" => "UNKNOWN", "summary" => "Permission denied"}
      ],
      "complete" => false,
      "diagnostic" => "Collection failed"
    })

    incident = Repo.one!(Incident)

    incident_path =
      "/incidents/#{incident.condition_incident_id || incident.id}?notification_status=all"

    {:ok, incident_view, _} = live(build_conn(), incident_path)

    {:ok, investigation, _} =
      incident_view
      |> element("#incident-check-now a", "Investigate measurement")
      |> render_click()
      |> follow_redirect(build_conn())

    assert has_element?(
             investigation,
             "#investigation-back[href='#{incident_path}']",
             "Back to incident"
           )

    Repo.update_all(Mondek.Runner,
      set: [last_seen_at: DateTime.add(now, -Mondek.MonitoringLoss.contact_seconds())]
    )

    send(investigation.pid, :tick)

    {:ok, runner, _} =
      investigation
      |> element("#investigation-next-action a")
      |> render_click()
      |> follow_redirect(build_conn())

    {:ok, returned, _} =
      runner |> element("a.back") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(
             returned,
             "#investigation-back[href='#{incident_path}']",
             "Back to incident"
           )

    assert has_element?(returned, "#latest-execution", "Collection failed")
  end

  test "bounded but unfamiliar runner telemetry remains inspectable" do
    ready(%{
      "scheduler" => "unsupported",
      "queue_count" => %{"count" => 2},
      "dropped" => -1,
      "diagnostic" => %{"error" => "Earlier failure <script>unsafe()</script>"}
    })

    {:ok, view, html} =
      live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001/diagnostics")

    assert has_element?(view, "#runner-signals", "Not reported")
    assert has_element?(view, "#runner-signals pre", "Earlier failure <script>unsafe()</script>")
    refute html =~ "<script>unsafe()"
    refute has_element?(view, "#runner-signals", "The runner reported buffered evidence")

    ready(%{
      "scheduler" => %{"running_checks" => [1], "due_waiting_checks" => %{}},
      "diagnostic" => ["old", "diagnostic"]
    })

    send(view.pid, :tick)
    assert has_element?(view, "#runner-signals", "Not reported")
    assert has_element?(view, "#runner-signals pre", "diagnostic")
  end
end
