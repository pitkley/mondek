# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.AcknowledgementsTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Control, NotificationWorker, Sweeper}

  test "indefinite acknowledgement is explicit, persists and reports no promised retry time" do
    incident = fire()

    assert {:ok, saved} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "Investigating indefinitely",
               at()
             )

    assert saved["acknowledgement_mode"] == "until_incident_ends"
    assert saved["acknowledged_until"] == nil
    assert saved["acknowledgement_revision"] == 1
    assert Monitoring.acknowledgement_active?(saved, DateTime.add(at(), 400 * 86_400))
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
    occurrence = Repo.one!(Occurrence)
    assert {:ok, {:gated, 86_400}} = NotificationWorker.begin_attempt(occurrence.id, at())
    inspected = hd(Monitoring.inspect_occurrences([occurrence], at()))
    assert inspected["gated_indefinitely"]
    assert inspected["gates"] == ["acknowledgement"]
    assert inspected["gated_until"] == nil
    assert inspected["next_retry_at"] == nil
    assert Repo.one!(Control).until == nil
    assert Repo.one!(Control).acknowledgement_ceiling == "CRIT"
    assert Repo.aggregate(Attempt, :count) == 0

    refute Monitoring.acknowledgement_active?(
             %{"status" => "open", "acknowledged_until" => nil},
             at()
           )
  end

  test "long duration and timezone expiry have exact controlled-clock boundaries" do
    incident = fire()

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               365 * 86_400,
               "Long investigation",
               at()
             )

    row = Repo.get!(Incident, incident.id)

    assert Monitoring.acknowledgement_active?(
             row,
             DateTime.add(row.acknowledged_until, -1, :microsecond)
           )

    refute Monitoring.acknowledgement_active?(row, row.acknowledged_until)
    explicit = options(row, "until") |> Map.put("expires_at", "2009-09-15T10:00:02+02:00")
    assert {:ok, saved} = reviewed_acknowledgement_fixture(row.id, explicit, "One second", at())
    assert saved["acknowledged_until"] == "2009-09-15T08:00:02.000000Z"
    refute Monitoring.acknowledgement_active?(saved, DateTime.add(at(), 1))

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               row.id,
               0,
               "End expired intent",
               DateTime.add(at(), 2)
             )

    assert Repo.get!(Incident, row.id).acknowledgement_mode == nil
  end

  test "malformed, contradictory, expired and unrepresentable requests leave state unchanged" do
    incident = fire()

    bad = [
      options(incident, "duration") |> Map.put("seconds", 0),
      options(incident, "duration") |> Map.put("seconds", -1),
      options(incident, "duration") |> Map.put("seconds", 1.5),
      options(incident, "duration") |> Map.put("seconds", 999_999_999_999_999_999),
      options(incident, "until") |> Map.put("expires_at", "2009-09-15T08:00:01Z"),
      options(incident, "until") |> Map.put("expires_at", "2009-09-15T09:00:00"),
      options(incident, "until") |> Map.put("expires_at", "10000-01-01T00:00:00Z"),
      options(incident) |> Map.put("seconds", 60),
      options(incident, "end") |> Map.put("expires_at", "2030-01-01T00:00:00Z"),
      Map.delete(options(incident), "revision"),
      options(incident) |> Map.put("attention_revision", "1"),
      %{}
    ]

    for request <- bad do
      assert {:error, {:invalid, _}} =
               reviewed_acknowledgement_fixture(incident.id, request, "Reason", at())
    end

    for id <- [nil, %{}, "not-an-id"] do
      assert {:error, {:invalid, _}} =
               reviewed_acknowledgement_fixture(id, options(incident), "Reason", at())
    end

    assert {:error, {:invalid, _}} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "bad\u0001reason",
               at()
             )

    assert {:error, {:invalid, _}} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               String.duplicate(" ", 500) <> "x",
               at()
             )

    assert Repo.get!(Incident, incident.id) == incident
    assert Repo.aggregate(Control, :count) == 0
  end

  test "multiline notes are bounded and database constraints reject ambiguous modes" do
    incident = fire()

    assert {:ok, saved} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "Investigating\nOwner: local operator",
               at()
             )

    assert saved["acknowledgement_note"] == "Investigating\nOwner: local operator"

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE incidents SET acknowledgement_mode=NULL, acknowledged_until=$1 WHERE id=$2",
        [DateTime.add(at(), 60), Ecto.UUID.dump!(incident.id)]
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE incidents SET acknowledgement_mode='unknown' WHERE id=$1", [
        Ecto.UUID.dump!(incident.id)
      ])
    end
  end

  test "reviewed writes conflict with another operator and with changed incident attention" do
    incident = fire("WARN")
    original = options(incident)

    tasks =
      for note <- ["First operator", "Second operator"],
          do:
            Task.async(fn ->
              reviewed_acknowledgement_fixture(incident.id, original, note, at())
            end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :stale}, &1)) == 1
    reviewed = options(Repo.get!(Incident, incident.id))
    ingest(measurement("CRIT", 2))

    assert {:error, :stale} =
             reviewed_acknowledgement_fixture(
               incident.id,
               reviewed,
               "Outdated warning review",
               at()
             )

    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
  end

  test "original ceiling survives downgrade while genuine escalation ends acknowledgement permanently" do
    incident = fire()

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "Cover critical episode",
               at()
             )

    ingest(measurement("WARN", 2))
    ingest(measurement("CRIT", 3))
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
    assert Repo.get!(Incident, incident.id).acknowledgement_ceiling == "CRIT"
    ingest(measurement("WARN", 4))
    row = Repo.get!(Incident, incident.id)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(row.id, options(row), "Cover warning only", at())

    ingest(measurement("CRIT", 5))
    ended = Repo.get!(Incident, incident.id)
    assert ended.acknowledgement_mode == nil
    assert ended.acknowledgement_ceiling == nil
    assert ended.acknowledgement_revision == 3
    ingest(measurement("WARN", 6))
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())

    assert Repo.one!(from c in Control, where: c.kind == "acknowledgement_ended").acknowledgement_ceiling ==
             "WARN"
  end

  test "recovery and retirement clear acknowledgement intent and retain attributable history" do
    incident = fire()

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "Original reason",
               at()
             )

    ingest(measurement("OK", 2))
    closed = Repo.get!(Incident, incident.id)
    assert closed.status == "closed"
    assert closed.acknowledgement_mode == nil
    assert closed.acknowledgement_ceiling == nil
    assert closed.acknowledgement_revision == 2
    ingest(measurement("CRIT", 3))
    next = Repo.one!(from i in Incident, where: i.status == "open")
    assert next.id != incident.id
    refute Monitoring.acknowledgement_active?(next, at())

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(next.id, options(next), "Before retirement", at())

    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Coverage removed",
               at()
             )

    retired = Repo.get!(Incident, next.id)
    assert retired.acknowledgement_mode == nil
    assert retired.acknowledgement_revision == 2

    assert Repo.aggregate(from(c in Control, where: c.kind == "acknowledgement_ended"), :count) ==
             2
  end

  test "cancellation racing snooze is durably woken without consuming a delivery attempt" do
    receiver(204)
    incident = fire()

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(incident),
               "Hold delivery",
               at()
             )

    occurrence = Repo.one!(Occurrence)

    job =
      Monitoring.change(Repo.one!(Oban.Job), %{state: "executing", attempt: 1, attempted_at: at()})

    assert {:ok, {:gated, 86_400}} = NotificationWorker.begin_attempt(occurrence.id, at(), job)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               options(Repo.get!(Incident, incident.id), "end"),
               "Resume delivery",
               DateTime.add(at(), 1)
             )

    assert {:ok, {0, _}} = Sweeper.wake_held_notifications(DateTime.add(at(), 2))
    assert :ok = Oban.Engines.Basic.snooze_job(Oban.config(), job, 86_400)
    assert Repo.get!(Oban.Job, job.id).attempt == 0
    assert {:ok, {1, _}} = Sweeper.wake_held_notifications(DateTime.add(at(), 3))
    woken = Repo.get!(Oban.Job, job.id)
    assert woken.state == "available"
    assert woken.attempt == 0
    assert woken.max_attempts == job.max_attempts
    assert Repo.aggregate(Attempt, :count) == 0
    assert :ok = NotificationWorker.perform(woken)
    assert_receive {:webhook, payload, true}
    assert payload == occurrence.payload
    assert Repo.aggregate(Attempt, :count) == 1
    refute Map.has_key?(Repo.get!(Oban.Job, job.id).args, "mondek_hold_revision")
  end

  test "ending acknowledgement keeps maintenance and a later receiver retry keeps its backoff" do
    receiver(503)
    incident = fire()
    reviewed_acknowledgement_fixture(incident.id, options(incident), "Investigating", at())

    reviewed_maintenance_fixture(
      "10000000-0000-4000-8000-000000000001",
      120,
      "Still maintaining",
      at()
    )

    occurrence = Repo.one!(Occurrence)
    job = Repo.one!(Oban.Job)
    assert {:ok, {:gated, 86_400}} = NotificationWorker.begin_attempt(occurrence.id, at(), job)
    reviewed_acknowledgement_fixture(incident.id, 0, "Investigation done", at())

    assert {:ok, {:gated, 120}} =
             NotificationWorker.begin_attempt(occurrence.id, at(), Repo.get!(Oban.Job, job.id))

    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 0, "End work", at())
    assert {:error, _} = NotificationWorker.perform(Repo.get!(Oban.Job, job.id))
    assert_receive {:webhook, _, true}
    retry_at = DateTime.add(Monitoring.now(), 30)
    Monitoring.change(Repo.get!(Oban.Job, job.id), %{state: "retryable", scheduled_at: retry_at})
    assert {:ok, {0, _}} = Sweeper.wake_held_notifications(Monitoring.now())
    assert Repo.get!(Oban.Job, job.id).scheduled_at == retry_at
  end

  test "long-lived closed incidents retain original control audit then release it with history" do
    incident = fire()

    reviewed_acknowledgement_fixture(
      incident.id,
      options(incident),
      "Original indefinite reason",
      at()
    )

    later = DateTime.add(at(), 45 * 86_400)
    # A current operator edit can replace indefinite intent with a long deadline;
    # neither the old null deadline nor the new distant deadline governs audit retention.
    reviewed_acknowledgement_fixture(
      incident.id,
      Map.put(
        options(Repo.get!(Incident, incident.id), "until"),
        "expires_at",
        "9999-12-31T00:00:00Z"
      ),
      "Long deadline",
      later
    )

    measured =
      measurement("OK", 2, %{
        "started_at" => DateTime.to_iso8601(later),
        "evaluated_at" => DateTime.to_iso8601(later)
      })
      |> put_in(["results", Access.at(0), "source_at"], DateTime.to_iso8601(later))

    ingest(measured, later)
    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: later])
    assert {:ok, _} = Sweeper.sweep(later)
    assert Repo.get!(Incident, incident.id).status == "closed"
    assert Repo.aggregate(Control, :count) == 3
    assert {:ok, _} = Sweeper.sweep(DateTime.add(later, 31 * 86_400))
    assert Repo.get(Incident, incident.id) == nil
    assert Repo.aggregate(Control, :count) == 0
  end

  defp fire(health \\ "CRIT") do
    connect()
    ingest(measurement(health))
    Repo.one!(Incident)
  end

  defp options(incident, mode \\ "until_incident_ends"),
    do: %{
      "mode" => mode,
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

  defp receiver(status) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Mondek.TestWebhook, owner: self(), status: status}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    old = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, old) end)
  end
end
