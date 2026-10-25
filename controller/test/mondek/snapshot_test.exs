# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.SnapshotTest do
  use Mondek.DataCase, async: false

  test "unnotified recovery retains its exact closing measurement through receipt cleanup" do
    connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)
    firing = Repo.one!(Occurrence)
    reviewed_acknowledgement_fixture(incident.id, 60, "Investigating", at())
    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 60, "Planned work", at())
    assert {:ok, {:gated, _}} = Mondek.NotificationWorker.begin_attempt(firing.id, at())

    recovery = measurement("OK", 2)
    ingest(recovery)
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.get!(Incident, incident.id).closing_observation_id == recovery["id"]

    for sequence <- 3..15, do: ingest(measurement("OK", sequence))
    detail = Monitoring.incident_detail(incident.id, at())
    assert Enum.any?(detail["evidence"], &(&1["id"] == recovery["id"]))
    assert detail["incident"]["closing_observation_id"] == recovery["id"]
    assert detail["incident"]["closure_reason"] == "measured_recovery"

    Mondek.Sweeper.sweep(DateTime.add(at(), 8 * 86_400))
    assert Repo.get!(Observation, recovery["id"])
    detail = Monitoring.incident_detail(incident.id, at())
    assert Enum.any?(detail["evidence"], &(&1["id"] == recovery["id"]))

    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: at()])
    Mondek.Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get(Incident, incident.id) == nil
    # Receipt cleanup can release the closure after incident-history cleanup.
    Mondek.Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get(Observation, recovery["id"]) == nil
  end

  test "notification inspection connects the check, gates, schedule and latest actual attempt" do
    connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)
    occurrence = Repo.one!(Occurrence)

    Monitoring.change(Repo.one!(Oban.Job), %{
      state: "scheduled",
      scheduled_at: DateTime.add(at(), 5)
    })

    reviewed_acknowledgement_fixture(incident.id, 20, "Investigating", at())
    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 30, "Planned work", at())

    inspection = fn time -> hd(Monitoring.snapshot(time)["occurrences"]) end
    current = inspection.(DateTime.add(at(), 6))
    assert current["assignment_id"] == "10000000-0000-4000-8000-000000000001"
    assert current["check_label"] == "Linux filesystem"
    assert current["incident_id"] == incident.id
    assert current["incident_status"] == "open"
    assert current["gates"] == ["acknowledgement", "maintenance"]
    assert current["waiting_on_gates"]
    assert current["gated_until"] == DateTime.to_iso8601(DateTime.add(at(), 30))
    assert current["next_retry_at"] == current["gated_until"]
    assert current["attempt_count"] == 0
    assert current["latest_attempt"] == nil

    boundary = DateTime.add(at(), 20)
    assert inspection.(boundary)["gates"] == ["maintenance"]

    assert {:ok, {:gated, _}} =
             Mondek.NotificationWorker.begin_attempt(occurrence.id, boundary)

    assert hd(Monitoring.incident_detail(incident.id, boundary)["occurrences"]) ==
             inspection.(boundary)

    ready = DateTime.add(at(), 30)
    assert inspection.(ready)["gates"] == []
    assert inspection.(ready)["next_retry_at"] == DateTime.to_iso8601(DateTime.add(at(), 5))
    assert {:ok, {_, attempt}} = Mondek.NotificationWorker.begin_attempt(occurrence.id, ready)
    current = inspection.(ready)
    assert current["attempt_count"] == 1
    assert current["latest_attempt"]["id"] == attempt.id
    assert current["latest_attempt"]["status"] == "started"
    assert current["next_retry_at"] == nil

    reviewed_maintenance_fixture(
      "10000000-0000-4000-8000-000000000001",
      60,
      "Extended work",
      ready
    )

    current = inspection.(ready)
    assert current["gates"] == ["maintenance"]
    refute current["waiting_on_gates"]

    Monitoring.change(attempt, %{
      status: "failed_or_ambiguous",
      http_status: 503,
      error: "rejected"
    })

    Monitoring.change(occurrence, %{status: "exhausted"})
    current = inspection.(ready)
    assert current["latest_attempt"]["http_status"] == 503
    assert current["latest_attempt"]["error"] == "rejected"
    assert current["next_retry_at"] == nil
    assert current["gates"] == ["maintenance"]
    refute current["waiting_on_gates"]
  end

  test "legacy first-execution progress cannot claim a measurement in public configuration state" do
    connect()
    ingest(measurement("CRIT"))
    saved = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    Monitoring.save_assignment(
      "10000000-0000-4000-8000-000000000001",
      1,
      Map.put(saved.params, "crit_percent", 95)
    )

    connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})
    ingest(measurement("UNKNOWN", 2, %{"generation" => 2, "complete" => false, "results" => []}))

    Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"), %{
      observed_generation: 2
    })

    assignment =
      Enum.find(
        Monitoring.snapshot(at())["assignments"],
        &(&1["id"] == "10000000-0000-4000-8000-000000000001")
      )

    assert assignment["desired_generation"] == 2
    assert assignment["observed_generation"] == 1
    assert assignment["current"]["confirmed_generation"] == 1
    assert assignment["current"]["confirmed_params"]["crit_percent"] == 90
  end

  test "recovery notifications bypass maintenance while obsolete firing has no eligible retry" do
    connect()
    ingest(measurement("CRIT"))
    firing = Repo.one!(Occurrence)
    Mondek.NotificationWorker.begin_attempt(firing.id, at())
    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 60, "Planned work", at())
    ingest(measurement("OK", 2))

    snapshot = Monitoring.snapshot(at())
    resolved = Enum.find(snapshot["occurrences"], &(&1["kind"] == "resolved"))
    obsolete = Enum.find(snapshot["occurrences"], &(&1["id"] == firing.id))
    assert resolved["gates"] == []
    assert resolved["gated_until"] == nil
    assert resolved["next_retry_at"] != nil
    assert {:ok, {_, _}} = Mondek.NotificationWorker.begin_attempt(resolved["id"], at())
    assert obsolete["gates"] == []
    assert obsolete["next_retry_at"] == nil
    assert {:ok, :superseded} = Mondek.NotificationWorker.begin_attempt(firing.id, at())
  end

  defp terminal_history(count) do
    for index <- 1..count do
      incident =
        Repo.insert!(%Incident{
          assignment_id: "10000000-0000-4000-8000-000000000002",
          health: "CRIT",
          status: "closed",
          opened_at: DateTime.add(at(), index),
          closed_at: DateTime.add(at(), index + 1),
          closure_reason: "measured_recovery",
          opening_generation: 1
        })

      Repo.insert!(%Occurrence{
        incident_id: incident.id,
        kind: "resolved",
        attention_revision: 2,
        payload: %{"incident_id" => incident.id},
        destination: "http://target:8080/webhook",
        inserted_at: DateTime.add(at(), index),
        status: "delivered"
      })
    end
  end

  test "new terminal history cannot hide an old open incident or pending occurrence" do
    connect()
    first = measurement("CRIT", 1)
    ingest(first)
    open = Repo.one!(Incident)
    pending = Repo.one!(Occurrence)
    terminal_history(150)

    for sequence <- 2..131 do
      ingest(measurement("CRIT", sequence), DateTime.add(at(), sequence))
    end

    snapshot = Monitoring.snapshot(DateTime.add(at(), 132))
    assert length(snapshot["incidents"]) == 101
    assert Enum.count(snapshot["incidents"], &(&1["status"] == "open")) == 1
    assert Enum.any?(snapshot["incidents"], &(&1["id"] == open.id))
    assert length(snapshot["occurrences"]) == 101
    assert Enum.any?(snapshot["occurrences"], &(&1["id"] == pending.id))

    assert snapshot["notification_backlog"] == %{
             "total" => 1,
             "returned" => 1,
             "omitted" => 0,
             "limit" => 100
           }

    assert Enum.any?(snapshot["evidence"], &(&1["id"] == first["id"]))
    assert length(snapshot["evidence"]) == 122

    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(at(), 8 * 86_400))
    assert Repo.get!(Observation, first["id"])
    assert Repo.aggregate(Observation, :count) == 3
    assert Monitoring.snapshot()["retention"] =~ "100000"
    assert Monitoring.snapshot()["retention"] =~ "protected"
  end

  test "a bounded oldest backlog includes exhaustion and discloses every omitted occurrence" do
    connect()
    ingest(measurement("CRIT", 1))
    incident = Repo.one!(Incident)
    oldest = Repo.one!(Occurrence)
    Monitoring.change(oldest, %{status: "exhausted"})

    for revision <- 2..151 do
      Repo.insert!(%Occurrence{
        incident_id: incident.id,
        kind: "update",
        attention_revision: revision,
        payload: %{"incident_id" => incident.id},
        destination: "http://target:8080/webhook",
        inserted_at: DateTime.add(at(), revision),
        status: "pending"
      })
    end

    terminal_history(150)
    snapshot = Monitoring.snapshot()
    assert length(snapshot["occurrences"]) == 200
    assert hd(snapshot["occurrences"])["id"] == oldest.id
    assert hd(snapshot["occurrences"])["status"] == "exhausted"

    assert snapshot["notification_backlog"] == %{
             "total" => 151,
             "returned" => 100,
             "omitted" => 51,
             "limit" => 100
           }
  end

  test "other assignment activity cannot hide a stalled assignment's execution or confirmed evidence" do
    connect()
    confirmed = measurement("OK", 1)
    ingest(confirmed)

    unavailable =
      measurement("UNKNOWN", 2, %{
        "complete" => false,
        "results" => [],
        "diagnostic" => "worker timeout"
      })

    ingest(unavailable)

    for sequence <- 3..123 do
      report =
        measurement("OK", sequence, %{"assignment_id" => "10000000-0000-4000-8000-000000000002"})
        |> put_in(["results", Access.at(0), "key"], "readiness")

      ingest(report, DateTime.add(at(), sequence))
    end

    evidence_ids = MapSet.new(Monitoring.snapshot()["evidence"], & &1["id"])
    assert MapSet.member?(evidence_ids, confirmed["id"])
    assert MapSet.member?(evidence_ids, unavailable["id"])
    assert MapSet.size(evidence_ids) <= 126

    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(at(), 8 * 86_400))
    assert Repo.get!(Observation, confirmed["id"])
    assert Repo.get!(Observation, unavailable["id"])
    current = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current
    assert current["health"] == "OK"
    assert current["confirmed_observation_id"] == confirmed["id"]
  end

  test "a long-open incident remains in recent history immediately after measured recovery" do
    connect()
    ingest(measurement("CRIT", 1))
    old_incident = Repo.one!(Incident)
    terminal_history(150)
    recovered_at = DateTime.add(at(), 200)
    time = DateTime.to_iso8601(recovered_at)

    recovery =
      measurement("OK", 2, %{"started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)

    ingest(recovery, recovered_at)
    snapshot = Monitoring.snapshot(recovered_at)
    assert length(snapshot["incidents"]) == 100
    assert hd(snapshot["incidents"])["id"] == old_incident.id
    assert hd(snapshot["incidents"])["closure_reason"] == "measured_recovery"
  end

  test "selected incident inspection keeps its own delivery and control chain after unrelated churn" do
    connect()
    ingest(measurement("CRIT", 1))
    incident = Repo.one!(Incident)
    firing = Repo.one!(Occurrence)
    Monitoring.change(firing, %{status: "delivered"})

    attempt =
      Repo.insert!(%Attempt{
        occurrence_id: firing.id,
        status: "accepted",
        http_status: 204,
        started_at: at(),
        finished_at: at()
      })

    reviewed_acknowledgement_fixture(incident.id, 60, "Investigating this episode", at())
    terminal_history(150)
    refute Enum.any?(Monitoring.snapshot()["occurrences"], &(&1["id"] == firing.id))

    detail = Monitoring.incident_detail(incident.id)
    assert detail["incident"]["id"] == incident.id
    assert Enum.any?(detail["occurrences"], &(&1["id"] == firing.id))
    assert Enum.any?(detail["attempts"], &(&1["id"] == attempt.id))
    assert Enum.any?(detail["controls"], &(&1["reason"] == "Investigating this episode"))
    assert Enum.any?(detail["evidence"], &(&1["id"] == firing.payload["observation_id"]))
    assert detail["limits"]["occurrences"]["total"] == 1
    assert detail["limits"]["attempts"]["total"] == 1
    assert Monitoring.incident_detail("invalid") == nil
    assert Monitoring.incident_detail(Ecto.UUID.generate()) == nil
  end

  test "selected incident detail bounds its own churn and discloses omissions" do
    connect()
    ingest(measurement("CRIT", 1))
    incident = Repo.one!(Incident)
    firing = Repo.one!(Occurrence)
    Monitoring.change(firing, %{status: "delivered"})

    occurrences =
      for revision <- 2..252 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: incident.id,
          kind: "update",
          attention_revision: revision,
          payload: %{},
          destination: "http://target:8080/webhook",
          inserted_at: DateTime.add(at(), revision),
          status: "pending"
        }
      end

    Repo.insert_all(Occurrence, occurrences)

    Repo.insert_all(
      Attempt,
      for occurrence <- occurrences, offset <- 1..3 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: occurrence.id,
          status: "failed_or_ambiguous",
          started_at: DateTime.add(occurrence.inserted_at, offset)
        }
      end
    )

    detail = Monitoring.incident_detail(incident.id)
    assert Enum.any?(detail["occurrences"], &(&1["id"] == firing.id))
    assert detail["limits"]["occurrences"]["total"] == 252
    assert detail["limits"]["occurrences"]["returned"] == 201
    assert detail["limits"]["occurrences"]["omitted"] == 51
    assert length(detail["attempts"]) <= 401
    assert detail["limits"]["attempts"]["total"] == 753
    assert detail["limits"]["attempts"]["omitted"] == 753 - length(detail["attempts"])

    for occurrence <- detail["occurrences"], occurrence["id"] != firing.id do
      assert Enum.any?(detail["attempts"], &(&1["occurrence_id"] == occurrence["id"]))
    end
  end
end
