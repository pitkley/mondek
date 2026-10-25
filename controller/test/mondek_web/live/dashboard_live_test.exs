# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DashboardLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.CoverageFixtures, as: Coverage

  @endpoint MondekWeb.Endpoint

  test "healthy overview explains its empty attention list without suggesting filters" do
    now = Monitoring.now()
    time = DateTime.to_iso8601(now)
    assert {:ok, _} = Monitoring.control(control(), now)

    for assignment <- Repo.all(Assignment) do
      results =
        for key <- assignment.expected_keys,
            do: %{"key" => key, "health" => "OK", "summary" => "Healthy", "source_at" => time}

      report =
        measurement("OK", 1, %{
          "assignment_id" => assignment.id,
          "started_at" => time,
          "evaluated_at" => time,
          "results" => results
        })

      assert disposition(ingest(report, now)) == "current"
    end

    {:ok, overview, html} = live(build_conn(), "/")
    assert has_element?(overview, "h3", "No results currently need attention")
    refute html =~ "Adjust the filters"
    refute html =~ "No matching results"

    {:ok, inventory, _} = live(build_conn(), "/checks?search=not-a-monitored-result")
    assert has_element?(inventory, "#check-inventory", "No matching results")

    assert has_element?(
             inventory,
             "#check-inventory",
             "Try a different search or clear the filters."
           )

    assert has_element?(
             inventory,
             "#check-inventory button[phx-click=clear_checks_all]",
             "Clear all filters"
           )

    Repo.update_all(Mondek.ResultStream, set: [retired_at: now])
    {:ok, retired, _} = live(build_conn(), "/")
    assert has_element?(retired, "h3", "No active results")
  end

  test "runner contact does not claim scheduled coverage" do
    {:ok, _} = connect()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Fresh measurements"

    assert has_element?(
             view,
             "#overview-attention .checks-results-table [id^=result-] .badge",
             "Awaiting measurement"
           )

    assert html =~ "No confirmed measurement yet"
    assert has_element?(view, "#overview-attention [role=region][tabindex='0']")
    assert has_element?(view, "#overview-attention a[href$='return_to=%2F']")
    assert html =~ "Coverage comes from scheduled evidence"
    refute has_element?(view, "[id^=result-] .badge", "Healthy")
  end

  test "published source results identify their observer before their first measurement" do
    streams = Repo.all(Mondek.ResultStream)
    assert streams != []
    {:ok, view, _} = live(build_conn(), "/")

    for stream <- streams do
      row = "#overview-attention #result-#{stream.id}"
      assert has_element?(view, row <> " .target-result-observer", "Fixture observer")
      assert has_element?(view, row <> " .badge", "Awaiting measurement")
    end
  end

  test "compact overview result inspection returns to overview without changing the inventory" do
    assert {:ok, _} = connect()

    stream =
      Repo.one!(
        from(s in Mondek.ResultStream,
          where: s.assignment_id == "10000000-0000-4000-8000-000000000001",
          limit: 1
        )
      )

    {:ok, overview, _} = live(build_conn(), "/")
    assert has_element?(overview, "#overview-attention th", "Last measured health")
    assert has_element?(overview, "#overview-attention th", "Observing runner")
    assert has_element?(overview, "#result-#{stream.id} .checks-result-context")

    {:ok, detail, _} = live(build_conn(), "/checks/#{stream.id}?return_to=%2F")
    assert has_element?(detail, "a.back[href='/']", "Back to overview")

    {:ok, config, _} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001?return_to=%2F")

    assert has_element?(config, "a.back[href='/']", "Back to overview")

    {:ok, external, _} =
      live(build_conn(), "/checks/#{stream.id}?return_to=https%3A%2F%2Fexample.com%2F")

    refute has_element?(external, "a.back[href='https://example.com/']")
  end

  test "overview distinguishes same-named observers without treating repeated results as runners" do
    publications =
      for {name, keys} <- [
            {"Shared observer", ~w(first second)},
            {"Shared observer", ~w(third)},
            {"Distinct observer", ~w(fourth fifth)}
          ] do
        candidates = Enum.map(keys, &Coverage.candidate(Coverage.check(&1)))
        publication = Coverage.publication(candidates, %{"runner_label" => name})
        assert {:ok, _} = Monitoring.inventory(publication)
        publication
      end

    {:ok, view, _} = live(build_conn(), "/")

    for publication <- publications,
        assignment <- Coverage.assignments(publication) do
      stream = Repo.get_by!(Mondek.ResultStream, assignment_id: assignment.id)
      name = publication["runner_label"]

      expected =
        if name == "Shared observer",
          do: "#{name} (#{publication["installation_id"]})",
          else: name

      assert has_element?(
               view,
               "#result-#{stream.id} .target-result-observer[title='#{expected}']",
               expected
             )
    end

    # A duplicate outside the attention results still makes the visible name ambiguous.
    assert {:ok, _} =
             Monitoring.inventory(
               Coverage.publication([], %{"runner_label" => "Distinct observer"})
             )

    send(view.pid, :tick)
    distinct = List.last(publications)

    for assignment <- Coverage.assignments(distinct) do
      stream = Repo.get_by!(Mondek.ResultStream, assignment_id: assignment.id)

      assert has_element?(
               view,
               "#result-#{stream.id} .target-result-observer",
               "Distinct observer (#{distinct["installation_id"]})"
             )
    end
  end

  test "overview keeps an observer outside the bounded runner snapshot identifiable" do
    now = Monitoring.now()

    Repo.insert_all(
      Mondek.Runner,
      for index <- 1..100 do
        %{
          id: Ecto.UUID.generate(),
          session_id: Ecto.UUID.generate(),
          boot: 1,
          label: "Earlier observer #{index}",
          last_seen_at: now
        }
      end
    )

    publication =
      Coverage.publication([Coverage.candidate(Coverage.check())], %{
        "runner_label" => "Tail observer"
      })

    assert {:ok, _} = Monitoring.inventory(publication, now)
    known = Mondek.Inspection.runners()
    assert length(known) == 100
    refute Enum.any?(known, &(&1["id"] == publication["installation_id"]))
    [assignment] = Coverage.assignments(publication)
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: assignment.id)
    {:ok, view, _} = live(build_conn(), "/")

    assert has_element?(
             view,
             "#result-#{stream.id} .target-result-observer",
             "Tail observer (#{publication["installation_id"]})"
           )
  end

  test "filtered incident history does not claim no incidents have ever been recorded" do
    assert {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    assert disposition(ingest(measurement("OK", 2))) == "current"
    incident = Repo.one!(Incident)
    assert incident.status == "closed"

    {:ok, open, html} = live(build_conn(), "/incidents")
    assert has_element?(open, "h3", "No matching incidents")
    assert html =~ "Change the filters to inspect other retained incidents"
    refute html =~ "No incidents recorded"

    {:ok, closed, _} = live(build_conn(), "/incidents?status=closed")
    assert has_element?(closed, "a[href^='/incidents/#{incident.id}']")

    {:ok, no_history, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000002")
    assert has_element?(no_history, "h3", "No incidents recorded")
  end

  test "runner detail calls recent transport contact connected rather than evidence" do
    {:ok, _} = Monitoring.control(control(), DateTime.utc_now())
    {:ok, view, _} = live(build_conn(), "/runners")

    assert has_element?(view, ".badge", "Recent contact")
    refute has_element?(view, ".badge", "Fresh measurement")
  end

  test "notification count includes omitted work and exhausted deliveries" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)

    rows =
      for index <- 1..100 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: incident.id,
          kind: "update",
          attention_revision: index + 1,
          payload: %{},
          destination: "http://target:8080/webhook",
          inserted_at: DateTime.add(at(), index),
          status: if(index == 100, do: "exhausted", else: "pending")
        }
      end

    Repo.insert_all(Occurrence, rows)
    {:ok, overview, _} = live(build_conn(), "/")
    assert has_element?(overview, "#notification-work .stat-value", "101")

    {:ok, delivery, _} = live(build_conn(), "/notifications")
    assert has_element?(delivery, ".badge", "101 outstanding")

    assert has_element?(
             delivery,
             "#occurrence-subset",
             "25 shown · 101 matching notifications"
           )

    assert has_element?(
             delivery,
             "#occurrence-subset",
             "Page 1 of 5"
           )
  end

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

    assert has_element?(reopened, ".page-heading .badge", "Pending")
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

  test "stale critical evidence stays critical and its episode remains open" do
    {:ok, _} = connect()
    evidence = measurement("CRIT")
    assert disposition(ingest(evidence)) == "current"
    {:ok, view, _} = live(build_conn(), "/")

    assert has_element?(view, "[id^=result-] .badge", "Critical")
    assert has_element?(view, "[id^=result-] .badge", "Stale")
    assert Repo.one!(Incident).status == "open"

    {:ok, _, html} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")
    assert html =~ evidence["id"]
    assert html =~ evidence["evaluated_at"]
    assert html =~ "Measurement age"
  end

  test "retained health identifies its measured policy separately from a failed new execution" do
    {:ok, _} = connect()
    confirmed = measurement("CRIT")
    assert disposition(ingest(confirmed)) == "current"

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

    assert disposition(ingest(unavailable)) == "current"
    {:ok, resource, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")
    assert has_element?(resource, ".badge", "Critical")
    assert has_element?(resource, ".badge", "Unavailable")
    assert has_element?(resource, "#confirmed-configuration", "v1")
    assert has_element?(resource, "#execution-configuration", "v2")
    assert render(resource) =~ confirmed["id"]
    assert render(resource) =~ unavailable["id"]

    assert has_element?(
             resource,
             "#measurement-notice-10000000-0000-4000-8000-000000000001",
             "Worker timed out"
           )

    assert has_element?(
             resource,
             "#measurement-notice-10000000-0000-4000-8000-000000000001",
             "Last measured health is retained"
           )

    assert has_element?(resource, "#last-measured-parameters", "v1")

    {:ok, configuration, _} =
      live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    refute has_element?(configuration, ".page-heading .badge", "Measured")

    assert has_element?(
             configuration,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Waiting"
           )

    assert has_element?(
             configuration,
             "#configuration-adoption-versions .stage[aria-current='step']",
             "Waiting"
           )
  end

  test "an open incident keeps its own delivery history beyond the global snapshot windows" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
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

    newer_occurrences =
      for index <- 1..100 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: other.id,
          kind: "update",
          attention_revision: index,
          payload: %{},
          destination: "http://target:8080/webhook",
          status: "delivered",
          inserted_at: DateTime.add(at(), index)
        }
      end

    Repo.insert_all(Occurrence, newer_occurrences)

    Repo.insert_all(
      Attempt,
      for index <- 1..200 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: List.last(newer_occurrences).id,
          status: "failed_or_ambiguous",
          http_status: 503,
          started_at: DateTime.add(at(), index)
        }
      end
    )

    snapshot = Monitoring.snapshot()
    refute Enum.any?(snapshot["occurrences"], &(&1["id"] == original.id))
    refute Enum.any?(snapshot["attempts"], &(&1["occurrence_id"] == original.id))

    {:ok, incident, _} = live(build_conn(), "/incidents/#{original.incident_id}")

    assert has_element?(incident, "#incident-occurrences pre", original.id),
           render(element(incident, "#incident-occurrences"))

    assert has_element?(incident, "#incident-attempts td", "HTTP 202")

    assert has_element?(
             incident,
             "#incident-attempts",
             "Showing 1 of 1 retained delivery attempts"
           )
  end

  test "acknowledgement and maintenance independently persist without clearing failure" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{incident.id}")

    view |> form("#acknowledgement-form", mode: "duration") |> render_change()

    view
    |> form("#acknowledgement-form", note: "Investigating the local service", seconds: "900")
    |> render_submit()

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               900,
               "Planned verification"
             )

    send(view.pid, :tick)

    assert Repo.get!(Incident, incident.id).acknowledgement_note ==
             "Investigating the local service"

    assert Repo.one!(Mondek.MaintenanceWindow).reason ==
             "Planned verification"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"

    window = Repo.one!(Mondek.MaintenanceWindow)
    {:ok, maintenance, _} = live(build_conn(), "/maintenance/" <> window.id)
    maintenance |> element("#maintenance-cancel") |> render_click()

    navigation =
      maintenance
      |> form("#maintenance-cancel-form", reason: "Verification complete")
      |> render_submit()

    {:ok, _, _} = follow_redirect(navigation, build_conn())
    send(view.pid, :tick)

    assert DateTime.compare(
             Repo.get!(Incident, incident.id).acknowledged_until,
             DateTime.utc_now()
           ) == :gt

    assert Repo.get!(Incident, incident.id).status == "open"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"

    assert has_element?(view, "#active-acknowledgement", "Investigating the local service")
  end

  test "empty onboarding explains source publishing without authoring monitoring in the UI" do
    Repo.query!("TRUNCATE assignments RESTART IDENTITY CASCADE")
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Waiting for check inventory"
    assert has_element?(view, "#runner-onboarding", "consumer package")
    refute has_element?(view, "button", "Configure three checks")
    refute has_element?(view, "a[href='/configuration/new']")
    assert Repo.aggregate(Assignment, :count) == 0
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

  test "ending acknowledgement leaves maintenance, ongoing failure, and audit history intact" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{incident.id}")

    view
    |> form("#acknowledgement-form", note: "Investigating")
    |> render_submit()

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               900,
               "Planned repair"
             )

    send(view.pid, :tick)

    view |> element("#end-acknowledgement") |> render_click()

    assert Repo.get!(Incident, incident.id).status == "open"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"

    assert DateTime.compare(
             Repo.one!(Mondek.MaintenanceWindow).ends_at,
             DateTime.utc_now()
           ) == :gt

    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    assert Repo.get!(Incident, incident.id).acknowledged_until == nil

    refute has_element?(view, "#end-acknowledgement")

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001",
             "Active"
           )

    assert render(view) =~ "Acknowledgement ended by local operator"
    assert render(view) =~ "Recovery notifications can still be delivered"
  end

  test "a check leads directly to its configuration and open incident before routine history" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)
    {:ok, view, html} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert has_element?(
             view,
             "a[href='/configuration/10000000-0000-4000-8000-000000000001?return_to=%2Fresources%2F10000000-0000-4000-8000-000000000001']",
             "Review configuration"
           )

    assert has_element?(
             view,
             "#active-incident-#{incident.id} a[href='/incidents/#{incident.id}']",
             "Inspect incident"
           )

    {incident_position, _} = :binary.match(html, "id=\"active-incident-#{incident.id}\"")
    {execution_position, _} = :binary.match(html, "id=\"check-execution-history\"")
    assert incident_position < execution_position
  end

  test "notifications connect receiver failure, next attempt, and the incident" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    occurrence = Repo.one!(Occurrence)
    Monitoring.change(occurrence, %{status: "retrying"})

    Repo.insert!(%Attempt{
      occurrence_id: occurrence.id,
      status: "failed_or_ambiguous",
      http_status: 503,
      error: "Receiver rejected delivery",
      started_at: at(),
      finished_at: at()
    })

    {:ok, view, _} = live(build_conn(), "/notifications/#{occurrence.id}")

    assert has_element?(
             view,
             "#notification-#{occurrence.id} a[href='/incidents/#{occurrence.incident_id}?return_to=%2Fnotifications%2F#{occurrence.id}']",
             "incident"
           )

    assert has_element?(view, "#notification-#{occurrence.id}", "HTTP 503")
    assert has_element?(view, "#notification-#{occurrence.id}", "Next eligible attempt")

    assert has_element?(view, "#notification-attempt-history", "HTTP 503")
    assert has_element?(view, "details summary", "Worker diagnostics")
  end

  test "overview puts an open failure before a check with missing measurements" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    {:ok, view, html} = live(build_conn(), "/")
    assert has_element?(view, "a[href='/notifications']", "Inspect delivery")

    attention =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#overview-attention tbody")
      |> LazyHTML.text()

    {failure_position, _} = :binary.match(attention, "Critical")
    {waiting_position, _} = :binary.match(attention, "No confirmed measurement yet")
    assert failure_position < waiting_position
  end

  test "a transient incident shows its closing measurement without a recovery notification" do
    {:ok, _} = connect()
    firing = measurement("CRIT")
    recovery = measurement("OK", 2)
    assert disposition(ingest(firing)) == "current"
    assert disposition(ingest(recovery)) == "current"
    incident = Repo.one!(Incident)
    assert incident.status == "closed"
    refute Repo.exists?(from o in Occurrence, where: o.kind == "resolved")

    {:ok, view, _} = live(build_conn(), "/incidents/#{incident.id}")
    assert has_element?(view, "#incident-measurements pre", firing["id"])
    assert has_element?(view, "#incident-measurements pre", recovery["id"])
    assert has_element?(view, "#incident-check-now", "Measurement age")
  end

  test "incident controls precede long histories and earlier retries are collapsed" do
    {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)
    occurrence = Repo.one!(Occurrence)
    Monitoring.change(occurrence, %{status: "retrying"})

    Repo.insert_all(
      Attempt,
      for index <- 1..37 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: occurrence.id,
          status: "failed_or_ambiguous",
          http_status: 503,
          error: "Receiver rejected delivery",
          started_at: DateTime.add(at(), index)
        }
      end
    )

    {:ok, view, html} = live(build_conn(), "/incidents/#{incident.id}")
    {summary_position, _} = :binary.match(html, "id=\"incident-summary\"")
    {controls_position, _} = :binary.match(html, "id=\"incident-controls\"")
    {history_position, _} = :binary.match(html, "id=\"incident-history\"")
    assert summary_position < controls_position
    assert controls_position < history_position
    assert has_element?(view, "#incident-controls #acknowledgement-form")

    assert has_element?(
             view,
             "#incident-controls #maintenance-summary-10000000-0000-4000-8000-000000000001"
           )

    assert has_element?(view, "#incident-delivery-summary", "HTTP 503")
    assert has_element?(view, "#incident-delivery-summary", "will be retried when eligible")
    assert has_element?(view, "#visible-attempt-count", "latest 3 of 37 retained")
    assert has_element?(view, "#earlier-delivery-attempts:not([open]) summary", "34 in this view")
    assert has_element?(view, "#incident-attempts > .table-wrap tbody tr:nth-child(3)")
    refute has_element?(view, "#incident-attempts > .table-wrap tbody tr:nth-child(4)")
  end
end
