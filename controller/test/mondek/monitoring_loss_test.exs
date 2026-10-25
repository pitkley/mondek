# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringLossTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    MonitoringLoss,
    MonitoringGap,
    MonitoringIncident,
    ResultStream,
    NotificationWorker
  }

  alias Mondek.CoverageFixtures, as: F

  setup do
    previous = Application.get_env(:mondek, :monitoring_loss_grace_seconds)
    contact = Application.get_env(:mondek, :monitoring_contact_seconds)
    Application.put_env(:mondek, :monitoring_loss_grace_seconds, 5)
    Application.put_env(:mondek, :monitoring_contact_seconds, 1000)

    on_exit(fn ->
      Application.put_env(:mondek, :monitoring_loss_grace_seconds, previous)
      Application.put_env(:mondek, :monitoring_contact_seconds, contact)
    end)

    :ok
  end

  defp single do
    connect()

    for id <- ["10000000-0000-4000-8000-000000000002", "10000000-0000-4000-8000-000000000003"],
        do: withdraw_source_fixture(id, "Keep one test result", at())

    sample("OK", 1, 1)
  end

  defp sample(health, sequence, seconds, source_seconds \\ nil) do
    report = sample_report(health, sequence, seconds, source_seconds)
    assert disposition(ingest(report, time(seconds))) == "current"
    report
  end

  defp sample_report(health, sequence, seconds, source_seconds \\ nil) do
    measurement(health, sequence, %{
      "started_at" => Monitoring.iso(time(seconds)),
      "evaluated_at" => Monitoring.iso(time(seconds)),
      "results" => [
        %{
          "key" => "capacity",
          "health" => health,
          "summary" => "Measurement #{health}",
          "source_at" => Monitoring.iso(time(source_seconds || seconds))
        }
      ]
    })
  end

  defp time(seconds), do: DateTime.add(at(), seconds)
  defp tick(seconds), do: assert({:ok, _} = MonitoringLoss.reconcile(time(seconds)))
  defp episode, do: Repo.one!(from i in MonitoringIncident, where: i.status == "open")

  test "Unknown is debounced without manufacturing target failure or refreshing retained evidence" do
    single()
    sample("UNKNOWN", 2, 2)
    gap = Repo.one!(MonitoringGap)
    sample("UNKNOWN", 3, 5)
    assert Repo.one!(MonitoringGap).since_at == gap.since_at
    tick(6)
    refute Repo.exists?(MonitoringIncident)
    tick(7)
    incident = episode()
    assert incident.member_count == 1
    assert incident.member_snapshot |> hd() |> Map.fetch!("knowledge") == "unavailable"

    assert Repo.one!(
             from s in ResultStream,
               where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
           ).current[
             "health"
           ] == "OK"

    refute Repo.exists?(Incident)
    assert Repo.aggregate(Occurrence, :count) == 1
    tick(20)
    assert episode().id == incident.id
    assert Repo.aggregate(Occurrence, :count) == 1
  end

  test "short interruption clears before grace and starts the next candidate afresh" do
    single()
    sample("UNKNOWN", 2, 2)
    sample("OK", 3, 4)
    refute Repo.exists?(MonitoringGap)
    sample("UNKNOWN", 4, 5)
    tick(7)
    refute Repo.exists?(MonitoringIncident)
    tick(10)
    assert episode().opened_at == time(10)
  end

  test "ordered upload preserves recovery then failure and retry is inert" do
    single()
    failed = sample("UNKNOWN", 2, 2)
    tick(7)
    old = episode()
    assert disposition(ingest(failed, time(8))) == "duplicate"
    assert episode().id == old.id
    recovery = sample_report("OK", 3, 9)
    next = sample_report("UNKNOWN", 4, 10)
    assert {:ok, _} = Monitoring.ingest(envelope([recovery, next]), time(10))
    assert Repo.get!(MonitoringIncident, old.id).closure_reason == "monitoring_restored"
    assert Repo.one!(MonitoringGap).since_at == time(10)
    refute Repo.exists?(from i in MonitoringIncident, where: i.status == "open")
    tick(15)
    refute episode().id == old.id
  end

  test "fresh Critical restores monitoring while the measured health incident stays Critical" do
    single()
    sample("CRIT", 2, 2)
    health_incident = Repo.one!(Incident)
    sample("UNKNOWN", 3, 3)
    tick(8)
    loss = episode()
    sample("CRIT", 4, 9)
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "monitoring_restored"
    assert Repo.get!(Incident, health_incident.id).status == "open"
    assert Repo.get!(Incident, health_incident.id).health == "CRIT"
  end

  test "contact recovery, stale buffered samples and cached fresh data cannot close an outage" do
    Application.put_env(:mondek, :monitoring_contact_seconds, 3)
    single()
    tick(4)
    tick(8)
    loss = episode()
    assert {:ok, _} = Monitoring.control(control(), time(9))
    tick(9)
    assert episode().id == loss.id
    sample("OK", 2, 10, 1)
    assert episode().id == loss.id
    sample("OK", 3, 11)
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "monitoring_restored"
  end

  test "stale measurements have a durable grace and unknown reason changes do not restart it" do
    single()
    tick(13)
    gap = Repo.one!(MonitoringGap)
    assert gap.details["knowledge"] == "stale"
    sample("UNKNOWN", 2, 14)
    assert Repo.one!(MonitoringGap).since_at == gap.since_at
    tick(18)
    assert episode().member_count == 1
  end

  test "retirement ends monitoring administratively and does not claim restoration" do
    single()
    sample("UNKNOWN", 2, 2)
    tick(7)
    loss = episode()
    firing = Repo.one!(Occurrence)
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(firing.id, time(7))

    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "No longer monitored",
               time(8)
             )

    tick(8)
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "scope_withdrawn"
    resolved = Repo.one!(from o in Occurrence, where: o.kind == "resolved")
    assert resolved.payload["closure_reason"] == "scope_withdrawn"
    refute Repo.exists?(MonitoringGap)
  end

  test "runner acknowledgement covers late members and expiry/end uses the same delivery" do
    connect()
    sample("UNKNOWN", 1, 1)
    tick(6)
    loss = episode()
    firing = Repo.one!(Occurrence)

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               loss.id,
               %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
               "Investigating this runner",
               time(6)
             )

    tick(14)
    assert episode().member_count == 3

    assert {:gated, ["acknowledgement"], nil} =
             MonitoringLoss.delivery_eligibility(firing, episode(), time(14))

    assert Repo.aggregate(Occurrence, :count) == 1

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(loss.id, 0, "Resume alerts", time(15))

    assert :eligible = MonitoringLoss.delivery_eligibility(firing, episode(), time(15))

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(loss.id, 1, "Short hold", time(16))

    assert {:gated, _, until} = MonitoringLoss.delivery_eligibility(firing, episode(), time(16))
    assert until == time(17)
    assert :eligible = MonitoringLoss.delivery_eligibility(firing, episode(), time(17))
  end

  test "concurrent ticks create exactly one episode and durable notification" do
    single()
    sample("UNKNOWN", 2, 2)
    tasks = for _ <- 1..6, do: Task.async(fn -> MonitoringLoss.reconcile(time(7)) end)
    for task <- tasks, do: assert({:ok, _} = Task.await(task))
    assert Repo.aggregate(MonitoringIncident, :count) == 1
    assert Repo.aggregate(Occurrence, :count) == 1
  end

  @tag empty_source_fixture: true
  test "known missing scopes survive republishing and clear only after fresh selected evidence" do
    candidate = F.candidate(F.check(), false)
    publication = F.publication([candidate])
    assert {:ok, _} = Monitoring.inventory(publication, at())
    tick(0)
    first_gap = Repo.one!(MonitoringGap)
    assert {:ok, _} = Monitoring.inventory(Map.put(publication, "inventory_revision", 2), time(2))
    tick(2)
    assert Repo.one!(MonitoringGap).since_at == first_gap.since_at
    tick(5)
    loss = episode()
    assert loss.scope_kind == "coverage"
    selected = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(selected, time(6))
    assert {:ok, _} = F.activate(selected, time(6))
    assert disposition(F.sample(selected, "UNKNOWN", 1, time(6))) == "current"
    tick(15)
    assert Repo.aggregate(from(i in MonitoringIncident, where: i.status == "open"), :count) == 1
    assert episode().id == loss.id
    assert disposition(F.sample(selected, "OK", 2, time(16))) == "current"
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "monitoring_restored"
  end

  test "unbound declarations never invent missing targets and authoritative withdrawal is closure" do
    candidate = F.candidate(F.check(), false)

    unbound =
      candidate
      |> Map.merge(%{
        "key" => "template",
        "scope_resolved" => false,
        "scope_reason" => "Needs a target"
      })
      |> put_in(["outputs", Access.at(0), "target"], nil)

    p = F.publication([candidate, unbound])
    assert {:ok, _} = Monitoring.inventory(p, at())
    tick(0)
    tick(5)
    assert episode().member_count == 1
    loss = episode()

    removed =
      p |> Map.put("inventory_revision", 2) |> put_in(["coverage", "candidates"], [unbound])

    assert {:ok, _} = Monitoring.inventory(removed, time(6))
    tick(6)
    assert Repo.get!(MonitoringIncident, loss.id).closure_reason == "scope_withdrawn"
  end

  @tag empty_source_fixture: true
  test "hundreds of missing results produce one group with bounded, complete pagination" do
    candidates = for n <- 1..300, do: F.candidate(F.check("check-#{n}"))
    p = F.publication(candidates)
    assert {:ok, _} = Monitoring.inventory(p, at())
    tick(0)
    tick(8)
    loss = episode()
    assert loss.member_count == 300
    assert length(loss.member_snapshot) == 100
    assert Repo.aggregate(Occurrence, :count) == 1
    assert MonitoringLoss.detail(loss.id, time(8))["members"]["total"] == 300

    assert MonitoringLoss.detail(loss.id, time(8), %{"members_page" => "12"})["members"]["items"]
           |> length() == 25

    assert length(MonitoringLoss.detail(loss.id, time(8))["members"]["items"]) == 25
  end
end
