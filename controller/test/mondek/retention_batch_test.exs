# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RetentionBatchTest do
  use Mondek.DataCase, async: false
  alias Mondek.Sweeper

  test "monitoring parent batches keep unselected attempts and pending delivery intact" do
    episodes =
      for index <- 1..3 do
        incident =
          Repo.insert!(%Mondek.MonitoringIncident{
            scope_kind: "coverage",
            source_id: "retention",
            scope_key: "coverage:retention",
            label: "Expired coverage episode",
            status: "closed",
            opened_at: at(),
            closed_at: DateTime.add(at(), index),
            closure_reason: "monitoring_restored",
            member_count: 1
          })

        occurrence =
          Repo.insert!(%Occurrence{
            monitoring_incident_id: incident.id,
            kind: "resolved",
            attention_revision: 1,
            payload: %{"monitoring_incident_id" => incident.id},
            destination: "http://target:8080/webhook",
            status: if(index == 1, do: "pending", else: "delivered"),
            inserted_at: at()
          })

        attempt =
          Repo.insert!(%Attempt{
            occurrence_id: occurrence.id,
            status: "accepted",
            started_at: at(),
            finished_at: at(),
            http_status: 204
          })

        {incident.id, occurrence.id, attempt.id}
      end

    future = DateTime.add(at(), 40 * 86_400)
    [protected | eligible] = episodes

    for {{incident_id, occurrence_id, attempt_id}, index} <- Enum.with_index(eligible) do
      assert {:ok, %{deleted: %{monitoring_incidents: 1}, more?: true}} =
               Sweeper.sweep(future, 1)

      assert is_nil(Repo.get(Mondek.MonitoringIncident, incident_id))
      assert is_nil(Repo.get(Occurrence, occurrence_id))
      assert is_nil(Repo.get(Attempt, attempt_id))

      for {retained_id, retained_occurrence, retained_attempt} <-
            [protected | Enum.drop(eligible, index + 1)] do
        assert Repo.get!(Mondek.MonitoringIncident, retained_id)
        assert Repo.get!(Occurrence, retained_occurrence)
        assert Repo.get!(Attempt, retained_attempt)
      end
    end

    assert {:ok, %{deleted: %{monitoring_incidents: 0}, more?: false}} =
             Sweeper.sweep(future, 1)

    {protected_id, protected_occurrence, protected_attempt} = protected
    Monitoring.change(Repo.get!(Occurrence, protected_occurrence), %{status: "delivered"})
    assert {:ok, %{deleted: %{monitoring_incidents: 1}}} = Sweeper.sweep(future, 1)
    assert is_nil(Repo.get(Mondek.MonitoringIncident, protected_id))
    assert is_nil(Repo.get(Occurrence, protected_occurrence))
    assert is_nil(Repo.get(Attempt, protected_attempt))
  end

  test "small passes delete the same parent and children while skipping protected older episodes" do
    episodes = terminal_episodes(4)
    [protected | eligible] = episodes
    protected_occurrence = hd(protected.occurrences)
    Monitoring.change(Repo.get!(Occurrence, protected_occurrence), %{status: "exhausted"})
    future = DateTime.add(at(), 40 * 86_400)

    for {episode, index} <- Enum.with_index(eligible) do
      # Each pass can run in a fresh process: progress belongs to committed rows,
      # not an in-memory cursor owned by the previous sweeper process.
      assert {:ok, %{deleted: deleted, more?: true}} =
               Task.async(fn -> Sweeper.sweep(future, 1) end) |> Task.await()

      assert deleted.incidents == 1
      assert deleted.observations <= 1
      assert is_nil(Repo.get(Incident, episode.id))
      for id <- episode.occurrences, do: assert(is_nil(Repo.get(Occurrence, id)))
      for id <- episode.attempts, do: assert(is_nil(Repo.get(Attempt, id)))

      for retained <- [protected | Enum.drop(eligible, index + 1)] do
        assert Repo.get!(Incident, retained.id)
        for id <- retained.occurrences, do: assert(Repo.get!(Occurrence, id))
        for id <- retained.attempts, do: assert(Repo.get!(Attempt, id))
      end
    end

    # The exhausted delivery retains its episode until explicitly terminal.
    assert Repo.aggregate(Incident, :count) == 1
    Monitoring.change(Repo.get!(Occurrence, protected_occurrence), %{status: "superseded"})
    assert {:ok, %{deleted: %{incidents: 1}}} = Sweeper.sweep(future, 1)
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(Occurrence, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0

    # Drain the separate receipt backlog, then prove an empty pass stops catch-up.
    for _ <- 1..10, do: assert({:ok, _} = Sweeper.sweep(future, 1))
    assert {:ok, %{more?: false}} = Sweeper.sweep(future, 1)
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 8
  end

  test "a rolled back cleanup pass leaves complete episodes available to retry" do
    episodes = terminal_episodes(2)
    before_counts = counts()
    future = DateTime.add(at(), 40 * 86_400)

    assert {:error, :interrupted} =
             Repo.transaction(fn ->
               assert {:ok, %{deleted: %{incidents: 1}}} = Sweeper.sweep(future, 1)
               Repo.rollback(:interrupted)
             end)

    assert counts() == before_counts

    for episode <- episodes do
      assert Repo.get!(Incident, episode.id)
      for id <- episode.occurrences, do: assert(Repo.get!(Occurrence, id))
      for id <- episode.attempts, do: assert(Repo.get!(Attempt, id))
    end

    assert {:ok, %{deleted: %{incidents: 1}}} = Sweeper.sweep(future, 1)
    assert Repo.aggregate(Incident, :count) == 1
  end

  test "configured age and count limits apply without pruning current evidence" do
    previous = Application.fetch_env!(:mondek, :retention)
    on_exit(fn -> Application.put_env(:mondek, :retention, previous) end)
    connect()

    for seq <- 1..5,
        do:
          assert(
            disposition(ingest(measurement("OK", seq), DateTime.add(at(), seq, :millisecond))) ==
              "current"
          )

    newest = Repo.get!(Assignment, report()["assignment_id"]).current["confirmed_observation_id"]

    Application.put_env(:mondek, :retention, %{
      receipt_days: 14,
      history_days: 60,
      max_observations: 2
    })

    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 8 * 86400))
    assert Repo.aggregate(Observation, :count) == 2
    assert Repo.get!(Observation, newest)

    Application.put_env(:mondek, :retention, %{
      receipt_days: 1,
      history_days: 60,
      max_observations: 100
    })

    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 8 * 86400))
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.get!(Observation, newest)
    assert Mondek.Retention.summary() =~ "1 days"
  end

  test "configured terminal history age protects completed episodes until its cutoff" do
    previous = Application.fetch_env!(:mondek, :retention)
    on_exit(fn -> Application.put_env(:mondek, :retention, previous) end)
    [episode] = terminal_episodes(1)

    Application.put_env(:mondek, :retention, %{
      receipt_days: 7,
      history_days: 60,
      max_observations: 100_000
    })

    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 40 * 86400))
    assert Repo.get!(Incident, episode.id)
    for id <- episode.occurrences, do: assert(Repo.get!(Occurrence, id))
    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 61 * 86400))
    assert is_nil(Repo.get(Incident, episode.id))
    for id <- episode.occurrences, do: assert(is_nil(Repo.get(Occurrence, id)))
  end

  test "configured cleanup and live ingestion preserve the committed current observation" do
    previous = Application.fetch_env!(:mondek, :retention)
    on_exit(fn -> Application.put_env(:mondek, :retention, previous) end)

    Application.put_env(:mondek, :retention, %{
      receipt_days: 7,
      history_days: 30,
      max_observations: 3
    })

    connect()

    for sequence <- 1..10,
        do:
          assert(
            disposition(
              ingest(measurement("OK", sequence), DateTime.add(at(), sequence, :millisecond))
            ) == "current"
          )

    writer =
      Task.async(fn ->
        for sequence <- 11..30 do
          assert disposition(
                   ingest(measurement("OK", sequence), DateTime.add(at(), sequence, :millisecond))
                 ) == "current"
        end
      end)

    for _ <- 1..5, do: assert({:ok, _} = Sweeper.sweep(at(), 2))
    Task.await(writer, 30000)
    for _ <- 1..20, do: assert({:ok, _} = Sweeper.sweep(at(), 2))
    current = Repo.get!(Assignment, report()["assignment_id"]).current["confirmed_observation_id"]
    assert Repo.get!(Observation, current)
    assert Repo.aggregate(Observation, :count) <= 3
  end

  defp terminal_episodes(count) do
    connect()

    for index <- 1..count do
      assert disposition(ingest(measurement("CRIT", 2 * index - 1))) == "current"
      incident = Repo.one!(from i in Incident, where: i.status == "open")
      occurrence = Repo.one!(from o in Occurrence, where: o.incident_id == ^incident.id)

      Repo.insert!(%Attempt{
        occurrence_id: occurrence.id,
        status: "accepted",
        started_at: at(),
        finished_at: at(),
        http_status: 204
      })

      Monitoring.change(occurrence, %{status: "delivered", delivered_at: at()})
      assert disposition(ingest(measurement("OK", 2 * index))) == "current"
      Monitoring.change(Repo.get!(Incident, incident.id), %{closed_at: DateTime.add(at(), index)})
    end

    Repo.update_all(Occurrence, set: [status: "delivered", delivered_at: at()])
    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: at()])

    for incident <- Repo.all(from i in Incident, order_by: [i.closed_at, i.id]) do
      occurrences =
        Repo.all(from o in Occurrence, where: o.incident_id == ^incident.id, select: o.id)

      attempts = Repo.all(from a in Attempt, where: a.occurrence_id in ^occurrences, select: a.id)
      %{id: incident.id, occurrences: occurrences, attempts: attempts}
    end
  end

  defp counts do
    for schema <- [Incident, Occurrence, Attempt, Observation], into: %{} do
      {schema, Repo.aggregate(schema, :count)}
    end
  end
end
