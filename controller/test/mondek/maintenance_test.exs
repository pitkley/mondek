# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    Maintenance,
    MaintenanceWindow,
    MaintenanceEvent,
    NotificationWorker,
    ResultStream,
    Sweeper
  }

  test "future and long windows use exact half-open boundaries without an activation job" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)

    p =
      proposal()
      |> Map.merge(%{
        "start_mode" => "scheduled",
        "starts_local" => "2009-09-15T09:00:00",
        "ends_local" => "2010-09-15T09:00:00"
      })

    window = save(p)
    assert window["status"] == "upcoming"

    assert {:ok, {:gated, 86_400}} =
             NotificationWorker.begin_attempt(occurrence.id, ~U[2009-09-15 09:00:00.000000Z])

    assert Maintenance.active_for(
             Repo.one!(Incident),
             Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"),
             ~U[2009-09-15 08:59:59.999999Z]
           ) == []

    assert Maintenance.active_for(
             Repo.one!(Incident),
             Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"),
             ~U[2010-09-15 09:00:00.000000Z]
           ) == []

    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "overlapping reviewed windows and acknowledgement remain independent" do
    connect()
    ingest(measurement("CRIT"))
    one = save(proposal())
    two = save(proposal() |> Map.put("name", "Second window"))

    third = save(Map.put(proposal(), "name", "Third independent window"))
    {:ok, detail} = Maintenance.get(third["id"], at())
    extended = save(Map.put(detail["proposal"], "ends_local", "2009-09-17T08:00:01"))
    assert extended["revision"] == third["revision"] + 1

    assert {:error, :stale} =
             Maintenance.cancel(third["id"], third["revision"], "Old review", at())

    assert {:ok, _} =
             Maintenance.cancel(
               extended["id"],
               extended["revision"],
               "End just this window",
               at()
             )

    assert length(
             Maintenance.active_for(
               Repo.one!(Incident),
               Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"),
               at()
             )
           ) == 2

    assert {:ok, _} = Maintenance.cancel(one["id"], one["revision"], "Cancel one", at())

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(Repo.one!(Incident).id, 3600, "Acknowledged", at())

    assert {:ok, _} = Maintenance.cancel(two["id"], two["revision"], "Cancel second", at())

    assert {:ok, {:gated, 3600}} =
             NotificationWorker.begin_attempt(Repo.one!(Occurrence).id, at())

    assert Enum.count(
             Maintenance.list(%{"status" => "history"}, at())["windows"],
             &(&1["status"] == "cancelled")
           ) == 3
  end

  test "review binds scope membership, proposal and concurrent edits" do
    p = proposal()
    assert {:ok, review} = Maintenance.preview(p, 1, at())

    assert {:error, :review_changed} =
             Maintenance.apply(review["review_token"], Map.put(p, "reason", "Changed"), at())

    window = save(p)
    assert {:ok, detail} = Maintenance.get(window["id"], at())
    changed = Map.put(detail["proposal"], "reason", "Reviewed edit")
    assert {:ok, review} = Maintenance.preview(changed, 1, at())

    assert {:ok, _} =
             Maintenance.cancel(window["id"], window["revision"], "Concurrent cancel", at())

    assert {:error, :stale} = Maintenance.apply(review["review_token"], changed, at())

    assert {:error, :stale} =
             Maintenance.cancel(window["id"], window["revision"], "Stale cancel", at())
  end

  test "Start now pagination preserves original instants and immutable audit snapshots" do
    p = proposal()
    assert {:ok, review} = Maintenance.preview(p, 1, at())
    assert {:ok, next} = Maintenance.preview(p, 2, DateTime.add(at(), 10), review["review_token"])
    assert next["starts_at"] == review["starts_at"]
    assert next["fingerprint"] == review["fingerprint"]
    assert next["review_token"] == review["review_token"]
    assert {:ok, window} = Maintenance.apply(review["review_token"], p, DateTime.add(at(), 10))
    assert window["starts_at"] == review["starts_at"]
    assert {:ok, detail} = Maintenance.get(window["id"], DateTime.add(at(), 20))
    edited = Map.put(detail["proposal"], "reason", "Update reason only")
    assert {:ok, preview} = Maintenance.preview(edited, 1, DateTime.add(at(), 20))

    assert {:ok, updated} =
             Maintenance.apply(preview["review_token"], edited, DateTime.add(at(), 20))

    assert updated["starts_at"] == window["starts_at"]
    assert Repo.aggregate(MaintenanceEvent, :count) == 2
    original = Repo.one!(from e in MaintenanceEvent, where: e.revision == 1)
    assert original.snapshot["reason"] == "Scheduled repair"
    assert original.snapshot["tzdata_version"]
  end

  test "target scope selects individual results, exact environment and source, surviving no matches" do
    first = inventory()
    assert {:ok, _} = Monitoring.inventory(first, at())
    a = Repo.one!(from a in Assignment, where: a.source_id == "maintenance-source")

    streams =
      Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id, order_by: s.result_key)

    selected = hd(streams)
    assert {:ok, seed} = Maintenance.seed(a.id, selected.id, at())
    assert seed["proposal"]["scope"] == "target"
    p = Map.put(seed["proposal"], "reason", "Moving orders volume")
    window = save(p)
    assert Enum.count(Maintenance.for_stream(selected.id, at())) == 1
    assert Maintenance.for_stream(List.last(streams).id, at()) == []
    fake = %Incident{stream_id: selected.id, environment: nil}
    assert length(Maintenance.active_for(fake, a, at())) == 1
    assert Maintenance.active_for(%{fake | environment: "production"}, a, at()) == []
    assert Maintenance.active_for(fake, %{a | source_id: "different-source"}, at()) == []

    assert {:ok, _} =
             Monitoring.control(
               control(%{
                 "installation_id" => first["installation_id"],
                 "session_id" => first["session_id"],
                 "prepared" => %{a.id => a.desired_generation}
               }),
               at()
             )

    results =
      Enum.map(streams, fn s ->
        %{
          "key" => s.result_key,
          "health" => "CRIT",
          "summary" => "Measured volume failure",
          "source_at" => "2009-09-15T08:00:00.010000Z"
        }
      end)

    report =
      measurement("CRIT", 1, %{
        "assignment_id" => a.id,
        "installation_id" => first["installation_id"],
        "session_id" => first["session_id"],
        "generation" => a.desired_generation,
        "results" => results
      })

    assert {:ok, _} =
             Monitoring.ingest(
               envelope([report], %{
                 "installation_id" => first["installation_id"],
                 "session_id" => first["session_id"]
               }),
               at()
             )

    by_result =
      Repo.all(
        from o in Occurrence,
          join: i in Incident,
          on: i.id == o.incident_id,
          where: i.assignment_id == ^a.id,
          select: {i.result_key, o}
      )
      |> Map.new()

    assert {:ok, {:gated, _}} =
             NotificationWorker.begin_attempt(by_result[selected.result_key].id, at())

    sibling = by_result[List.last(streams).result_key]
    assert {:ok, {_, %Attempt{}}} = NotificationWorker.begin_attempt(sibling.id, at())

    inspected =
      Monitoring.inspect_occurrences(Map.values(by_result), at()) |> Map.new(&{&1["id"], &1})

    assert inspected[by_result[selected.result_key].id]["gates"] == ["maintenance"]
    assert inspected[sibling.id]["gates"] == []
    assert Repo.aggregate(Attempt, :count) == 1

    assert {:ok, _} =
             Monitoring.inventory(%{first | "inventory_revision" => 2, "checks" => []}, at())

    assert {:ok, detail} = Maintenance.get(window["id"], at())
    assert detail["match_count"] == 0
    assert {:ok, _} = Monitoring.inventory(inventory(), at())
    assert {:ok, detail} = Maintenance.get(window["id"], at())
    assert detail["match_count"] == 1
    assert hd(detail["current_matches"])["assignment_id"] != a.id
  end

  test "shortening or cancelling a snoozed window wakes the same durable job safely" do
    connect()
    ingest(measurement("CRIT"))
    window = save(proposal())
    occurrence = Repo.one!(Occurrence)

    job =
      Monitoring.change(Repo.one!(Oban.Job), %{state: "executing", attempt: 1, attempted_at: at()})

    assert {:ok, {:gated, 3600}} = NotificationWorker.begin_attempt(occurrence.id, at(), job)

    assert {:ok, _} =
             Maintenance.cancel(window["id"], window["revision"], "Completed early", at())

    assert {:ok, {0, _}} = Sweeper.wake_held_notifications(at())
    assert :ok = Oban.Engines.Basic.snooze_job(Oban.config(), job, 3600)
    assert {:ok, {1, _}} = Sweeper.wake_held_notifications(at())
    assert Repo.get!(Oban.Job, job.id).attempt == 0
    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.one!(Occurrence).payload == occurrence.payload
  end

  test "malformed and past proposals do not leave controls or windows" do
    p = proposal()

    for changed <- [
          Map.put(p, "ends_local", "2003-01-01T00:00:00"),
          Map.put(p, "scope", "all"),
          Map.put(p, "timezone", "unknown"),
          Map.put(p, "reason", String.duplicate(" ", 500) <> "x"),
          Map.put(p, "assignment_id", nil),
          Map.put(p, "extra", "unexpected")
        ] do
      assert {:error, {:invalid, _}} = Maintenance.preview(changed, 1, at())
    end

    assert {:error, :not_found} = Maintenance.get(nil)
    assert {:error, :not_found} = Maintenance.seed(nil)
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    assert Repo.aggregate(MaintenanceEvent, :count) == 0
  end

  test "production dispatch samples the clock after a lock wait crossing the start boundary" do
    connect()
    ingest(measurement("CRIT"))
    now = Monitoring.now()
    starts = DateTime.add(now, 2)
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, now)

    p =
      seed["proposal"]
      |> Map.merge(%{
        "reason" => "Clock barrier",
        "start_mode" => "scheduled",
        "starts_local" => Mondek.MaintenanceTime.local(starts, "Etc/UTC"),
        "ends_local" => Mondek.MaintenanceTime.local(DateTime.add(starts, 3600), "Etc/UTC")
      })

    assert {:ok, preview} = Maintenance.preview(p, 1, now)
    assert {:ok, _} = Maintenance.apply(preview["review_token"], p, now)
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Maintenance.lock!()
          send(owner, :maintenance_locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :maintenance_locked
    job = Repo.one!(Oban.Job)
    occurrence = Repo.one!(Occurrence)
    worker = Task.async(fn -> NotificationWorker.begin_attempt(occurrence.id, nil, job) end)
    assert Task.yield(worker, 20) == nil
    Process.sleep(max(0, DateTime.diff(starts, Monitoring.now(), :millisecond)) + 50)
    send(blocker.pid, :release)
    Task.await(blocker)
    assert {:ok, {:gated, seconds}} = Task.await(worker)
    assert seconds > 3500
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "an edit waiting across activation cannot reschedule the original start" do
    now = Monitoring.now()
    starts = DateTime.add(now, 2)
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, now)

    p =
      seed["proposal"]
      |> Map.merge(%{
        "reason" => "Edit barrier",
        "start_mode" => "scheduled",
        "starts_local" => Mondek.MaintenanceTime.local(starts, "Etc/UTC"),
        "ends_local" => Mondek.MaintenanceTime.local(DateTime.add(starts, 7200), "Etc/UTC")
      })

    {:ok, preview} = Maintenance.preview(p, 1, now)
    {:ok, window} = Maintenance.apply(preview["review_token"], p, now)
    {:ok, detail} = Maintenance.get(window["id"], now)

    p =
      Map.put(
        detail["proposal"],
        "starts_local",
        Mondek.MaintenanceTime.local(DateTime.add(starts, 3600), "Etc/UTC")
      )

    {:ok, preview} = Maintenance.preview(p, 1, now)
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Maintenance.lock!()
          send(owner, :window_locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :window_locked
    editor = Task.async(fn -> Maintenance.apply(preview["review_token"], p) end)
    assert Task.yield(editor, 20) == nil
    Process.sleep(max(0, DateTime.diff(starts, Monitoring.now(), :millisecond)) + 50)
    send(blocker.pid, :release)
    Task.await(blocker)
    assert {:error, {:invalid, reason}} = Task.await(editor)
    assert reason =~ "original start"
    assert Repo.get!(MaintenanceWindow, window["id"]).starts_at == starts
  end

  defp proposal do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, at())
    Map.put(seed["proposal"], "reason", "Scheduled repair")
  end

  defp save(p) do
    assert {:ok, review} = Maintenance.preview(p, 1, at())
    assert {:ok, window} = Maintenance.apply(review["review_token"], p, at())
    window
  end

  defp inventory do
    control(%{
      "installation_id" => Ecto.UUID.generate(),
      "session_id" => Ecto.UUID.generate(),
      "prepared" => %{}
    })
    |> Map.merge(%{
      "runner_label" => "Volume observer",
      "source_id" => "maintenance-source",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [
        %{
          "key" => "volumes",
          "label" => "Volumes",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => nil,
          "params_owner" => "source",
          "params" => %{},
          "parameter_schema" => %{"fields" => %{}},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" =>
            Enum.map(["orders", "other"], fn key ->
              %{
                "key" => key,
                "label" => key,
                "target" => %{"kind" => "volume", "key" => key, "label" => key}
              }
            end)
        }
      ]
    })
  end
end
