# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LifecycleLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MondekWeb.Endpoint

  test "a direct incident link resolves its retired check outside global history windows" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)

    {:ok, _} =
      withdraw_source_fixture(
        "10000000-0000-4000-8000-000000000001",
        "Original target retired",
        at()
      )

    rows =
      for index <- 1..101 do
        %{"id" => id} =
          elem(
            create_source_fixture(
              "http",
              "Later target #{index}",
              %{
                "url" => "http://target:8080/ready"
              }
            ),
            1
          )

        later = DateTime.add(at(), index)
        {:ok, _} = withdraw_source_fixture(id, "Later retirement", later)

        %{
          id: Ecto.UUID.generate(),
          assignment_id: id,
          status: "closed",
          health: "CRIT",
          opened_at: later,
          closed_at: later,
          opening_generation: 1,
          attention_revision: 1,
          closure_reason: "check_retired"
        }
      end

    Repo.insert_all(Incident, rows)

    Repo.insert_all(
      Occurrence,
      Enum.map(rows, fn row ->
        %{
          id: Ecto.UUID.generate(),
          incident_id: row.id,
          kind: "firing",
          attention_revision: 1,
          status: "delivered",
          destination: "http://target:8080/webhook",
          payload: %{},
          inserted_at: row.closed_at
        }
      end)
    )

    refute Enum.any?(
             Monitoring.snapshot()["assignments"],
             &(&1["id"] == "10000000-0000-4000-8000-000000000001")
           )

    {:ok, view, _} = live(build_conn(), "/incidents/health/" <> incident.id <> "/full")
    assert has_element?(view, "h1", "Linux filesystem")

    stream =
      Repo.one!(
        from s in Mondek.ResultStream,
          where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
      )

    assert has_element?(
             view,
             "#preview-history",
             MondekWeb.EvidencePresentation.badge_text(
               Repo.get!(Incident, incident.id).closure_reason
             )
           )

    refute Repo.get!(Incident, incident.id).closure_reason == "measured_recovery"
    view |> element("#incident-page a", "View latest check result") |> render_click()
    assert has_element?(view, "#overview-panel", "Linux filesystem")
    assert has_element?(view, "#overview-panel", "This result is retired")
    assert has_element?(view, "#overview-panel #result-measurement-provenance", stream.id)
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#incident-page")
  end

  test "selected configuration edits one check without loading every parameter form" do
    {:ok, check} =
      create_source_fixture("filesystem", "Workspace capacity", %{
        "path" => "/tmp",
        "warn_percent" => 70,
        "crit_percent" => 90
      })

    {:ok, view, _html} = live(build_conn(), "/configuration/" <> check["id"])
    refute has_element?(view, "#10000000-0000-4000-8000-000000000001-warn")
    assert has_element?(view, "##{check["id"]}-warn_percent")

    view
    |> form("#form-" <> check["id"],
      params: %{path: "/tmp", warn_percent: "60", crit_percent: "80"}
    )
    |> render_submit()

    assert Repo.get!(Assignment, check["id"]).params["warn_percent"] == 70
    view |> element("#confirm-instance-save") |> render_click()
    assert Repo.get!(Assignment, check["id"]).params["warn_percent"] == 60

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").params["warn_percent"] ==
             80
  end

  test "retired source history remains inspectable without a generic retirement control" do
    {:ok, _} =
      withdraw_source_fixture("10000000-0000-4000-8000-000000000002", "Target removed", at())

    {:ok, view, _} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000002")
    assert has_element?(view, "#execution-scope", "retirement is not recovery")
    refute has_element?(view, "#retire-check-form")
    refute has_element?(view, "#execution-maintenance a", "Schedule maintenance")
    {:ok, configuration, _} = live(build_conn(), "/configuration?status=retired")

    assert has_element?(
             configuration,
             "#configuration-row-10000000-0000-4000-8000-000000000002",
             "HTTP readiness"
           )
  end
end
