# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RunnerContactTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    ConfigurationRepository,
    CoverageFixtures,
    MonitoringLoss,
    MonitoringIncident,
    Runner
  }

  @tag empty_source_fixture: true
  test "inventory delayed behind the journal cannot rewind newer control contact" do
    contact = Application.get_env(:mondek, :monitoring_contact_seconds)
    grace = Application.get_env(:mondek, :monitoring_loss_grace_seconds)
    Application.put_env(:mondek, :monitoring_contact_seconds, 3)
    Application.put_env(:mondek, :monitoring_loss_grace_seconds, 1)

    on_exit(fn ->
      Application.put_env(:mondek, :monitoring_contact_seconds, contact)
      Application.put_env(:mondek, :monitoring_loss_grace_seconds, grace)
    end)

    publication =
      CoverageFixtures.publication([CoverageFixtures.candidate(CoverageFixtures.check())])

    assert {:ok, _} = Monitoring.inventory(publication, at())
    assert {:ok, _} = CoverageFixtures.activate(publication, at())
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          ConfigurationRepository.lock!()
          send(parent, :journal_locked)

          receive do
            :release -> :ok
          after
            5000 -> raise "journal test lock was not released"
          end
        end)
      end)

    assert_receive :journal_locked

    pending =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:inventory_pid, pid})

          Monitoring.inventory(
            Map.put(publication, "inventory_revision", 2),
            DateTime.add(at(), 5)
          )
        end)
      end)

    try do
      assert_receive {:inventory_pid, pid}
      await_blocked(pid, System.monotonic_time(:millisecond) + 2000)
      assert {:ok, _} = CoverageFixtures.activate(publication, DateTime.add(at(), 12))

      assert disposition(CoverageFixtures.sample(publication, "OK", 1, DateTime.add(at(), 12))) ==
               "current"

      assert Repo.get!(Runner, publication["installation_id"]).last_seen_at ==
               DateTime.add(at(), 12)
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder)
    assert {:ok, _} = Task.await(pending)

    assert Repo.get!(Runner, publication["installation_id"]).last_seen_at ==
             DateTime.add(at(), 12)

    assert {:ok, _} = MonitoringLoss.reconcile(DateTime.add(at(), 14))
    refute Repo.exists?(MonitoringIncident)
    assert {:ok, _} = MonitoringLoss.reconcile(DateTime.add(at(), 20))

    loss =
      Repo.one!(
        from m in MonitoringIncident, where: m.runner_id == ^publication["installation_id"]
      )

    assert loss.status == "open"
    assert hd(loss.member_snapshot)["knowledge"] == "control_contact_overdue"
  end

  defp await_blocked(pid, deadline) do
    %{rows: [[waiting]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [pid])

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_blocked(pid, deadline)
    end
  end
end
