# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DashboardLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.CoverageFixtures, as: Coverage

  @endpoint MondekWeb.Endpoint

  test "invalid typed values keep the saved revision intact" do
    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    html =
      view
      |> form("#form-10000000-0000-4000-8000-000000000001",
        params: %{path: "/", warn_percent: "90", crit_percent: "80"}
      )
      |> render_submit()

    assert html =~ "source schema"
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 1

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").params["warn_percent"] ==
             80

    assert has_element?(
             view,
             "#10000000-0000-4000-8000-000000000001-warn_percent[value='90'][aria-invalid='true']"
           )

    assert has_element?(
             view,
             "#10000000-0000-4000-8000-000000000001-warn_percent[aria-describedby='10000000-0000-4000-8000-000000000001-warn_percent-help error-10000000-0000-4000-8000-000000000001']"
           )

    refute has_element?(
             view,
             "#configuration-10000000-0000-4000-8000-000000000001 button",
             "Reload current values"
           )
  end

  test "a background refresh preserves the revision reviewed by a concurrent editor" do
    {:ok, first, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")
    {:ok, second, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    first
    |> form("#form-10000000-0000-4000-8000-000000000001",
      params: %{path: "/", warn_percent: "70", crit_percent: "85"}
    )
    |> render_submit()

    first |> element("#confirm-instance-save") |> render_click()

    send(second.pid, :tick)
    assert render(second) =~ "Reviewing saved version 1"

    html =
      second
      |> form("#form-10000000-0000-4000-8000-000000000001",
        params: %{path: "/", warn_percent: "60", crit_percent: "75"}
      )
      |> render_submit()

    assert html =~ "changed after you opened it"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").params["warn_percent"] ==
             70

    second
    |> element(
      "#configuration-10000000-0000-4000-8000-000000000001 button",
      "Reload current values"
    )
    |> render_click()

    assert render(second) =~ "Reviewing saved version 2"
    assert has_element?(second, "#10000000-0000-4000-8000-000000000001-warn_percent[value='70']")
  end

  test "offline save remains pending and survives a new browser session" do
    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    view
    |> form("#form-10000000-0000-4000-8000-000000000001",
      params: %{path: "/", warn_percent: "72.5", crit_percent: "91"}
    )
    |> render_submit()

    view |> element("#confirm-instance-save") |> render_click()

    {:ok, reopened, html} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    assert html =~ "Reviewing saved version 2"

    assert has_element?(
             reopened,
             "#10000000-0000-4000-8000-000000000001-warn_percent[value='72.5']"
           )

    assert has_element?(
             reopened,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Waiting"
           )

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").active_generation == nil

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").observed_generation ==
             nil
  end

  test "form recovery after reconnect preserves the revision originally reviewed" do
    {:ok, disconnected, _} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    assert has_element?(
             disconnected,
             "#form-10000000-0000-4000-8000-000000000001 input[name='_revision'][value='1']"
           )

    recovered_form = %{
      "_id" => "10000000-0000-4000-8000-000000000001",
      "_revision" => "1",
      "params" => %{"path" => "/", "warn_percent" => "60", "crit_percent" => "75"}
    }

    render_change(disconnected, "edit", recovered_form)

    assert {:ok, _} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
               "path" => "/",
               "warn_percent" => 70,
               "crit_percent" => 85
             })

    # A reconnect mounts a new server process, then LiveView sends the old DOM
    # form through phx-change before applying the rejoin patch.
    {:ok, reconnected, _} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    assert render(reconnected) =~ "Reviewing saved version 2"
    render_change(reconnected, "edit", recovered_form)
    assert render(reconnected) =~ "Reviewing saved version 1"

    html = render_submit(reconnected, "save", recovered_form)
    assert html =~ "changed after you opened it"
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 2

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").params["warn_percent"] ==
             70

    reconnected
    |> element(
      "#configuration-10000000-0000-4000-8000-000000000001 button",
      "Reload current values"
    )
    |> render_click()

    assert has_element?(
             reconnected,
             "#form-10000000-0000-4000-8000-000000000001 input[name='_revision'][value='2']"
           )

    assert has_element?(
             reconnected,
             "#10000000-0000-4000-8000-000000000001-warn_percent[value='70']"
           )
  end

  test "reviewing unchanged source defaults explicitly pins a complete instance exception" do
    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    view
    |> form("#form-10000000-0000-4000-8000-000000000001",
      params: %{path: "/", warn_percent: "80.0", crit_percent: "90"}
    )
    |> render_submit()

    view |> element("#confirm-instance-save") |> render_click()

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 2

    assert has_element?(
             view,
             "#feedback-10000000-0000-4000-8000-000000000001[role='status']",
             "Settings saved"
           )

    refute has_element?(view, "#feedback-10000000-0000-4000-8000-000000000003")

    refute has_element?(
             view,
             "#configuration-10000000-0000-4000-8000-000000000002 button",
             "Save configuration"
           )

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").instance_exception == %{
             "path" => "/",
             "warn_percent" => 80.0,
             "crit_percent" => 90
           }
  end

  test "healthy overview explains its empty attention list without suggesting filters" do
    now = Monitoring.now()
    iso = DateTime.to_iso8601(now)
    assert {:ok, _} = Monitoring.control(control(), now)

    for assignment <- Repo.all(Assignment) do
      results =
        for key <- assignment.expected_keys,
            do: %{"key" => key, "health" => "OK", "summary" => "Healthy", "source_at" => iso}

      report =
        measurement("OK", 1, %{
          "assignment_id" => assignment.id,
          "started_at" => iso,
          "evaluated_at" => iso,
          "results" => results
        })

      assert disposition(ingest(report, now)) == "current"
    end

    {:ok, overview, html} = live(build_conn(), "/")

    assert has_element?(
             overview,
             "#preview-no-attention",
             "No results currently need attention"
           )

    refute html =~ "Adjust the filters"
    {:ok, inventory, _} = live(build_conn(), "/checks?search=not-a-monitored-result")
    assert has_element?(inventory, ".preview-empty", "No check results match")
    assert has_element?(inventory, "a", "Clear filters")
  end

  test "runner contact alone does not establish measured health" do
    {:ok, _} = connect()
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#preview-attention", "Awaiting")
    assert has_element?(view, "#preview-attention", "Not measured")
    refute has_element?(view, "#preview-attention", "Healthy")
  end

  test "published results identify their observer before their first measurement" do
    {:ok, view, _} = live(build_conn(), "/")

    for stream <- Repo.all(Mondek.ResultStream) do
      assert has_element?(
               view,
               "#result-row-#{stream.id} .preview-result-context",
               "Fixture observer"
             )

      assert has_element?(view, "#result-row-#{stream.id}", "Awaiting")
    end
  end

  test "overview opens and closes result evidence without leaving its inventory" do
    {:ok, _} = connect()
    stream = fixture_stream()
    {:ok, view, _} = live(build_conn(), "/")
    view |> element("#open-result-#{stream.id}") |> render_click()
    assert_patch(view)
    assert has_element?(view, "#overview-panel")
    assert has_element?(view, "#preview-summary")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view)
    refute has_element?(view, "#overview-panel")
    assert Repo.get!(Mondek.ResultStream, stream.id).current == stream.current
  end

  test "same-named observers retain distinct labels independent of their result count" do
    publications =
      for {name, keys} <- [
            {"Shared observer", ~w(first second)},
            {"Shared observer", ~w(third)},
            {"Distinct observer", ~w(fourth fifth)}
          ] do
        publication =
          Coverage.publication(Enum.map(keys, &Coverage.candidate(Coverage.check(&1))), %{
            "runner_label" => name
          })

        assert {:ok, _} = Monitoring.inventory(publication)
        publication
      end

    {:ok, view, _} = live(build_conn(), "/")

    for publication <- publications, assignment <- Coverage.assignments(publication) do
      stream = Repo.get_by!(Mondek.ResultStream, assignment_id: assignment.id)

      assert has_element?(
               view,
               "#result-row-#{stream.id} .preview-result-context",
               publication["runner_label"]
             )

      if publication["runner_label"] == "Shared observer",
        do: assert(has_element?(view, "#result-row-#{stream.id}", publication["installation_id"]))
    end
  end

  test "an observer beyond the bounded runner snapshot stays identifiable" do
    for index <- 1..100,
        do:
          Repo.insert!(%Mondek.Runner{
            id: Ecto.UUID.generate(),
            session_id: Ecto.UUID.generate(),
            boot: 1,
            label: "Earlier observer #{index}",
            last_seen_at: Monitoring.now()
          })

    publication =
      Coverage.publication([Coverage.candidate(Coverage.check())], %{
        "runner_label" => "Tail observer"
      })

    assert {:ok, _} = Monitoring.inventory(publication)
    [assignment] = Coverage.assignments(publication)
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: assignment.id)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#result-row-#{stream.id}", "Tail observer")
    view |> element("#open-result-#{stream.id}") |> render_click()
    assert has_element?(view, "#overview-panel a[href*='#{publication["installation_id"]}']")
  end

  test "closed incidents remain reachable through the removable status chip" do
    {:ok, _} = connect()
    ingest(measurement("CRIT"))
    ingest(measurement("OK", 2))
    incident = Repo.one!(Incident)
    {:ok, open, _} = live(build_conn(), "/incidents")
    refute has_element?(open, "#incident-row-health-#{incident.id}")
    {:ok, closed, _} = live(build_conn(), "/incidents?status=closed")
    assert render(closed) =~ incident.id
    {:ok, execution, _} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000002")
    assert has_element?(execution, "#execution-incidents", "No health incidents")
  end

  test "runner detail keeps contact separate from measurement coverage" do
    {:ok, _} = Monitoring.control(control(), Monitoring.now())
    {:ok, view, _} = live(build_conn(), "/runners/#{control()["installation_id"]}/full")
    assert has_element?(view, "#runner-contact", "Recent contact")
    assert has_element?(view, "#runner-measurements", "Awaiting")
    refute has_element?(view, "#runner-measurements", "Fresh measurement")
  end

  test "notification inventory counts include work outside its first page and exhausted deliveries" do
    {:ok, _} = connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)

    Repo.insert_all(
      Occurrence,
      for index <- 1..100 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: incident.id,
          kind: "update",
          attention_revision: index + 1,
          payload: %{},
          destination: "webhook:example",
          inserted_at: DateTime.add(at(), index),
          status: if(index == 100, do: "exhausted", else: "pending")
        }
      end
    )

    {:ok, view, _} = live(build_conn(), "/notifications")
    assert has_element?(view, "#notifications-heading + span", "101 outstanding")
    assert has_element?(view, ".notification-matching-count", "101 matching notifications")

    assert view
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("[id^='notification-row-']")
           |> Enum.count() == 25

    assert has_element?(view, "nav[aria-label='Notification pages']", "101")
  end

  test "old critical evidence stays critical while its incident stays open" do
    {:ok, _} = connect()
    evidence = measurement("CRIT")
    ingest(evidence)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#preview-attention", "Critical")
    assert has_element?(view, "#preview-attention", "Overdue")
    assert Repo.one!(Incident).status == "open"
    {:ok, execution, _} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000001")
    assert render(execution) =~ evidence["id"]
  end

  test "retained health stays attached to its measured configuration after a failed new execution" do
    {:ok, _} = connect()
    confirmed = measurement("CRIT")
    ingest(confirmed)

    assert {:ok, _} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
               "path" => "/",
               "warn_percent" => 70,
               "crit_percent" => 85
             })

    {:ok, _} = connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})

    unavailable =
      report(%{
        "id" => Ecto.UUID.generate(),
        "sequence" => 2,
        "generation" => 2,
        "complete" => false,
        "results" => [],
        "diagnostic" => "Worker timed out"
      })

    ingest(unavailable)
    stream = fixture_stream()
    {:ok, view, _} = live(build_conn(), "/results/#{stream.id}/full?diagnostics=1")
    assert render(view) =~ "Critical"
    assert render(view) =~ "unavailable"
    assert render(view) =~ "Worker timed out"
    assert Repo.get!(Mondek.ResultStream, stream.id).current["confirmed_generation"] == 1
    assert Repo.get!(Assignment, stream.assignment_id).desired_generation == 2
    assert has_element?(view, "#result-measurement-provenance", confirmed["id"])
    {:ok, execution, _} = live(build_conn(), "/executions/#{stream.assignment_id}")
    assert render(execution) =~ unavailable["id"]
  end

  test "an incident keeps delivery evidence beyond the bounded global snapshot" do
    {:ok, _} = connect()
    ingest(measurement("CRIT"))
    original = Repo.one!(Occurrence)
    Monitoring.change(original, %{status: "delivered"})

    Repo.insert!(%Attempt{
      occurrence_id: original.id,
      status: "accepted",
      http_status: 202,
      started_at: at(),
      finished_at: at()
    })

    other =
      Repo.insert!(%Incident{
        assignment_id: "10000000-0000-4000-8000-000000000002",
        health: "CRIT",
        opened_at: at(),
        opening_generation: 1
      })

    Repo.insert_all(
      Occurrence,
      for index <- 1..100 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: other.id,
          kind: "update",
          attention_revision: index,
          payload: %{},
          destination: "webhook:example",
          status: "delivered",
          inserted_at: DateTime.add(at(), index)
        }
      end
    )

    refute Enum.any?(Monitoring.snapshot()["occurrences"], &(&1["id"] == original.id))
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{original.incident_id}/full")
    assert has_element?(view, "section[aria-labelledby=preview-delivery-heading]", "HTTP 202")
    assert has_element?(view, "#preview-payload-#{original.id}", original.id)
  end

  test "acknowledgement and maintenance persist independently without clearing failure" do
    incident = incident()
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{incident.id}/full")

    view
    |> form("#preview-incident-ack-form", note: "Investigating local service")
    |> render_submit()

    assert {:ok, _} =
             reviewed_maintenance_fixture(incident.assignment_id, 900, "Planned verification")

    send(view.pid, :tick)

    assert has_element?(
             view,
             "table[aria-label='Active acknowledgement']",
             "Investigating local service"
           )

    assert Repo.get!(Incident, incident.id).status == "open"
    assert Repo.get!(Assignment, incident.assignment_id).current["health"] == "CRIT"
    assert Repo.one!(Mondek.MaintenanceWindow).reason == "Planned verification"
  end

  test "empty overview describes source publishing without adding authored checks" do
    Repo.query!("TRUNCATE assignments RESTART IDENTITY CASCADE")
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#runner-onboarding", "consumer package")
    refute has_element?(view, "a[href='/configuration/new']")
    assert Repo.aggregate(Assignment, :count) == 0
  end

  test "ending acknowledgement leaves maintenance and failure intact with an audit trail" do
    incident = incident()
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{incident.id}/full")
    view |> form("#preview-incident-ack-form", note: "Investigating") |> render_submit()
    assert {:ok, _} = reviewed_maintenance_fixture(incident.assignment_id, 900, "Planned repair")
    send(view.pid, :tick)
    view |> element("button[phx-click='end_acknowledgement']") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    assert Repo.get!(Incident, incident.id).status == "open"
    assert Repo.get!(Assignment, incident.assignment_id).current["health"] == "CRIT"
    assert DateTime.compare(Repo.one!(Mondek.MaintenanceWindow).ends_at, Monitoring.now()) == :gt
    assert render(view) =~ "Acknowledgement ended"
  end

  test "result leads directly to its configuration and incident before measurement history" do
    incident = incident()
    assert disposition(ingest(measurement("CRIT", 2))) == "current"
    {:ok, view, _} = live(build_conn(), "/results/#{incident.stream_id}/full")
    assert has_element?(view, "a[href^='/configuration/#{incident.assignment_id}']")
    assert has_element?(view, "#preview-result-incidents a[data-phx-link='patch']")
    assert has_element?(view, "#preview-result-history")
  end

  test "notification details link delivery failure next eligibility and the exact incident" do
    incident()
    notice = Repo.one!(Occurrence)
    Monitoring.change(notice, %{status: "retrying"})

    Repo.insert!(%Attempt{
      occurrence_id: notice.id,
      status: "failed_or_ambiguous",
      http_status: 503,
      error: "Receiver rejected delivery",
      started_at: at(),
      finished_at: at()
    })

    {:ok, view, _} = live(build_conn(), "/notifications/#{notice.id}/full")
    assert has_element?(view, "#notification-delivery", "HTTP 503")
    assert has_element?(view, "#notification-delivery a[data-phx-link='patch']", "incident")
    assert has_element?(view, "#notification-attempts", "HTTP 503")
  end

  test "overview prioritizes an open measured failure before unmeasured results" do
    incident()
    {:ok, view, _} = live(build_conn(), "/")

    text =
      view
      |> element("#preview-attention tbody")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

    {failure, _} = :binary.match(text, "Critical")
    {waiting, _} = :binary.match(text, "Not measured")
    assert failure < waiting
  end

  test "a transient incident retains its closing evidence without inventing a recovery notification" do
    {:ok, _} = connect()

    firing =
      measurement("CRIT")
      |> put_in(["results", Access.at(0), "summary"], "Opening failure evidence")

    recovery =
      measurement("OK", 2)
      |> put_in(["results", Access.at(0), "summary"], "Closing recovery evidence")

    ingest(firing)
    ingest(recovery)
    incident = Repo.one!(Incident)
    assert incident.status == "closed"
    refute Repo.exists?(from o in Occurrence, where: o.kind == "resolved")
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{incident.id}/full")
    assert has_element?(view, "#preview-measurements-#{incident.id}", "Opening failure evidence")
    assert has_element?(view, "#preview-measurements-#{incident.id}", "Closing recovery evidence")

    assert Repo.get!(Observation, firing["id"]).payload["results"]
           |> hd()
           |> Map.fetch!("summary") == "Opening failure evidence"

    assert incident.closing_observation_id == recovery["id"]
  end

  test "incident controls precede history and older attempts remain collapsed" do
    incident = incident()
    notice = Repo.one!(Occurrence)
    Monitoring.change(notice, %{status: "retrying"})

    Repo.insert_all(
      Attempt,
      for index <- 1..37 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: notice.id,
          status: "failed_or_ambiguous",
          http_status: 503,
          error: "Receiver rejected delivery",
          started_at: DateTime.add(at(), index)
        }
      end
    )

    {:ok, view, html} = live(build_conn(), "/incidents/health/#{incident.id}/full")
    {controls, _} = :binary.match(html, "id=\"preview-ack-heading\"")
    {history, _} = :binary.match(html, "id=\"preview-history\"")
    assert controls < history
    assert has_element?(view, "#preview-incident-ack-form")

    assert has_element?(
             view,
             "#preview-attempts-#{notice.id}:not([open]) summary",
             "Earlier attempts (36)"
           )

    assert render(view) =~ "HTTP 503"
  end

  defp fixture_stream,
    do: Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

  defp incident do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    Repo.one!(Incident)
  end
end
