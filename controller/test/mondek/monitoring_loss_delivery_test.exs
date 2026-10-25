# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringLossDeliveryTest do
  use Mondek.DataCase, async: false

  alias Mondek.{Control, MonitoringIncident, MonitoringLoss, NotificationWorker, Sweeper}

  test "monitoring delivery commits attempts before real HTTP and keeps its separate immutable owner" do
    receiver(204)
    {incident, occurrence, _clock} = fire()
    assert Repo.aggregate(Incident, :count) == 0
    assert :ok = NotificationWorker.perform(job(occurrence))
    assert_receive {:webhook, payload, true}
    assert payload == occurrence.payload
    assert payload["monitoring_incident_id"] == incident.id
    assert Repo.one!(Attempt).status == "accepted"
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"

    assert_raise Postgrex.Error, fn ->
      Monitoring.change(Repo.get!(Occurrence, occurrence.id), %{monitoring_incident_id: nil})
    end

    [inspected] = Monitoring.inspect_occurrences([Repo.get!(Occurrence, occurrence.id)], at())
    assert inspected["monitoring_incident_id"] == incident.id
    assert inspected["check_label"] == incident.label
    assert inspected["latest_attempt"]["status"] == "accepted"
    assert inspected["attempt_count"] == 1
  end

  test "dispatch observes retirement immediately without a tick or an invented recovery" do
    {incident, occurrence, clock} = fire()
    retired_at = DateTime.add(clock, 1)

    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Remove this collector",
               retired_at
             )

    assert {:ok, :superseded} = NotificationWorker.begin_attempt(occurrence.id, retired_at)
    closed = Repo.get!(MonitoringIncident, incident.id)
    assert closed.status == "closed"
    assert closed.closure_reason == "scope_withdrawn"
    assert closed.closed_at == retired_at
    assert Repo.aggregate(Attempt, :count) == 0
    refute Repo.exists?(from o in Occurrence, where: o.kind == "resolved")
  end

  test "an attempted unavailable episode gets administrative closure when retired before the next dispatch" do
    {incident, occurrence, clock} = fire()
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(occurrence.id, clock)
    retired_at = DateTime.add(clock, 1)

    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Source intentionally removed",
               retired_at
             )

    assert {:ok, :superseded} = NotificationWorker.begin_attempt(occurrence.id, retired_at)
    assert Repo.get!(MonitoringIncident, incident.id).closure_reason == "scope_withdrawn"
    terminal = Repo.one!(from o in Occurrence, where: o.kind == "resolved")
    assert terminal.monitoring_incident_id == incident.id
    assert terminal.payload["closure_reason"] == "scope_withdrawn"
    assert Repo.aggregate(Attempt, :count) == 1
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(terminal.id, retired_at)
  end

  test "an exhausted monitoring notification can be retried without changing its payload or owner" do
    receiver(503)
    {incident, occurrence, clock} = fire()
    original_job = job(occurrence)

    assert {:error, _} =
             NotificationWorker.perform(%{original_job | attempt: original_job.max_attempts})

    assert_receive {:webhook, payload, true}
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    Monitoring.change(original_job, %{state: "discarded"})
    [inspected] = Monitoring.inspect_occurrences([Repo.get!(Occurrence, occurrence.id)], clock)
    assert inspected["can_retry"]

    assert {:ok, retry} = Monitoring.retry_notification(occurrence.id, "Receiver repaired", clock)
    assert retry["id"] == occurrence.id
    assert retry["payload"] == payload
    assert retry["destination"] == occurrence.destination
    replacement = job(occurrence)
    refute replacement.id == original_job.id
    assert replacement.max_attempts == original_job.max_attempts
    assert replacement.attempt == 0

    audit = Repo.one!(from c in Control, where: c.kind == "notification_retry")
    assert audit.monitoring_incident_id == incident.id
    assert is_nil(audit.assignment_id)
    assert is_nil(audit.incident_id)
    assert is_nil(audit.condition_incident_id)
    assert {:ok, _} = Sweeper.sweep(clock)
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"

    assert {:error, _} = NotificationWorker.perform(replacement)
    assert_receive {:webhook, ^payload, true}
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "maintenance edits wake a durable monitoring hold without resetting retry budget" do
    {incident, occurrence, clock} = fire()

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               3600,
               "Collector maintenance",
               clock
             )

    original_job = job(occurrence)

    assert {:ok, {:gated, _}} =
             NotificationWorker.begin_attempt(occurrence.id, clock, original_job)

    [inspected] = Monitoring.inspect_occurrences([Repo.get!(Occurrence, occurrence.id)], clock)
    assert "maintenance" in inspected["gates"]
    assert length(inspected["maintenance_windows"]) == 1
    assert Repo.aggregate(Attempt, :count) == 0
    held = Repo.get!(Oban.Job, original_job.id)

    Monitoring.change(held, %{state: "scheduled", scheduled_at: DateTime.add(clock, 3600)})

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               0,
               "Work complete",
               clock
             )

    assert {:ok, {count, _}} = Sweeper.wake_held_notifications(clock)
    assert count >= 1
    resumed = Repo.get!(Oban.Job, original_job.id)
    assert resumed.state == "available"
    assert resumed.attempt == original_job.attempt
    assert resumed.max_attempts == original_job.max_attempts
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(occurrence.id, clock, resumed)
    assert Repo.get!(MonitoringIncident, incident.id).status == "open"
  end

  test "an indefinite monitoring acknowledgement wakes on explicit ending with the same occurrence" do
    {incident, occurrence, clock} = fire()

    reviewed = %{
      "mode" => "until_incident_ends",
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               incident.id,
               reviewed,
               "Collector work",
               clock
             )

    original_job = job(occurrence)

    assert {:ok, {:gated, 86_400}} =
             NotificationWorker.begin_attempt(occurrence.id, clock, original_job)

    held = Repo.get!(Oban.Job, original_job.id)
    Monitoring.change(held, %{state: "scheduled", scheduled_at: DateTime.add(clock, 86_400)})

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               incident.id,
               %{reviewed | "mode" => "end", "revision" => reviewed["revision"] + 1},
               "Resume monitoring notifications",
               clock
             )

    assert {:ok, {count, _}} = Sweeper.wake_held_notifications(clock)
    assert count >= 1
    assert Repo.get!(Oban.Job, original_job.id).state == "available"
    assert {:ok, {same, _}} = NotificationWorker.begin_attempt(occurrence.id, clock)
    assert same.payload == occurrence.payload
    assert same.id == occurrence.id
  end

  test "partial maintenance does not suppress a runner episode with other affected results" do
    {_incident, occurrence, clock} = fire(false)

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               3600,
               "Disk collector only",
               clock
             )

    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(occurrence.id, clock)
    [inspected] = Monitoring.inspect_occurrences([Repo.get!(Occurrence, occurrence.id)], clock)
    refute "maintenance" in inspected["gates"]
  end

  test "exhaustion and retention preserve unresolved monitoring incidents and retry controls" do
    {incident, occurrence, clock} = fire()
    original_job = job(occurrence)
    Monitoring.change(original_job, %{state: "discarded"})
    assert {:ok, _} = Sweeper.sweep(clock)
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"

    assert {:ok, _} =
             Monitoring.retry_notification(occurrence.id, "Test receiver restored", clock)

    retry = job(occurrence)
    Monitoring.change(retry, %{state: "discarded"})
    assert {:ok, _} = Sweeper.sweep(DateTime.add(clock, 40 * 86_400))
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert Repo.get!(MonitoringIncident, incident.id).status == "open"

    assert Repo.one!(from c in Control, where: c.kind == "notification_retry").monitoring_incident_id ==
             incident.id
  end

  test "history cleanup retains every raw observation referenced by a monitoring snapshot" do
    {incident, occurrence, clock} = fire()
    opening_id = hd(occurrence.payload["member_snapshot"])["observation_id"]
    later = measurement("UNKNOWN", 2)
    assert disposition(ingest(later, clock)) == "current"
    assert {:ok, _} = MonitoringLoss.reconcile(clock)

    assert hd(Repo.get!(MonitoringIncident, incident.id).member_snapshot)["observation_id"] ==
             later["id"]

    # The first receipt is now referenced only by the immutable notification;
    # the current snapshot references the later failure independently.
    assert {:ok, _} = Sweeper.sweep(DateTime.add(clock, 40 * 86_400))
    assert Repo.get(Observation, opening_id)
    assert Repo.get(Observation, later["id"])

    refs =
      (Repo.get!(MonitoringIncident, incident.id).member_snapshot ++
         occurrence.payload["member_snapshot"])
      |> Enum.map(& &1["observation_id"])

    assert Enum.all?(refs, &Repo.get(Observation, &1))
  end

  test "monitoring-only episodes retain matching maintenance windows and complete series history" do
    {_incident, _occurrence, clock} = fire()

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               1,
               "Brief collector work",
               clock
             )

    window = Repo.one!(Mondek.MaintenanceWindow)
    {:ok, seed} = Mondek.Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, clock)

    proposal =
      Map.merge(seed["proposal"], %{
        "name" => "Collector patching",
        "reason" => "Planned observer work",
        "start_mode" => "scheduled",
        "timezone" => "UTC",
        "starts_local" => "2009-09-20T09:00:00",
        "ends_local" => "2009-09-20T10:00:00",
        "recurrence" => %{
          "frequency" => "weekly",
          "interval" => 1,
          "end_mode" => "count",
          "count" => 2,
          "until_date" => nil
        }
      })

    assert {:ok, reviewed} = Mondek.MaintenanceSchedules.preview(proposal, 1, 1, clock)

    assert {:ok, series} =
             Mondek.MaintenanceSchedules.apply(reviewed["review_token"], proposal, clock)

    assert Repo.aggregate(Incident, :count) == 0
    assert {:ok, _} = Sweeper.sweep(DateTime.add(clock, 60 * 86_400))
    assert Repo.get(Mondek.MaintenanceWindow, window.id)
    assert Repo.get(Mondek.MaintenanceSeries, series["id"])
    assert Repo.aggregate(Mondek.MaintenanceWindow, :count) == 3
    assert Repo.aggregate(Mondek.MaintenanceEvent, :count) == 3
  end

  defp fire(retire_unrelated \\ true) do
    for id <-
          if(retire_unrelated,
            do: ["10000000-0000-4000-8000-000000000002", "10000000-0000-4000-8000-000000000003"],
            else: []
          ) do
      assert {:ok, _} = withdraw_source_fixture(id, "Outside this delivery fixture", at())
    end

    connect()
    assert disposition(ingest(measurement("UNKNOWN"))) == "current"
    assert {:ok, _} = MonitoringLoss.reconcile(at())
    clock = DateTime.add(at(), 125)
    assert {:ok, _} = MonitoringLoss.reconcile(clock)
    incident = Repo.one!(from i in MonitoringIncident, where: i.status == "open")
    occurrence = Repo.one!(from o in Occurrence, where: o.monitoring_incident_id == ^incident.id)
    {incident, occurrence, clock}
  end

  defp job(occurrence),
    do:
      Repo.one!(
        from j in Oban.Job,
          where: fragment("?->>'occurrence_id'", j.args) == ^occurrence.id,
          order_by: [desc: j.id],
          limit: 1
      )

  defp receiver(status) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Mondek.TestWebhook, owner: self(), status: status}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
  end
end
