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

    {:ok, view, _} = live(build_conn(), "/incidents/" <> incident.id)
    assert has_element?(view, "#retry-notification-" <> occurrence.id)

    view
    |> form("#retry-notification-" <> occurrence.id, reason: "Receiver repaired")
    |> render_submit()

    notification = "#notification-" <> occurrence.id
    assert has_element?(view, notification, "another eligible delivery attempt")
    assert has_element?(view, notification, "earlier attempts remain in the history")
    assert has_element?(view, notification, "Waiting for Acknowledgement and Maintenance")
    refute has_element?(view, notification, "first eligible delivery attempt")
    refute has_element?(view, "#retry-notification-" <> occurrence.id)
    assert has_element?(view, "#incident-attempts", "HTTP 503")
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    assert Repo.aggregate(Attempt, :count) == 1
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(occurrence.id, now)
  end

  test "retry reasons survive incident refresh and reconnect without requesting delivery" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = record_failed_attempt(Repo.one!(Occurrence))
    incident = Repo.one!(Incident)
    path = "/incidents/" <> incident.id
    selector = "#retry-notification-" <> occurrence.id
    input = "#retry-reason-" <> occurrence.id
    reason = "Receiver restored after investigation"
    {:ok, view, _} = live(build_conn(), path)
    view |> form(selector, reason: reason) |> render_change()
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='#{reason}']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert has_element?(view, selector <> "[phx-auto-recover='edit_notification_retry']")

    {:ok, recovered, _} = live(build_conn(), path)

    recovered
    |> render_change("edit_notification_retry", %{"_id" => occurrence.id, "reason" => reason})

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
    assert has_element?(view, ".flash[role='alert']", "1 to 500 bytes")
    assert has_element?(view, input <> "[value='#{rejected}']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"

    view |> form(selector, reason: "Receiver repaired") |> render_change()
    view |> form(selector) |> render_submit()
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    refute has_element?(view, selector)
    refute has_element?(view, ".flash[role='alert']")

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
    {:ok, view, _} = live(build_conn(), "/incidents/" <> incident.id)

    assert has_element?(
             view,
             "#maintenance-summary-10000000-0000-4000-8000-000000000001",
             "Active"
           )

    view
    |> form("#retry-notification-" <> resolved.id, reason: "Deliver the recorded closure")
    |> render_submit()

    assert has_element?(
             view,
             ".flash[role='status']",
             "incident closure notifications remain eligible"
           )

    assert has_element?(
             view,
             "#notification-" <> resolved.id,
             "another eligible delivery attempt"
           )

    refute has_element?(view, "#notification-" <> resolved.id, "Waiting for Maintenance")

    inspected =
      Enum.find(
        Monitoring.incident_detail(incident.id)["occurrences"],
        &(&1["id"] == resolved.id)
      )

    assert inspected["gates"] == []
    refute inspected["waiting_on_gates"]
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(resolved.id, Monitoring.now())
  end

  test "retiring before the first measurement does not promise future collection" do
    {:ok, _} =
      withdraw_source_fixture(
        "10000000-0000-4000-8000-000000000002",
        "Target removed before first run",
        at()
      )

    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000002")
    html = render(view)
    assert has_element?(view, "#retired-check-notice", "excluded from active coverage")
    assert has_element?(view, "h3", "No retained execution evidence")
    assert html =~ "retired without a confirmed measurement"
    refute html =~ "Waiting for the first scheduled observation"
    refute html =~ "Scheduled reports will appear"
    refute has_element?(view, "#retire-check-form")
    refute has_element?(view, "#maintenance-summary-10000000-0000-4000-8000-000000000002")
    assert has_element?(view, "#check-control-history", "Target removed before first run")
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

    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")
    html = render(view)
    assert has_element?(view, "#retired-check-notice", "retirement does not mean recovery")
    assert html =~ "Real sample in contract fixture"
    assert html =~ "1 referenced observations are no longer retained"
    assert html =~ "recorded history and measurement identities remain available"
    assert has_element?(view, "h3", "No retained execution evidence")
    refute html =~ "retired without a confirmed measurement"
    refute html =~ "Scheduled reports will appear"
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
    assert has_element?(view, "#coverage-summary .stat-value", "0")
    refute has_element?(view, ".stat-foot", "Checks awaiting fresh evidence")
    refute has_element?(view, ".stat-foot", "All checks have fresh evidence")
    refute has_element?(view, "#resource-10000000-0000-4000-8000-000000000002")
    assert has_element?(view, "#runner-onboarding", "Waiting for check inventory")
    assert has_element?(view, "a[href='/checks?status=retired']", "retired result history")
  end
end
