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

  test "failed collection preserves result evidence, escaped diagnostics and the host investigation" do
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

    result = stream()
    {:ok, view, html} = live(build_conn(), "/results/#{result.id}/full")
    assert has_element?(view, ".preview-result-measurement", "Critical")
    assert has_element?(view, ".preview-result-measurement", "Original confirmed details")
    assert has_element?(view, "#collection-diagnostics", "Collection unavailable")

    assert has_element?(
             view,
             "#collection-diagnostics",
             "Connection refused <script>unsafe()</script>"
           )

    refute html =~ "<script>unsafe()"
    prompt = view |> element("#collection-agent-prompt-text") |> render()
    assert prompt =~ result.assignment_id
    refute prompt =~ "Connection refused"
    refute prompt =~ "Original confirmed details"
    view |> element("a", "Shared execution and history") |> render_click()
    assert has_element?(view, "#overview-panel #execution-history", "Connection refused")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, ".preview-result-measurement", "Critical")
  end

  test "contact expiry changes assessment while last reported runner signals remain historical" do
    now =
      ready(%{
        "queue_count" => 3,
        "dropped" => 2,
        "diagnostic" => "Earlier upload failure",
        "scheduler" => %{"due_waiting_checks" => 4, "running_checks" => 2}
      })

    measure("OK", 1, now)
    {:ok, view, _} = live(build_conn(), "/results/#{stream().id}/full")
    assert has_element?(view, "#collection-diagnostics", "Measurement current")
    assert has_element?(view, "#reported-runner-signals", "may predate its latest contact")

    assert has_element?(
             view,
             "#reported-runner-signals",
             "Historical drops alone do not establish a current outage"
           )

    Repo.update_all(Mondek.Runner,
      set: [last_seen_at: DateTime.add(now, -Mondek.MonitoringLoss.contact_seconds())]
    )

    send(view.pid, :tick)
    assert has_element?(view, "#collection-diagnostics", "Runner contact overdue")
    assert has_element?(view, "#collection-diagnostics a", "Inspect runner connection")
    assert has_element?(view, "#reported-runner-signals", "3")
    ready()
    send(view.pid, :tick)
    assert has_element?(view, "#collection-diagnostics", "Measurement current")
  end

  test "old source evidence with current contact is distinct from runner transport loss" do
    now = ready()
    old = DateTime.add(now, -100)
    measure("OK", 1, old)
    {:ok, view, _} = live(build_conn(), "/results/#{stream().id}/full")
    assert has_element?(view, "#collection-diagnostics", "Measurement overdue")
    assert has_element?(view, "#collection-diagnostics", "cached or delayed datasource evidence")
    assert has_element?(view, "time[datetime='#{DateTime.to_iso8601(old)}']")
  end

  test "waiting and retired execution identities retain different next steps" do
    now = ready()
    assignment = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    Monitoring.change(assignment, %{desired_generation: 2})
    {:ok, waiting, _} = live(build_conn(), "/executions/#{assignment.id}")
    assert has_element?(waiting, "#collection-diagnostics", "Waiting for configuration")

    assert has_element?(
             waiting,
             "#collection-diagnostics a[href^='/configuration/#{assignment.id}']",
             "Review pending configuration"
           )

    Monitoring.change(Repo.get!(Assignment, assignment.id), %{
      retired_at: now,
      retirement_reason: "Removed from source"
    })

    {:ok, retired, _} = live(build_conn(), "/executions/#{assignment.id}")
    assert has_element?(retired, "#collection-diagnostics", "Result retired")
    assert render(retired) =~ "Removed from source"
  end

  test "an exact runner is inspected outside the bounded fleet list" do
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

    {:ok, view, html} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000001")
    assert has_element?(view, "#collection-diagnostics", "zz selected owner")
    assert has_element?(view, "#collection-diagnostics", "Recent contact")
    refute html =~ "aa unrelated"
  end

  test "unknown identities and forged return destinations remain safe" do
    {:ok, missing, _} = live(build_conn(), "/results/not-an-id/full")
    assert render(missing) =~ "not available"

    {:ok, view, _} =
      live(
        build_conn(),
        "/executions/10000000-0000-4000-8000-000000000001?return_to=https%3A%2F%2Fevil.example"
      )

    refute render(view) =~ "href=\"https://evil.example"
    assert has_element?(view, "a[href='/checks']")
  end

  test "an incident keeps its original context through result and runner diagnostics" do
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
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{incident.id}/full")
    view |> element("#incident-page a", "View latest check result") |> render_click()

    Repo.update_all(Mondek.Runner,
      set: [last_seen_at: DateTime.add(now, -Mondek.MonitoringLoss.contact_seconds())]
    )

    send(view.pid, :tick)

    view
    |> element("#overview-panel #collection-diagnostics a", "Inspect runner connection")
    |> render_click()

    assert has_element?(view, "#overview-panel #runner-detail")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#overview-panel #collection-diagnostics", "Collection failed")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#incident-page #preview-health-evidence")
  end

  test "unfamiliar telemetry is safely inspectable rather than treated as a numeric counter" do
    ready(%{
      "scheduler" => "unsupported",
      "queue_count" => %{"count" => 2},
      "dropped" => -1,
      "diagnostic" => %{"error" => "Earlier failure <script>unsafe()</script>"}
    })

    {:ok, view, html} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000001")
    assert has_element?(view, "#reported-runner-signals", "Not reported")

    assert has_element?(
             view,
             "#reported-runner-signals",
             "Earlier failure <script>unsafe()</script>"
           )

    refute html =~ "<script>unsafe()"

    ready(%{
      "scheduler" => %{"running_checks" => [1], "due_waiting_checks" => %{}},
      "diagnostic" => ["old", "diagnostic"]
    })

    send(view.pid, :tick)
    assert has_element?(view, "#reported-runner-signals", "Not reported")
    assert has_element?(view, "#reported-runner-signals", "diagnostic")
  end
end
