# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LifecycleReviewTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.NotificationWorker

  @endpoint MondekWeb.Endpoint

  defp record_failed_attempt(occurrence) do
    {:ok, {_, attempt}} = NotificationWorker.begin_attempt(occurrence.id, at())

    Monitoring.change(attempt, %{
      status: "failed_or_ambiguous",
      finished_at: at(),
      http_status: 503
    })

    job =
      Repo.one!(
        from j in Oban.Job, where: fragment("?->>'occurrence_id'", j.args) == ^occurrence.id
      )

    Monitoring.change(job, %{state: "discarded"})
    Mondek.Sweeper.sweep(at())
    Repo.get!(Occurrence, occurrence.id)
  end

  test "operator retry keeps previous attempts visible while explaining another gated attempt" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = record_failed_attempt(Repo.one!(Occurrence))
    incident = Repo.one!(Incident)
    now = Monitoring.now()
    reviewed_acknowledgement_fixture(incident.id, 60, "Investigating the failure", now)

    reviewed_maintenance_fixture(
      "10000000-0000-4000-8000-000000000001",
      120,
      "Local service work",
      now
    )

    {:ok, view, _} = live(build_conn(), "/incidents/health/" <> incident.id <> "/full")
    assert has_element?(view, "#preview-retry-" <> occurrence.id)

    view
    |> form("#preview-retry-" <> occurrence.id, reason: "Receiver repaired")
    |> render_submit()

    notification = "section[aria-labelledby='preview-delivery-heading']"
    assert has_element?(view, notification, "another eligible delivery attempt")
    assert has_element?(view, notification, "earlier attempts remain in the history")
    assert has_element?(view, notification, "Waiting for Acknowledgement and Maintenance")
    refute has_element?(view, notification, "first eligible delivery attempt")
    refute has_element?(view, "#preview-retry-" <> occurrence.id)
    assert has_element?(view, "section[aria-labelledby='preview-delivery-heading']", "HTTP 503")
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    assert Repo.aggregate(Attempt, :count) == 1
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(occurrence.id, now)
  end

  test "retry reasons survive incident refresh and reconnect without requesting delivery" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = record_failed_attempt(Repo.one!(Occurrence))
    incident = Repo.one!(Incident)
    path = "/incidents/health/" <> incident.id <> "/full"
    selector = "#preview-retry-" <> occurrence.id
    input = selector <> " input[name=reason]"
    reason = "Receiver restored after investigation"
    {:ok, view, _} = live(build_conn(), path)
    view |> form(selector, reason: reason) |> render_change()
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='#{reason}']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert has_element?(view, selector <> "[phx-auto-recover='edit_retry_delivery']")

    {:ok, recovered, _} = live(build_conn(), path)

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("edit_retry_delivery", %{
      "entity" => "health:#{incident.id}",
      "_id" => occurrence.id,
      "reason" => reason
    })

    send(recovered.pid, :tick)
    assert has_element?(recovered, input <> "[value='#{reason}']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    recovered |> form(selector) |> render_submit()
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"

    assert Repo.exists?(
             from c in Mondek.Control,
               where:
                 c.occurrence_id == ^occurrence.id and c.kind == "notification_retry" and
                   c.reason == ^reason
           )
  end

  test "delivery retry drafts survive rejected input and clear after a successful request" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = record_failed_attempt(Repo.one!(Occurrence))
    selector = "#retry-notification-" <> occurrence.id
    input = "#retry-reason-" <> occurrence.id
    {:ok, view, _} = live(build_conn(), "/notifications/" <> occurrence.id)
    rejected = String.duplicate("é", 300)
    view |> form(selector, reason: rejected) |> render_change()
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='#{rejected}']")
    view |> form(selector) |> render_submit()
    assert has_element?(view, "[role=alert]", "1 to 500 bytes")
    assert has_element?(view, input <> "[value='#{rejected}']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"

    view |> form(selector, reason: "Receiver repaired") |> render_change()
    view |> form(selector) |> render_submit()
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    refute has_element?(view, selector)
    refute has_element?(view, "[role=alert]")

    Repo.update_all(
      from(j in Oban.Job, where: fragment("?->>'occurrence_id'", j.args) == ^occurrence.id),
      set: [state: "discarded"]
    )

    Monitoring.change(Repo.get!(Occurrence, occurrence.id), %{status: "exhausted"})
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='']")
  end

  test "retrying a closure notification stays eligible during check maintenance" do
    connect()
    ingest(measurement("CRIT"))
    record_failed_attempt(Repo.one!(Occurrence))
    incident = Repo.one!(Incident)

    reviewed_maintenance_fixture(
      "10000000-0000-4000-8000-000000000001",
      120,
      "Maintenance continues after recovery",
      Monitoring.now()
    )

    ingest(measurement("OK", 2))
    resolved = record_failed_attempt(Repo.one!(from o in Occurrence, where: o.kind == "resolved"))
    {:ok, view, _} = live(build_conn(), "/incidents/health/" <> incident.id <> "/full")

    assert Enum.any?(
             Mondek.Maintenance.for_assignment(incident.assignment_id),
             &(&1["status"] == "active")
           )

    view
    |> form("#preview-retry-" <> resolved.id, reason: "Deliver the recorded closure")
    |> render_submit()

    assert has_element?(
             view,
             "[role=status]",
             "incident closure notifications remain eligible"
           )

    assert has_element?(
             view,
             "section[aria-labelledby='preview-delivery-heading']",
             "another eligible delivery attempt"
           )

    refute has_element?(
             view,
             "section[aria-labelledby='preview-delivery-heading']",
             "Waiting for Maintenance"
           )

    inspected =
      Enum.find(
        Monitoring.incident_detail(incident.id)["occurrences"],
        &(&1["id"] == resolved.id)
      )

    assert inspected["gates"] == []
    refute inspected["waiting_on_gates"]
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(resolved.id, Monitoring.now())
  end

  test "retiring before the first measurement preserves the reason and promises no future execution" do
    {:ok, _} =
      withdraw_source_fixture(
        "10000000-0000-4000-8000-000000000002",
        "Target removed before first run",
        at()
      )

    {:ok, view, _} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000002")
    assert has_element?(view, "#execution-scope", "Retired")
    assert render(view) =~ "Target removed before first run"
    refute render(view) =~ "Waiting for the first scheduled observation"
    refute render(view) =~ "Scheduled reports will appear"
    refute has_element?(view, "#retire-check-form")
    refute has_element?(view, "a", "Schedule maintenance")

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000002").current[
             "confirmed_observation_id"
           ] == nil
  end

  test "expired retired raw evidence is distinguished from a check that never measured" do
    connect()
    sample = measurement("OK")
    ingest(sample)

    withdraw_source_fixture(
      "10000000-0000-4000-8000-000000000001",
      "Retained historical check",
      at()
    )

    Mondek.Sweeper.sweep(DateTime.add(at(), 31 * 86_400))
    refute Repo.get(Observation, sample["id"])

    stream =
      Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

    {:ok, view, _} = live(build_conn(), "/results/#{stream.id}/full")
    assert render(view) =~ "This result is retired"
    assert render(view) =~ "Real sample in contract fixture"
    assert has_element?(view, "#result-measurement-provenance", sample["id"])
    assert has_element?(view, ".preview-result-measurement", "Healthy")
    refute render(view) =~ "Scheduled reports will appear"
    assert stream.current["confirmed_observation_id"] == sample["id"]
  end

  test "zero active checks explain the empty coverage and keep a route to new monitoring" do
    for id <- [
          "10000000-0000-4000-8000-000000000001",
          "10000000-0000-4000-8000-000000000002",
          "10000000-0000-4000-8000-000000000003"
        ] do
      {:ok, _} = withdraw_source_fixture(id, "Completed local monitoring", at())
    end

    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#preview-onboarding", "No active results")
    assert has_element?(view, "a[href='/guide']", "Connect a runner")
    refute has_element?(view, "#preview-check-results tbody tr")
    {:ok, history, _} = live(build_conn(), "/checks?status=retired")
    assert render(history) =~ "HTTP readiness"
  end
end
