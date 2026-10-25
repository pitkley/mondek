# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationTest do
  use Mondek.DataCase, async: false
  alias Mondek.NotificationWorker, as: Worker

  defp receiver(status, options \\ []) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Mondek.TestWebhook, [owner: self(), status: status] ++ options},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
  end

  defp fire do
    connect()
    ingest(measurement("CRIT"))
    Repo.one!(Occurrence)
  end

  for exhausted? <- [false, true] do
    @exhausted? exhausted?
    test "an older #{if exhausted?, do: "exhausted", else: "retryable"} failure preserves accepted delivery" do
      receiver(503, controlled: true)
      occurrence = fire()
      job = Repo.one!(Oban.Job)
      older_job = if @exhausted?, do: %{job | attempt: job.max_attempts}, else: job

      older = Task.async(fn -> Worker.perform(older_job) end)
      assert_receive {:webhook_waiting, first}, 1000
      newer = Task.async(fn -> Worker.perform(job) end)
      assert_receive {:webhook_waiting, second}, 1000

      send(second, {:respond, 204})
      assert :ok = Task.await(newer)
      delivered = Repo.get!(Occurrence, occurrence.id)
      assert delivered.status == "delivered"
      assert delivered.delivered_at

      send(first, {:respond, 503})
      assert {:error, _} = Task.await(older)
      retained = Repo.get!(Occurrence, occurrence.id)
      assert retained.status == "delivered"
      assert retained.delivered_at == delivered.delivered_at
      assert {:ok, :delivered} = Worker.begin_attempt(occurrence.id, at())

      attempts = Repo.all(from a in Attempt, order_by: a.started_at)
      assert Enum.sort(Enum.map(attempts, & &1.status)) == ["accepted", "failed_or_ambiguous"]
      assert Enum.all?(attempts, & &1.finished_at)
      assert Repo.aggregate(Attempt, :count) == 2
    end
  end

  test "the longest SMTP deadline fits within job execution and orphan recovery limits" do
    smtp = [
      host: "localhost",
      port: 25,
      from: "mondek@example.invalid",
      to: "operator@example.invalid",
      transport: :plain,
      timeout_ms: 30_000
    ]

    assert Mondek.NotificationDelivery.validate_config!(smtp) == smtp
    config = Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: :prod)
    plugins = config[:mondek][Oban][:plugins]
    rescue_after = Keyword.fetch!(plugins[Oban.Plugins.Lifeline], :rescue_after)
    timeout = Worker.timeout(%Oban.Job{})
    assert is_integer(timeout)
    assert timeout > smtp[:timeout_ms]
    assert rescue_after > timeout
  end

  test "orphan rescue preserves the job identity and leaves bounded running work alone" do
    receiver(204)
    occurrence = fire()
    now = Monitoring.now()

    expired =
      Monitoring.change(Repo.one!(Oban.Job), %{
        state: "executing",
        attempt: 1,
        attempted_at: DateTime.add(now, -180)
      })

    recent =
      Worker.new(%{"occurrence_id" => occurrence.id})
      |> Oban.insert!()
      |> Monitoring.change(%{
        state: "executing",
        attempt: 1,
        attempted_at: DateTime.add(now, -40)
      })

    config = Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: :prod)
    rescue_after = config[:mondek][Oban][:plugins][Oban.Plugins.Lifeline][:rescue_after]

    assert {:ok, [%{id: id, state: "available"}]} =
             Oban.Engines.Basic.rescue_jobs(Oban.config(), Oban.Job, rescue_after: rescue_after)

    assert id == expired.id
    rescued = Repo.get!(Oban.Job, id)
    assert rescued.args == expired.args
    assert rescued.attempt == expired.attempt
    assert Repo.get!(Oban.Job, recent.id).state == "executing"
    assert :ok = Worker.perform(rescued)
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    assert Repo.one!(Attempt).status == "accepted"
  end

  test "a real webhook observes an already committed attempt and immutable occurrence" do
    receiver(204)
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert :ok = Worker.perform(job)
    assert_receive {:webhook, payload, true}
    assert payload == occurrence.payload
    assert Repo.one!(Attempt).status == "accepted"
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    assert {:ok, :delivered} = Worker.begin_attempt(occurrence.id, at())
    assert Repo.aggregate(Attempt, :count) == 1

    assert_raise Postgrex.Error, fn ->
      Monitoring.change(Repo.get!(Occurrence, occurrence.id), %{
        destination: "http://localhost:9999/changed"
      })
    end
  end

  test "receiver rejection retries same payload and recovery supersedes obsolete firing" do
    receiver(503)
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, _} = Worker.perform(job)
    assert_receive {:webhook, payload, true}
    assert Repo.get!(Occurrence, occurrence.id).status == "retrying"
    assert {:error, _} = Worker.perform(job)
    assert_receive {:webhook, ^payload, true}
    assert Repo.aggregate(Attempt, :count) == 2
    ingest(measurement("OK", 2))
    assert {:ok, :superseded} = Worker.begin_attempt(occurrence.id, at())
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(Occurrence, :count) == 2

    assert Repo.one!(from o in Occurrence, where: o.kind == "resolved").payload["closure_reason"] ==
             "measured_recovery"
  end

  test "never-attempted transient has no terminal delivery and no new episode on old retry" do
    occurrence = fire()
    ingest(measurement("OK", 2))
    assert Repo.aggregate(Occurrence, :count) == 1
    assert {:ok, :superseded} = Worker.begin_attempt(occurrence.id, at())
    assert Repo.aggregate(Incident, :count) == 1
  end

  test "acknowledgement and maintenance expire independently while checks continue" do
    occurrence = fire()
    incident = Repo.one!(Incident)
    assert {:ok, _} = reviewed_acknowledgement_fixture(incident.id, 20, "Investigating", at())

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               30,
               "Planned work",
               at()
             )

    assert {:ok, {:gated, _}} = Worker.begin_attempt(occurrence.id, DateTime.add(at(), 21))

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               0,
               "End maintenance",
               DateTime.add(at(), 5)
             )

    assert {:ok, {:gated, _}} = Worker.begin_attempt(occurrence.id, DateTime.add(at(), 6))
    assert {:ok, {_, _}} = Worker.begin_attempt(occurrence.id, DateTime.add(at(), 21))
    ingest(measurement("CRIT", 2))
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 2
    assert Repo.one!(Incident).status == "open"

    assert {:ok, _} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               7201,
               "Long planned work",
               at()
             )

    assert {:error, {:invalid, _}} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               -1,
               "Invalid",
               at()
             )
  end

  test "ack severity ceiling survives downgrade and invalidates on real escalation" do
    connect()
    ingest(measurement("WARN"))
    incident = Repo.one!(Incident)
    reviewed_acknowledgement_fixture(incident.id, 60, "Watching warning", at())
    ingest(measurement("CRIT", 2))
    incident = Repo.one!(Incident)
    assert is_nil(incident.acknowledged_until)
    assert Repo.aggregate(Occurrence, :count) == 2
    ended = Repo.one!(from c in Mondek.Control, where: c.kind == "acknowledgement_ended")
    assert ended.actor == "Mondek"
    assert ended.incident_id == incident.id
    assert ended.until == at()
    assert ended.reason =~ "severity rose from WARN to CRIT"
    reviewed_acknowledgement_fixture(incident.id, 60, "Watching critical", at())
    ingest(measurement("WARN", 3))
    ingest(measurement("CRIT", 4))
    assert Repo.one!(Incident).acknowledgement_ceiling == "CRIT"
    assert Repo.one!(Incident).acknowledged_until == DateTime.add(at(), 60)
  end

  test "ending acknowledgement is attributable and leaves maintenance in effect" do
    occurrence = fire()
    incident = Repo.one!(Incident)
    reviewed_acknowledgement_fixture(incident.id, 60, "Investigating", at())

    reviewed_maintenance_fixture(
      "10000000-0000-4000-8000-000000000001",
      120,
      "Planned work",
      at()
    )

    ended_at = DateTime.add(at(), 10)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(incident.id, 0, "Ended by local operator", ended_at)

    assert {:ok, {:gated, _}} = Worker.begin_attempt(occurrence.id, ended_at)

    ended = Repo.one!(from c in Mondek.Control, where: c.kind == "acknowledgement_ended")
    assert ended.actor == "Local operator"
    assert ended.until == ended_at
    assert ended.reason == "Ended by local operator"
    assert Repo.one!(Incident).status == "open"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"
  end

  test "a new explicit impact ends an individual acknowledgement at unchanged severity" do
    fire()
    incident = Repo.one!(Incident)
    assert {:ok, _} = reviewed_acknowledgement_fixture(incident.id, 0, "Start review", at())
    incident = Repo.get!(Incident, incident.id)

    reviewed = %{
      "mode" => "until_incident_ends",
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(incident.id, reviewed, "Known disk pressure", at())

    original = Repo.get!(Incident, incident.id)
    impact = %{"key" => "writes-blocked", "label" => "Writes blocked"}

    sample =
      update_in(
        measurement("CRIT", 2),
        ["results", Access.at(0)],
        &Map.put(&1, "impacts", [impact])
      )

    assert disposition(ingest(sample)) == "current"
    current = Repo.get!(Incident, incident.id)
    assert current.health == "CRIT"
    assert current.attention_revision == original.attention_revision + 1
    refute Monitoring.acknowledgement_active?(current, at())
    assert current.impacts == [impact]

    assert {:error, :stale} =
             reviewed_acknowledgement_fixture(incident.id, reviewed, "Outdated review", at())

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(incident.id, 600, "Reviewed blocked writes", at())

    assert Repo.get!(Incident, incident.id).acknowledgement_impacts == ["writes-blocked"]

    renamed =
      put_in(
        sample,
        ["results", Access.at(0), "impacts", Access.at(0), "label"],
        "Write operations blocked"
      )
      |> Map.merge(%{"id" => Ecto.UUID.generate(), "sequence" => 3})

    assert disposition(ingest(renamed)) == "current"
    assert Repo.get!(Incident, incident.id).attention_revision == current.attention_revision
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
    assert disposition(ingest(measurement("CRIT", 4))) == "current"
    restored = Map.merge(sample, %{"id" => Ecto.UUID.generate(), "sequence" => 5})
    assert disposition(ingest(restored)) == "current"
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
  end

  test "exhausted delivery becomes visible, and retention preserves unresolved work and current evidence" do
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    Monitoring.change(job, %{state: "discarded"})
    future = DateTime.add(at(), 40 * 86_400)
    assert {:ok, _} = Mondek.Sweeper.sweep(future)
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.aggregate(Incident, :count) == 1
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 1
    ingest(measurement("OK", 2))
    assert Repo.get!(Occurrence, occurrence.id).status == "superseded"
    assert Monitoring.snapshot()["notification_backlog"]["total"] == 0
    # Obsolete exhausted work retains terminal history until ordinary expiry.
    Mondek.Sweeper.sweep(future)
    assert is_nil(Repo.get(Occurrence, occurrence.id))
  end

  test "a severity change retires an exhausted old revision without hiding current exhaustion" do
    occurrence = fire()
    Monitoring.change(Repo.one!(Oban.Job), %{state: "discarded"})
    Mondek.Sweeper.sweep(at())
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    ingest(measurement("CRIT", 2))
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert Monitoring.snapshot()["notification_backlog"]["total"] == 1

    ingest(measurement("WARN", 3))
    assert Repo.get!(Occurrence, occurrence.id).status == "superseded"
    update = Repo.one!(from o in Occurrence, where: o.kind == "update")
    assert update.status == "pending"
    assert Monitoring.snapshot()["notification_backlog"]["total"] == 1
    assert Repo.aggregate(Occurrence, :count) == 2
  end

  test "the last rejected attempt immediately reports exhausted delivery" do
    receiver(503)
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, _} = Worker.perform(%{job | attempt: job.max_attempts})
    assert_receive {:webhook, _, true}
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
  end

  test "completed history expires while current projection and configuration authority survive" do
    occurrence = fire()
    {:ok, {_, attempt}} = Worker.begin_attempt(occurrence.id, at())
    Monitoring.change(attempt, %{status: "accepted", finished_at: at()})
    Monitoring.change(occurrence, %{status: "delivered"})
    ingest(measurement("OK", 2))
    Repo.update_all(Occurrence, set: [status: "delivered"])
    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: at()])
    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 1, "Past work", at())

    for revision <- 1..21 do
      assert {:ok, _} =
               Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", revision, %{
                 "path" => "/",
                 "warn_percent" => 60 + revision,
                 "crit_percent" => 90
               })
    end

    Repo.update_all(Mondek.Configuration, set: [saved_at: at()])
    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(Occurrence, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(Mondek.Control, :count) == 0
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 2

    assert Repo.get_by(Mondek.Configuration,
             assignment_id: "10000000-0000-4000-8000-000000000001",
             generation: 1
           )

    assert is_nil(
             Repo.get_by(Mondek.Configuration,
               assignment_id: "10000000-0000-4000-8000-000000000001",
               generation: 2
             )
           )

    assert Repo.get_by(Mondek.Configuration,
             assignment_id: "10000000-0000-4000-8000-000000000001",
             generation: 22
           )
  end

  test "a measured downgrade supersedes an unsent critical payload with an immutable warning update" do
    firing = fire()
    ingest(measurement("WARN", 2))
    assert Repo.one!(Incident).attention_revision == 2
    assert {:ok, :superseded} = Worker.begin_attempt(firing.id, at())
    update = Repo.one!(from o in Occurrence, where: o.kind == "update")
    assert update.payload["health"] == "WARN"
    assert firing.payload["health"] == "CRIT"
    assert {:ok, {_, _}} = Worker.begin_attempt(update.id, at())
  end
end
