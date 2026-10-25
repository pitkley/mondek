# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Explicit, destructive test-database profile; outside normal test discovery.
# PGPORT=55433 MIX_ENV=test mix test profiles/retention.exs --trace

unless Mix.env() == :test and Mondek.Repo.config()[:database] == "mondek_test" and
         Mondek.Repo.config()[:hostname] == "127.0.0.1" and
         Mondek.Repo.config()[:port] == 55433 do
  raise "Retention profile requires the isolated mondek-tests database on 127.0.0.1:55433"
end

defmodule Mondek.RetentionProfile do
  use Mondek.DataCase, async: false

  @tag timeout: 180_000
  test "measure expired history cleanup alongside real ingestion" do
    assert Repo.config()[:database] == "mondek_test"
    count = System.get_env("MONDEK_RETENTION_PROFILE_ROWS", "10000") |> String.to_integer()
    assert count in [10_000, 100_000]
    assert {:ok, _} = connect()
    opening = measurement("CRIT", 1)
    assert disposition(ingest(opening)) == "current"
    retained = measurement("CRIT", 2)
    assert disposition(ingest(retained)) == "current"
    future = DateTime.add(at(), 40 * 86_400)

    Repo.query!(
      """
      INSERT INTO observations (id,assignment_id,installation_id,session_id,generation,sequence,
        started_at,evaluated_at,received_at,payload,disposition)
      SELECT gen_random_uuid(),assignment_id,installation_id,session_id,generation,100+n,
        started_at,evaluated_at,received_at,payload,'historical'
      FROM observations CROSS JOIN generate_series(1,$1::integer) n WHERE id=$2::uuid
      """,
      [count, Ecto.UUID.dump!(opening["id"])]
    )

    # Terminal parent rows deliberately have no unfinished delivery. The two real
    # observations remain protected by the unresolved incident/current stream.
    terminal_count = div(count, 100)

    Repo.query!(
      """
      INSERT INTO incidents (id,assignment_id,health,status,opened_at,closed_at,opening_generation,attention_revision)
      SELECT gen_random_uuid(),'filesystem','CRIT','closed',$1,$1,1,1
      FROM generate_series(1,$2::integer)
      """,
      [at(), terminal_count]
    )

    # DataCase truncates referenced evidence tables too. Refresh their statistics
    # so previous test workloads cannot distort the protected-history join plan.
    Repo.query!("ANALYZE")
    report = measurement("CRIT", 3)
    {idle_us, idle} = :timer.tc(fn -> ingest(report) end)
    assert disposition(idle) == "current"
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:mondek, :repo, :query], &__MODULE__.signal_lock/4, parent)

    try do
      next = measurement("CRIT", 4)
      {sweep_us, ingest_us, samples} = measure_pass(future, next)
      assert Repo.get!(Observation, opening["id"]).payload == opening
      assert Repo.get!(Observation, report["id"]).payload == report
      assert Repo.get!(Observation, next["id"]).payload == next
      remaining = Repo.aggregate(Observation, :count)

      terminal_remaining =
        Repo.aggregate(from(i in Incident, where: i.status == "closed"), :count)

      IO.puts(
        "RETENTION_PROFILE " <>
          Jason.encode!(%{
            receipts: count,
            terminal_incidents: terminal_count,
            sweep_ms: sweep_us / 1000,
            idle_ingest_ms: idle_us / 1000,
            concurrent_ingest_ms: ingest_us / 1000,
            lock_wait_samples: Enum.count(samples, & &1),
            samples: length(samples),
            remaining_receipts: remaining,
            remaining_terminal_incidents: terminal_remaining,
            protected_evidence_verified: true
          })
      )

      {drain_us, passes} =
        :timer.tc(fn ->
          if System.get_env("MONDEK_RETENTION_PROFILE_FIRST_ONLY") == "1",
            do: [{sweep_us, ingest_us}],
            else: drain(future, opening, 5, [{sweep_us, ingest_us}])
        end)

      IO.puts(
        "RETENTION_DRAIN " <>
          Jason.encode!(%{
            receipts: count,
            drain_requested: System.get_env("MONDEK_RETENTION_PROFILE_FIRST_ONLY") != "1",
            passes: length(passes),
            remaining_receipts: Repo.aggregate(Observation, :count),
            remaining_terminal_incidents:
              Repo.aggregate(from(i in Incident, where: i.status == "closed"), :count),
            total_sweep_ms: Enum.sum(Enum.map(passes, &elem(&1, 0))) / 1000,
            additional_drain_wall_ms: drain_us / 1000,
            max_pass_ms: Enum.max(Enum.map(passes, &elem(&1, 0))) / 1000,
            max_concurrent_ingest_ms: Enum.max(Enum.map(passes, &elem(&1, 1))) / 1000,
            protected_evidence_verified: true
          })
      )
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(future, opening, sequence, passes) do
    assert sequence < 205, "Cleanup must make durable progress through this bounded workload"

    if Repo.aggregate(Observation, :count) <= 3 and
         Repo.aggregate(from(i in Incident, where: i.status == "closed"), :count) == 0 do
      assert Repo.get!(Observation, opening["id"]).payload == opening
      passes
    else
      next = measurement("CRIT", sequence)
      {sweep_us, ingest_us, _samples} = measure_pass(future, next)
      assert Repo.get!(Observation, opening["id"]).payload == opening
      assert Repo.get!(Observation, next["id"]).payload == next
      drain(future, opening, sequence + 1, [{sweep_us, ingest_us} | passes])
    end
  end

  defp measure_pass(future, next) do
    parent = self()

    sweep =
      Task.async(fn ->
        Process.put(:retention_profile_sweep, true)
        result = :timer.tc(fn -> Mondek.Sweeper.sweep(future) end)
        send(parent, {:sweep_query_times, Process.get(:retention_profile_queries, %{})})
        result
      end)

    assert_receive :sweep_locked, 5000

    writer =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:writer_pid, pid})
          :timer.tc(fn -> ingest(next) end)
        end)
      end)

    assert_receive {:writer_pid, pid}, 5000
    samples = sample_waits(pid, sweep, writer, [])
    {sweep_us, {:ok, _}} = Task.await(sweep, 120_000)
    {ingest_us, result} = Task.await(writer, 120_000)
    assert disposition(result) == "current"
    assert_receive {:sweep_query_times, queries}

    unless Process.get(:retention_profile_first_query_times) do
      Process.put(:retention_profile_first_query_times, true)
      top = queries |> Enum.sort_by(fn {_query, value} -> -value.us end) |> Enum.take(5)

      IO.puts(
        "RETENTION_QUERY_TIMES " <>
          Jason.encode!(
            Enum.map(top, fn {query, value} ->
              %{query: query, query_ms: value.us / 1000}
            end)
          )
      )

      if System.get_env("MONDEK_RETENTION_PROFILE_PLAN") == "1" do
        {query, value} =
          Enum.find(top, fn {query, _} ->
            String.starts_with?(
              query,
              "DELETE FROM observations WHERE id IN (SELECT observations.id FROM observations WHERE received_at"
            )
          end)

        {:error, rows} =
          Repo.transaction(fn ->
            plan = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, value.params)
            Repo.rollback(plan.rows)
          end)

        IO.puts("RETENTION_QUERY_PLAN " <> Jason.encode!(rows))
      end
    end

    {sweep_us, ingest_us, samples}
  end

  def signal_lock(_event, measurements, metadata, parent) do
    if Process.get(:retention_profile_sweep, false) do
      queries = Process.get(:retention_profile_queries, %{})
      us = System.convert_time_unit(measurements.query_time, :native, :microsecond)

      queries =
        Map.update(queries, metadata.query, %{us: us, params: metadata.params}, fn old ->
          %{old | us: old.us + us}
        end)

      Process.put(:retention_profile_queries, queries)
      if metadata.query == "SELECT pg_advisory_xact_lock(774015)", do: send(parent, :sweep_locked)
    end
  end

  defp sample_waits(pid, sweep, writer, samples) do
    if Process.alive?(sweep.pid) and Process.alive?(writer.pid) do
      %{rows: [[waiting]]} =
        Repo.query!("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)", [pid])

      Process.sleep(2)
      sample_waits(pid, sweep, writer, [waiting | samples])
    else
      samples
    end
  end
end
