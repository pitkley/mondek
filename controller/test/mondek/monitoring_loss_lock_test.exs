# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringLossLockTest do
  use Mondek.DataCase, async: false

  alias Mondek.{Maintenance, MonitoringIncident, MonitoringLoss, ResultStream, Runner}

  setup do
    grace = Application.get_env(:mondek, :monitoring_loss_grace_seconds)
    contact = Application.get_env(:mondek, :monitoring_contact_seconds)
    Application.put_env(:mondek, :monitoring_loss_grace_seconds, 5)
    Application.put_env(:mondek, :monitoring_contact_seconds, 1000)

    on_exit(fn ->
      Application.put_env(:mondek, :monitoring_loss_grace_seconds, grace)
      Application.put_env(:mondek, :monitoring_contact_seconds, contact)
    end)

    assert {:ok, _} = connect()

    for id <- ["10000000-0000-4000-8000-000000000002", "10000000-0000-4000-8000-000000000003"] do
      assert {:ok, _} = withdraw_source_fixture(id, "Keep one measured result", at())
    end

    confirmed = sample("OK", 1, 1)
    unavailable = sample("UNKNOWN", 2, 2)
    assert disposition(ingest(confirmed, time(1))) == "current"
    assert disposition(ingest(unavailable, time(2))) == "current"
    refute Repo.exists?(MonitoringIncident)
    %{confirmed: confirmed, unavailable: unavailable}
  end

  for operation <- [:control, :ingest] do
    @operation operation

    test "monitoring-loss episode insertion does not deadlock with #{@operation} holding the runner row",
         %{confirmed: confirmed, unavailable: unavailable} do
      operation = @operation
      parent = self()
      next = sample("UNKNOWN", 3, 8)

      sweep =
        Task.async(fn ->
          capture_failure(fn ->
            Repo.transaction(fn ->
              Maintenance.lock!(:shared)
              MonitoringLoss.lock!()
              send(parent, {:sweep_holds_advisory, backend_pid()})

              receive do
                :reconcile -> MonitoringLoss.reconcile(time(7))
              after
                5000 -> raise "Monitoring-loss reconciliation was not released"
              end
            end)
          end)
        end)

      assert_receive {:sweep_holds_advisory, sweep_backend}, 1000

      mutation =
        Task.async(fn ->
          capture_failure(fn ->
            Repo.checkout(fn ->
              send(parent, {:mutation_backend, backend_pid()})

              mutate(operation, next)
            end)
          end)
        end)

      try do
        assert_receive {:mutation_backend, mutation_backend}, 1000
        refute mutation_backend == sweep_backend

        await_advisory_wait(
          mutation_backend,
          sweep_backend,
          System.monotonic_time(:millisecond) + 2000
        )

        # The actual control/ingest transaction now owns the runner row and is
        # waiting behind the sweep. The sweep must still be able to insert its
        # incident: the runner foreign key takes KEY SHARE on that same row.
        # FOR UPDATE creates a cycle; NO KEY UPDATE retains writer exclusion
        # while allowing this reference to an immutable runner identity.
        send(sweep.pid, :reconcile)
        assert {:ok, {:ok, _}} = Task.await(sweep, 5000)
        assert {:ok, response} = Task.await(mutation, 5000)

        assert_mutation(operation, response)

        episode = Repo.one!(MonitoringIncident)
        assert episode.status == "open"
        assert episode.runner_id == control()["installation_id"]
        assert episode.member_count == 1
        assert Repo.aggregate(Occurrence, :count) == 1
        assert Repo.one!(Occurrence).monitoring_incident_id == episode.id

        runner = Repo.get!(Runner, control()["installation_id"])
        assert runner.session_id == control()["session_id"]
        assert runner.boot == 1
        assert runner.last_seen_at == last_contact(operation)

        stream =
          Repo.one!(
            from s in ResultStream,
              where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
          )

        latest = latest(operation, next, unavailable)
        assert stream.current["observation_id"] == latest["id"]
        assert stream.current["confirmed_observation_id"] == confirmed["id"]
        assert stream.current["health"] == "OK"
        assert stream.current["knowledge"] == "unavailable"

        # The lock change must preserve session fencing and subsequent genuine
        # recovery; neither a heartbeat nor unavailable evidence restores health.
        assert {:error, :session_conflict} =
                 Monitoring.ingest(
                   envelope([sample("OK", 4, 9)], %{"session_id" => Ecto.UUID.generate()}),
                   time(9)
                 )

        assert disposition(ingest(sample("OK", 4, 9), time(9))) == "current"
        assert Repo.get!(MonitoringIncident, episode.id).closure_reason == "monitoring_restored"
        assert Repo.aggregate(MonitoringIncident, :count) == 1
        refute Repo.exists?(Incident)
      after
        send(sweep.pid, :reconcile)
        Task.shutdown(mutation, :brutal_kill)
        Task.shutdown(sweep, :brutal_kill)
      end
    end
  end

  test "the runner lock still serializes ingestion with a competing session transition" do
    parent = self()
    report = sample("UNKNOWN", 3, 3)
    replacement = control(%{"boot" => 2, "session_id" => Ecto.UUID.generate()})

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert disposition(ingest(report, time(3))) == "current"
          send(parent, {:ingestion_holds_runner, backend_pid()})

          receive do
            :commit -> :committed
          after
            5000 -> raise "Ingestion writer was not released"
          end
        end)
      end)

    assert_receive {:ingestion_holds_runner, writer_backend}, 1000

    transition =
      Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {:transition_backend, backend_pid()})
          Monitoring.control(replacement, time(4))
        end)
      end)

    try do
      assert_receive {:transition_backend, transition_backend}, 1000

      await_row_wait(
        transition_backend,
        writer_backend,
        System.monotonic_time(:millisecond) + 2000
      )

      send(writer.pid, :commit)
      assert {:ok, :committed} = Task.await(writer, 5000)
      assert {:ok, _} = Task.await(transition, 5000)
      runner = Repo.get!(Runner, replacement["installation_id"])
      assert runner.session_id == replacement["session_id"]
      assert runner.boot == 2
      assert Repo.get!(Observation, report["id"]).payload == report
      assert {:error, :session_conflict} = ingest(sample("OK", 4, 5), time(5))

      recovery = sample("OK", 4, 5) |> Map.put("session_id", replacement["session_id"])

      assert disposition(
               Monitoring.ingest(
                 envelope([recovery], %{"session_id" => replacement["session_id"]}),
                 time(5)
               )
             ) == "current"

      stream =
        Repo.one!(
          from s in ResultStream, where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
        )

      assert stream.current["session_id"] == replacement["session_id"]
      assert stream.current["confirmed_observation_id"] == recovery["id"]
      assert stream.current["health"] == "OK"
    after
      send(writer.pid, :commit)
      Task.shutdown(transition, :brutal_kill)
      Task.shutdown(writer, :brutal_kill)
    end
  end

  test "a twelve-runner sweep acquires one loss lock and reads runner metadata once" do
    for _ <- 1..11 do
      Repo.insert!(%Runner{
        id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        boot: 1,
        last_seen_at: at(),
        label: "Idle observer"
      })
    end

    handler = {__MODULE__, :sweep_queries, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:mondek, :repo, :query],
        &__MODULE__.capture_sweep_query/4,
        %{owner: self(), tag: handler}
      )

    try do
      assert {:ok, _} = MonitoringLoss.reconcile(time(7))
    after
      :telemetry.detach(handler)
    end

    queries = collected_queries(handler, [])
    assert Enum.count(queries, &String.contains?(&1, ~s(FROM "runners" AS))) == 1
    assert Enum.count(queries, &(&1 == "SELECT pg_advisory_xact_lock(774015)")) == 1
    assert Repo.one!(MonitoringIncident).member_count == 1
    assert Repo.aggregate(Occurrence, :count) == 1
  end

  test "a session transition cannot commit after a sweep captures runner metadata" do
    parent = self()
    replacement = control(%{"boot" => 2, "session_id" => Ecto.UUID.generate()})

    sweep =
      Task.async(fn ->
        Repo.checkout(fn ->
          handler = {__MODULE__, :loaded_runner, self()}
          config = %{owner: self(), parent: parent, backend: backend_pid()}

          :ok =
            :telemetry.attach(
              handler,
              [:mondek, :repo, :query],
              &__MODULE__.pause_after_runner_snapshot/4,
              config
            )

          try do
            MonitoringLoss.reconcile(time(7))
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    assert_receive {:runner_snapshot_loaded, sweep_backend}, 1000

    transition =
      Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {:replacement_backend, backend_pid()})
          Monitoring.control(replacement, time(8))
        end)
      end)

    try do
      assert_receive {:replacement_backend, replacement_backend}, 1000

      await_advisory_wait(
        replacement_backend,
        sweep_backend,
        System.monotonic_time(:millisecond) + 2000
      )

      refute Task.yield(transition, 0)

      assert Repo.get!(Runner, replacement["installation_id"]).session_id ==
               control()["session_id"]

      send(sweep.pid, :continue_sweep)
      assert {:ok, _} = Task.await(sweep, 5000)
      assert {:ok, _} = Task.await(transition, 5000)

      episode = Repo.one!(MonitoringIncident)
      assert episode.status == "open"
      assert episode.member_count == 1
      assert Repo.aggregate(Occurrence, :count) == 1

      assert Repo.get!(Runner, replacement["installation_id"]).session_id ==
               replacement["session_id"]

      assert {:error, :session_conflict} = ingest(sample("OK", 4, 9), time(9))
      recovery = sample("OK", 4, 9) |> Map.put("session_id", replacement["session_id"])

      assert disposition(
               Monitoring.ingest(
                 envelope([recovery], %{"session_id" => replacement["session_id"]}),
                 time(9)
               )
             ) == "current"

      assert Repo.get!(MonitoringIncident, episode.id).closure_reason == "monitoring_restored"
      assert Repo.get!(Observation, recovery["id"]).payload == recovery
    after
      send(sweep.pid, :continue_sweep)
      Task.shutdown(transition, :brutal_kill)
      Task.shutdown(sweep, :brutal_kill)
    end
  end

  @doc false
  def capture_sweep_query(_event, _measurements, metadata, %{owner: owner, tag: tag}) do
    if self() == owner, do: send(owner, {tag, metadata.query})
  end

  @doc false
  def pause_after_runner_snapshot(_event, _measurements, metadata, config) do
    if self() == config.owner and String.contains?(metadata.query, ~s(FROM "runners" AS)) and
         not String.contains?(metadata.query, "WHERE") do
      send(config.parent, {:runner_snapshot_loaded, config.backend})

      receive do
        :continue_sweep -> :ok
      after
        5000 -> raise "Runner snapshot barrier was not released"
      end
    end
  end

  defp collected_queries(tag, acc) do
    receive do
      {^tag, query} -> collected_queries(tag, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp mutate(:control, _next), do: Monitoring.control(control(), time(8))
  defp mutate(:ingest, next), do: ingest(next, time(8))

  defp assert_mutation(:control, response),
    do: assert(response["authorized"] == %{"10000000-0000-4000-8000-000000000001" => 1})

  defp assert_mutation(:ingest, response), do: assert(disposition({:ok, response}) == "current")

  defp last_contact(:control), do: time(8)
  defp last_contact(:ingest), do: at()

  defp latest(:ingest, next, _unavailable), do: next
  defp latest(:control, _next, unavailable), do: unavailable

  defp sample(health, sequence, seconds) do
    measurement(health, sequence, %{
      "started_at" => Monitoring.iso(time(seconds)),
      "evaluated_at" => Monitoring.iso(time(seconds)),
      "results" => [
        %{
          "key" => "capacity",
          "health" => health,
          "summary" => "Measured #{health}",
          "source_at" => Monitoring.iso(time(seconds))
        }
      ]
    })
  end

  defp time(seconds), do: DateTime.add(at(), seconds)

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp capture_failure(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  defp await_advisory_wait(waiter, blocker, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT $1=ANY(pg_blocking_pids($2)) AND EXISTS (
          SELECT 1 FROM pg_locks WHERE pid=$2 AND locktype='advisory'
            AND classid=0 AND objid=774015 AND objsubid=1 AND NOT granted)
        """,
        [blocker, waiter]
      )

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "The actual runner mutation must reach the monitoring-loss advisory lock"

      Process.sleep(5)
      await_advisory_wait(waiter, blocker, deadline)
    end
  end

  defp await_row_wait(waiter, blocker, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT $1=ANY(pg_blocking_pids($2)) AND EXISTS (
          SELECT 1 FROM pg_locks WHERE pid=$2 AND locktype='transactionid' AND NOT granted)
        """,
        [blocker, waiter]
      )

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "The competing session must wait for the ingestion writer's runner row"

      Process.sleep(5)
      await_row_wait(waiter, blocker, deadline)
    end
  end
end
