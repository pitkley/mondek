# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.OverviewAttentionTest do
  use Mondek.DataCase, async: false

  alias Mondek.{ConditionIncident, MonitoringIncident, MonitoringLoss}
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

    for key <- [
          "10000000-0000-4000-8000-000000000001",
          "10000000-0000-4000-8000-000000000002",
          "10000000-0000-4000-8000-000000000003"
        ] do
      assert {:ok, _} = withdraw_source_fixture(key, "Use installed checks", at())
    end

    :ok
  end

  test "Overview excludes acknowledged health before paging while Checks inventory and exact expiry stay honest" do
    observer = install(["a-held", "b-warning", "c-critical"])
    sample(observer, "a-held", "CRIT", 1, 1)
    sample(observer, "b-warning", "WARN", 1, 1)
    sample(observer, "c-critical", "CRIT", 1, 1)
    held = health_incident(observer, "a-held")
    assert {:ok, _} = reviewed_acknowledgement_fixture(held.id, 2, "Investigating", time(2))

    first = attention(time(3), %{"page_size" => 1})
    second = attention(time(3), %{"page_size" => 1, "page" => 2})
    assert first.total == 2 and second.total == 2
    assert first.filter_counts["attention"] == 2
    assert keys(first) == ["c-critical"]
    assert keys(second) == ["b-warning"]
    assert Monitoring.list_streams(%{"attention" => true}, time(3)).total == 3
    assert Monitoring.list_streams(%{"unacknowledged" => true}, time(3)).total == 3

    assert attention(DateTime.add(time(4), -1, :microsecond)).total == 2
    assert attention(time(4)).total == 3
    acknowledge(Repo.get!(Incident, held.id), time(4))
    assert attention(time(5)).total == 2
    assert {:ok, _} = reviewed_acknowledgement_fixture(held.id, 0, "Resume attention", time(5))
    assert attention(time(5)).total == 3
    acknowledge(Repo.get!(Incident, held.id), time(5))
    sample(observer, "a-held", "OK", 2, 6)
    assert attention(time(6)).total == 2
    sample(observer, "a-held", "CRIT", 3, 7)
    assert attention(time(7)).total == 3
    refute health_incident(observer, "a-held").id == held.id
  end

  test "health and collection acknowledgements independently cover their own problem on the same retained Critical result" do
    observer = install(["disk"])
    sample(observer, "disk", "CRIT", 1, 1)
    health = health_incident(observer, "disk")
    acknowledge(health, time(1))
    assert attention(time(1)).total == 0

    sample(observer, "disk", "UNKNOWN", 2, 2)
    assert attention(time(2)).total == 1
    refute Repo.exists?(MonitoringIncident)
    tick(7)
    loss = Repo.one!(MonitoringIncident)
    acknowledge_loss(loss, time(7))
    assert attention(time(7)).total == 0

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               health.id,
               0,
               "Reconsider measured failure",
               time(8)
             )

    assert attention(time(8)).total == 1
    acknowledge(Repo.get!(Incident, health.id), time(8))
    assert attention(time(8)).total == 0

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               loss.id,
               0,
               "Reconsider collection",
               time(8)
             )

    assert attention(time(8)).total == 1

    sample(observer, "disk", "CRIT", 3, 9)
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "monitoring_restored"
    assert attention(time(9)).total == 0
    # The acknowledged retained failure cannot hide a new collection gap before
    # the sweeper has had a chance to open another monitoring-loss episode.
    assert attention(time(21)).total == 1
    assert hd(attention(time(21)).items)["current"]["health"] == "CRIT"
    assert hd(attention(time(21)).items)["current"]["knowledge"] == "stale"
  end

  test "shared acknowledgements cover equivalent late contributors but individual holds and severity escalation remain independent" do
    condition = %{"namespace" => "storage", "key" => "pressure", "label" => "Storage pressure"}
    linux = install([condition_check("linux", condition)])
    elastic = install([condition_check("elastic", condition)])
    sample(linux, "linux", "WARN", 1, 1)
    group = Repo.one!(ConditionIncident)
    acknowledge(group, time(2))
    assert keys(attention(time(2))) == ["elastic"]
    sample(elastic, "elastic", "WARN", 1, 3)
    assert attention(time(3)).total == 0

    sample(elastic, "elastic", "CRIT", 2, 4)
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id), time(4))
    assert attention(time(4)).total == 2
    linux_incident = health_incident(linux, "linux")
    acknowledge(linux_incident, time(5))
    assert keys(attention(time(5))) == ["elastic"]
    acknowledge(Repo.get!(ConditionIncident, group.id), time(5))
    assert attention(time(5)).total == 0

    assert {:ok, _} =
             Mondek.Conditions.acknowledge(
               group.id,
               %{
                 "mode" => "end",
                 "revision" => Repo.get!(ConditionIncident, group.id).acknowledgement_revision,
                 "attention_revision" => Repo.get!(ConditionIncident, group.id).attention_revision
               },
               "Resume shared attention",
               time(6)
             )

    assert keys(attention(time(6))) == ["elastic"]
  end

  test "a runner acknowledgement covers actual late episode members after grace and expires exactly" do
    observer = install(["alpha", "beta"])
    sample(observer, "alpha", "UNKNOWN", 1, 1)
    sample(observer, "beta", "OK", 1, 1)
    tick(6)
    loss = Repo.one!(MonitoringIncident)

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               loss.id,
               7,
               "Known collection outage",
               time(6)
             )

    assert attention(time(6)).total == 0
    sample(observer, "beta", "UNKNOWN", 2, 7)
    assert keys(attention(time(7))) == ["beta"]
    assert keys(attention(time(11))) == ["beta"]
    tick(12)
    assert Repo.get!(MonitoringIncident, loss.id).member_count == 2
    assert attention(time(12)).total == 0
    assert attention(DateTime.add(time(13), -1, :microsecond)).total == 0
    assert attention(time(13)).total == 2
    acknowledge_loss(Repo.get!(MonitoringIncident, loss.id), time(13))
    assert attention(time(13)).total == 0
    sample(observer, "alpha", "OK", 2, 14)
    sample(observer, "beta", "OK", 3, 14)
    assert Repo.get!(MonitoringIncident, loss.id).status == "closed"
    assert attention(time(14)).total == 0
  end

  test "coverage ownership prevents an unrelated acknowledged runner episode from hiding a result's collection gap" do
    backup = install(["backup"], %{"source_id" => "backup-project"})
    sample(backup, "backup", "UNKNOWN", 1, 1)
    missing = F.publication([F.candidate(F.check("service"), false)])
    assert {:ok, _} = Monitoring.inventory(missing, time(2))
    tick(2)
    tick(6)
    runner_loss = Repo.one!(from i in MonitoringIncident, where: i.scope_kind == "runner")
    acknowledge_loss(runner_loss, time(6))
    tick(7)
    coverage_loss = Repo.one!(from i in MonitoringIncident, where: i.scope_kind == "coverage")

    selected =
      install(["service"], Map.take(backup, ~w(installation_id session_id boot)), time(8))

    sample(selected, "service", "UNKNOWN", 1, 8)
    tick(16)
    assert keys(attention(time(16))) == ["service"]
    assert Repo.get!(MonitoringIncident, runner_loss.id).member_count == 1
    acknowledge_loss(coverage_loss, time(16))
    assert attention(time(16)).total == 0

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               runner_loss.id,
               0,
               "Resume backup investigation",
               time(17)
             )

    assert keys(attention(time(17))) == ["backup"]

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               coverage_loss.id,
               0,
               "Resume service investigation",
               time(18)
             )

    assert Enum.sort(keys(attention(time(18)))) == ["backup", "service"]
  end

  defp install(checks, overrides \\ %{}, instant \\ at()) do
    checks =
      Enum.map(checks, fn
        key when is_binary(key) -> F.check(key, "production", key)
        check -> check
      end)

    candidates =
      Enum.map(checks, fn check ->
        check
        |> F.candidate()
        |> Map.update!(
          "outputs",
          &Enum.map(&1, fn output -> Map.take(output, ~w(key label target)) end)
        )
      end)

    publication = F.publication(candidates, overrides) |> Map.put("checks", checks)
    assert {:ok, _} = Monitoring.inventory(publication, instant)
    assert {:ok, _} = F.activate(publication, instant)
    publication
  end

  defp condition_check(key, condition) do
    F.check(key, "production", key)
    |> Map.update!("outputs", fn outputs ->
      Enum.map(outputs, &Map.put(&1, "condition", condition))
    end)
  end

  defp sample(observer, key, health, sequence, seconds) do
    assignment = Enum.find(F.assignments(observer), &(&1.source_key == key))

    report =
      measurement(health, sequence, %{
        "assignment_id" => assignment.id,
        "installation_id" => observer["installation_id"],
        "session_id" => observer["session_id"],
        "started_at" => Monitoring.iso(time(seconds)),
        "evaluated_at" => Monitoring.iso(time(seconds)),
        "results" => [
          %{
            "key" => "health",
            "health" => health,
            "summary" => "Measured #{health}",
            "source_at" => Monitoring.iso(time(seconds))
          }
        ]
      })

    assert disposition(
             Monitoring.ingest(
               envelope([report], Map.take(observer, ~w(installation_id session_id))),
               time(seconds)
             )
           ) == "current"
  end

  defp health_incident(observer, key) do
    assignment = Enum.find(F.assignments(observer), &(&1.source_key == key))
    Repo.one!(from i in Incident, where: i.assignment_id == ^assignment.id and i.status == "open")
  end

  defp acknowledge(incident, instant) do
    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               acknowledgement(incident),
               "Investigating",
               instant
             )
  end

  defp acknowledge_loss(incident, instant) do
    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               incident.id,
               acknowledgement(incident),
               "Investigating collection",
               instant
             )
  end

  defp acknowledgement(incident),
    do: %{
      "mode" => "until_incident_ends",
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

  defp attention(instant, filters \\ %{}),
    do:
      Monitoring.list_streams(
        Map.merge(%{"attention" => true, "unacknowledged" => true}, filters),
        instant
      )

  defp keys(page), do: Enum.map(page.items, & &1["source_key"])
  defp time(seconds), do: DateTime.add(at(), seconds)
  defp tick(seconds), do: assert({:ok, _} = MonitoringLoss.reconcile(time(seconds)))
end
