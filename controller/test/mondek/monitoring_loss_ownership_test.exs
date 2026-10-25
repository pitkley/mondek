# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringLossOwnershipTest do
  use Mondek.DataCase, async: false
  @moduletag empty_source_fixture: true

  alias Mondek.{MonitoringIncident, MonitoringLoss}
  alias Mondek.CoverageFixtures, as: F

  setup do
    grace = Application.get_env(:mondek, :monitoring_loss_grace_seconds)
    contact = Application.get_env(:mondek, :monitoring_contact_seconds)
    Application.put_env(:mondek, :monitoring_loss_grace_seconds, 5)
    Application.put_env(:mondek, :monitoring_contact_seconds, 1000)

    on_exit(fn ->
      Application.put_env(:mondek, :monitoring_loss_grace_seconds, grace)
      Application.put_env(:mondek, :monitoring_contact_seconds, contact)
    end)

    :ok
  end

  test "an unrelated runner episode cannot take over an already open coverage gap" do
    backup =
      F.publication([F.candidate(F.check("backup", "production", "backup"))], %{
        "source_id" => "backup-project"
      })

    assert {:ok, _} = Monitoring.inventory(backup, at())
    assert {:ok, _} = F.activate(backup, at())
    assert disposition(F.sample(backup, "UNKNOWN", 1, time(1))) == "current"

    missing = F.publication([F.candidate(F.check(), false)])
    assert {:ok, _} = Monitoring.inventory(missing, time(2))
    tick(2)
    tick(6)
    runner_incident = Repo.one!(from i in MonitoringIncident, where: i.scope_kind == "runner")
    tick(7)
    coverage_incident = Repo.one!(from i in MonitoringIncident, where: i.scope_kind == "coverage")

    selected =
      F.publication(
        [F.candidate(F.check())],
        Map.take(backup, ~w(installation_id session_id boot))
      )

    assert {:ok, _} = Monitoring.inventory(selected, time(8))
    assert {:ok, _} = F.activate(selected, time(8))
    assert disposition(F.sample(selected, "UNKNOWN", 1, time(8))) == "current"
    tick(16)

    assert Repo.get!(MonitoringIncident, coverage_incident.id).status == "open"
    assert Repo.get!(MonitoringIncident, runner_incident.id).status == "open"
    assert Repo.get!(MonitoringIncident, runner_incident.id).member_count == 1
    assert Repo.aggregate(MonitoringIncident, :count) == 2
    assert Repo.aggregate(Occurrence, :count) == 2
    assert MonitoringLoss.detail(coverage_incident.id, time(16))["members"]["total"] == 1

    assert disposition(F.sample(selected, "OK", 2, time(17))) == "current"

    assert Repo.get!(MonitoringIncident, coverage_incident.id).closure_reason ==
             "monitoring_restored"

    assert Repo.get!(MonitoringIncident, runner_incident.id).status == "open"
    assert disposition(F.sample(backup, "OK", 2, time(18))) == "current"

    assert Repo.get!(MonitoringIncident, runner_incident.id).closure_reason ==
             "monitoring_restored"
  end

  defp time(seconds), do: DateTime.add(at(), seconds)
  defp tick(seconds), do: assert({:ok, _} = MonitoringLoss.reconcile(time(seconds)))
end
