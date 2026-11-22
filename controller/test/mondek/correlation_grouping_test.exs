# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationGroupingTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    CorrelationAutomationPolicy,
    CorrelationCase,
    CorrelationDecision,
    CorrelationGrouping,
    Correlations,
    CoverageFixtures,
    NotificationWorker
  }

  @moduletag :empty_source_fixture
  @hint %{
    "dimension" => "network",
    "depends_on" => %{
      "type" => "target",
      "source_id" => "coverage-test",
      "kind" => "service",
      "key" => "up"
    },
    "window_seconds" => 10
  }
  defp rule(hint \\ @hint) do
    CorrelationAutomationPolicy.set_rule(
      Ecto.UUID.generate(),
      %{
        "source_id" => "coverage-test",
        "check_id" => "app",
        "output_key" => "health",
        "hint" => hint,
        "revision" => 0,
        "enabled" => true,
        "reason" => "Approved dependency"
      },
      at()
    )
  end

  defp publish(name, target, opts \\ []) do
    check = CoverageFixtures.check(name, nil, target)

    check =
      if name == "app" || opts[:hint],
        do:
          update_in(check["outputs"], fn [o] ->
            [Map.put(o, "correlation_hints", [opts[:declared] || @hint])]
          end),
        else: check

    check =
      if opts[:condition],
        do:
          update_in(check["outputs"], fn [o] -> [Map.put(o, "condition", opts[:condition])] end),
        else: check

    pub =
      CoverageFixtures.publication([CoverageFixtures.candidate(check)]) |> Map.delete("coverage")

    assert {:ok, _} = Monitoring.inventory(pub, at())
    CoverageFixtures.activate(pub, at())
    pub
  end

  defp open(pub, offset) do
    CoverageFixtures.sample(pub, "CRIT", 1, DateTime.add(at(), offset))
    [a] = CoverageFixtures.assignments(pub)
    Repo.get_by!(Incident, assignment_id: a.id)
  end

  defp ref(i), do: %{"type" => "individual", "id" => i.id}

  defp run_jobs do
    Oban.drain_queue(queue: :correlations, with_recursion: true)
  end

  test "opening a child with one approved upstream creates one case and preserves standalone delivery" do
    assert {:ok, _} = rule()
    parent = open(publish("upstream", "up"), -3600)
    child = open(publish("app", "app"), 0)
    occurrences = Repo.all(from o in Occurrence, order_by: o.id)
    assert %{failure: 0} = run_jobs()

    assert %{"case_id" => id, "disposition" => "created"} =
             CorrelationGrouping.latest("individual", child.id)

    assert %CorrelationCase{batching_enabled: false} = Repo.get!(CorrelationCase, id)

    assert %{"case_id" => ^id, "provenance" => "deterministic_rule"} =
             Correlations.membership("individual", parent.id)

    assert %CorrelationDecision{
             provenance: "deterministic_rule",
             change: %{"rule_evidence" => %{"rules" => [%{"revision" => 1}]}}
           } = Repo.one!(CorrelationDecision)

    assert occurrences == Repo.all(from o in Occurrence, order_by: o.id)
    assert {:ok, _} = CorrelationGrouping.evaluate(ref(child), at())
    assert Repo.aggregate(CorrelationCase, :count) == 1

    assert {:ok, {%Occurrence{}, %Attempt{}}} =
             NotificationWorker.begin_attempt(hd(occurrences).id, at())
  end

  test "late parent wakes a previously unmatched child through a durable opening job" do
    assert {:ok, _} = rule()
    child = open(publish("app", "app"), 0)
    assert %{failure: 0} = run_jobs()
    assert %{"reason" => "no_match"} = CorrelationGrouping.latest("individual", child.id)
    _parent = open(publish("upstream", "up"), 10)
    assert %{failure: 0} = run_jobs()
    assert %{"disposition" => "created"} = CorrelationGrouping.latest("individual", child.id)
  end

  test "late commit of an older parent wakes children already evaluated as unmatched" do
    assert {:ok, _} = rule()
    child = open(publish("app", "app"), 20)
    assert %{failure: 0} = run_jobs()
    assert %{"reason" => "no_match"} = CorrelationGrouping.latest("individual", child.id)
    open(publish("parent", "up"), 0)
    assert %{failure: 0} = run_jobs()
    assert %{"disposition" => "created"} = CorrelationGrouping.latest("individual", child.id)
  end

  test "a case committed before a competing opening has stable membership and no dispatch hold" do
    assert {:ok, _} = rule()
    child = open(publish("app", "app"), 0)
    parent = open(publish("upstream", "up"), 1)
    extra = publish("second", "up")

    held(
      fn -> assert {:ok, "created"} = CorrelationGrouping.evaluate(ref(child), at()) end,
      fn -> open(extra, 2) end
    )

    assert Repo.aggregate(CorrelationCase, :count) == 1

    assert Correlations.membership("individual", child.id)["case_id"] ==
             Correlations.membership("individual", parent.id)["case_id"]

    o = Repo.get_by!(Occurrence, incident_id: child.id)
    assert {:ok, {%Occurrence{}, %Attempt{}}} = NotificationWorker.begin_attempt(o.id, at())
    assert %{failure: 0} = run_jobs()
    assert Repo.aggregate(Mondek.CorrelationMembership, :count) == 2
  end

  test "with no approval openings enqueue no grouping work" do
    _child = open(publish("app", "app"), 0)
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Mondek.CorrelationGroupingWorker")
  end

  test "an uncommitted competing parent opening is visible to the exclusive apply" do
    assert {:ok, _} = rule()
    open(publish("first", "up"), 0)
    child = open(publish("app", "app"), 1)
    competing = publish("second", "up")
    held(fn -> open(competing, 2) end, fn -> CorrelationGrouping.evaluate(ref(child), at()) end)
    assert %{"reason" => "multiple_parents"} = CorrelationGrouping.latest("individual", child.id)
    refute Repo.exists?(CorrelationCase)
  end

  test "admitted native attempt fences apply even while its result is unknown" do
    assert {:ok, _} = rule()
    parent = open(publish("upstream", "up"), 0)
    child = open(publish("app", "app"), 1)
    o = Repo.get_by!(Occurrence, incident_id: parent.id)

    held(
      fn ->
        assert {:ok, {%Occurrence{}, %Attempt{}}} = NotificationWorker.begin_attempt(o.id, at())
      end,
      fn -> CorrelationGrouping.evaluate(ref(child), at()) end
    )

    assert %{"reason" => "delivery_history"} = CorrelationGrouping.latest("individual", child.id)
    refute Repo.exists?(CorrelationCase)
  end

  test "an operator approval on one output cannot group another member of the same Condition" do
    assert {:ok, _} = rule()
    condition = %{"namespace" => "network", "key" => "down", "label" => "Connection"}
    parent = open(publish("parent", "up"), 0)
    child = open(publish("app", "app", condition: condition), 1)
    other = open(publish("second-app", "app", condition: condition, hint: true), 2)
    assert child.condition_incident_id == other.condition_incident_id
    ref = %{"type" => "condition", "id" => child.condition_incident_id}
    assert {:ok, _} = CorrelationGrouping.evaluate(ref, at())
    assert %{"reason" => "unapproved_match"} = CorrelationGrouping.latest("condition", ref["id"])
    refute Correlations.membership("individual", parent.id)
  end

  test "approval revocation wins against an already queued evaluation" do
    assert {:ok, rule} = rule()
    open(publish("parent", "up"), 0)
    child = open(publish("app", "app"), 1)

    revoke =
      Map.take(rule, ~w(source_id check_id output_key hint revision reason enabled))
      |> Map.put("enabled", false)

    held(
      fn -> assert {:ok, _} = CorrelationAutomationPolicy.set_rule(rule["id"], revoke, at()) end,
      fn -> CorrelationGrouping.evaluate(ref(child), at()) end
    )

    refute Repo.exists?(CorrelationCase)
    assert %{failure: 0} = run_jobs()
    refute Repo.exists?(CorrelationCase)
  end

  test "reviewed standalone override fences grouping until explicitly released" do
    assert {:ok, _} = rule()
    parent = open(publish("parent", "up"), 0)
    child = open(publish("app", "app"), 1)

    held(fn -> override(parent, "keep_standalone") end, fn ->
      CorrelationGrouping.evaluate(ref(child), at())
    end)

    assert %{"reason" => "operator_override"} = CorrelationGrouping.latest("individual", child.id)
    assert %{failure: 0} = run_jobs()
    override(parent, "allow_grouping")
    assert %{failure: 0} = run_jobs()
    assert %{"disposition" => "created"} = CorrelationGrouping.latest("individual", child.id)
  end

  test "acknowledgement and maintenance gate grouping without any queued notification" do
    set_notification_adapter(:off)
    assert {:ok, _} = rule()
    parent = open(publish("parent", "up"), 0)
    child = open(publish("app", "app"), 1)

    held(
      fn ->
        assert {:ok, _} = reviewed_acknowledgement_fixture(parent.id, 3600, "Acknowledged", at())
      end,
      fn -> CorrelationGrouping.evaluate(ref(child), at()) end
    )

    assert %{"reason" => "native_hold"} = CorrelationGrouping.latest("individual", child.id)
    assert {:ok, _} = reviewed_acknowledgement_fixture(parent.id, 0, "Released", at())
    {:ok, seed} = Mondek.Maintenance.seed(parent.assignment_id, nil, at())
    proposal = Map.put(seed["proposal"], "reason", "Maintenance")
    {:ok, review} = Mondek.Maintenance.preview(proposal, 1, at())

    held(
      fn ->
        assert {:ok, _} = Mondek.Maintenance.apply(review["review_token"], proposal, at())
      end,
      fn -> CorrelationGrouping.evaluate(ref(child), at()) end
    )

    assert %{"reason" => "native_hold"} = CorrelationGrouping.latest("individual", child.id)
    refute Repo.exists?(Occurrence)
    refute Repo.exists?(CorrelationCase)
  end

  test "a detached and re-enabled episode keeps its in-flight reservation and historical aggregate attempts" do
    assert {:ok, _} = rule()
    parent = open(publish("parent", "up"), 0)
    child = open(publish("app", "app"), 1)
    peer = open(publish("peer", "peer"), 1)

    {:ok, %{"case_id" => id}} =
      topology(%{
        "action" => "create",
        "title" => "Prior case",
        "episodes" => [ref(parent), ref(peer)]
      })

    {:ok, control} =
      Mondek.CaseControls.preview(
        id,
        %{"action" => "enable", "note" => "Reviewed", "request_id" => Ecto.UUID.generate()},
        at()
      )

    assert {:ok, _} = Mondek.CaseControls.apply(control["review_token"], at())
    o = Repo.get_by!(Occurrence, incident_id: parent.id)
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(o.id, at())
    batch = Repo.one!(Mondek.CorrelationBatch)

    held(
      fn ->
        assert {:ok, {:send, _, _, _}} = Mondek.CorrelationDelivery.begin_attempt(batch.id, at())
      end,
      fn -> topology(%{"action" => "detach", "case_id" => id, "episodes" => [ref(parent)]}) end
    )

    refute Correlations.membership("individual", parent.id)
    assert CorrelationAutomationPolicy.overridden?(ref(parent))
    override(parent, "allow_grouping")

    assert Repo.exists?(
             from r in Mondek.CorrelationReservation,
               where: r.occurrence_id == ^o.id and r.status == "reserved"
           )

    assert {:ok, "review"} = CorrelationGrouping.evaluate(ref(child), at())
    attempt = Repo.one!(Mondek.CorrelationAttempt)
    Mondek.CorrelationDelivery.finish(batch.id, attempt.id, {:error, :timeout}, at())

    refute Repo.exists?(
             from r in Mondek.CorrelationReservation,
               where: r.occurrence_id == ^o.id and r.status == "reserved"
           )

    assert {:ok, "review"} = CorrelationGrouping.evaluate(ref(child), at())
    assert %{"reason" => "delivery_history"} = CorrelationGrouping.latest("individual", child.id)
    assert Repo.aggregate(CorrelationCase, :count) == 1
  end

  defp topology(p) do
    p = Map.merge(p, %{"reason" => "Reviewed", "request_id" => Ecto.UUID.generate()})
    {:ok, preview} = Correlations.preview(p, at())
    Correlations.apply(preview["review_token"], at())
  end

  defp override(episode, action) do
    p = %{
      "action" => action,
      "subject" => if(is_struct(episode, Incident), do: ref(episode), else: episode),
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Operator decision"
    }

    {:ok, preview} = CorrelationAutomationPolicy.preview_override(p, at())
    assert {:ok, _} = CorrelationAutomationPolicy.apply_override(preview["review_token"], at())
  end

  test "resuming a Condition parent searches by canonical opening even when its only active contribution is newer" do
    condition = %{"namespace" => "network", "key" => "up", "label" => "Network"}

    hint = %{
      @hint
      | "depends_on" => %{"type" => "condition", "namespace" => "network", "key" => "up"}
    }

    assert {:ok, _} = rule(hint)
    original = publish("original", "net", condition: condition)
    parent = open(original, 0)
    subject = open(publish("app", "app", declared: hint), 10)
    parent_ref = %{"type" => "condition", "id" => parent.condition_incident_id}
    override(parent_ref, "keep_standalone")
    assert %{failure: 0} = run_jobs()
    open(publish("later", "net2", condition: condition), 100_000)
    CoverageFixtures.sample(original, "OK", 2, DateTime.add(at(), 100_001))
    assert %{failure: 0} = run_jobs()

    assert %{"reason" => "operator_override"} =
             CorrelationGrouping.latest("individual", subject.id)

    override(parent_ref, "allow_grouping")
    assert %{failure: 0} = run_jobs()
    assert %{"disposition" => "created"} = CorrelationGrouping.latest("individual", subject.id)
  end

  test "explicit retry replenishes native credits but keeps previous attempts ineligible for grouping" do
    assert {:ok, _} = rule()
    parent = open(publish("upstream", "up"), 0)
    child = open(publish("app", "app"), 1)
    occurrence = Repo.get_by!(Occurrence, incident_id: parent.id)
    credit = Repo.get!(Mondek.CorrelationCredit, occurrence.id)

    for _ <- 1..credit.limit do
      assert {:ok, {%Occurrence{}, %Attempt{}}} =
               NotificationWorker.begin_attempt(occurrence.id, at())
    end

    assert {:ok, :exhausted} = NotificationWorker.begin_attempt(occurrence.id, at())
    job = Repo.one!(from j in Oban.Job, where: j.args["occurrence_id"] == ^occurrence.id)
    assert :ok = Oban.cancel_job(job.id)
    assert {:ok, _} = Monitoring.retry_notification(occurrence.id, "Retry after outage", at())
    renewed = Repo.get!(Mondek.CorrelationCredit, occurrence.id)
    assert renewed.epoch == credit.epoch + 1
    assert renewed.spent == 0
    assert {:ok, "review"} = CorrelationGrouping.evaluate(ref(child), at())
    assert %{"reason" => "delivery_history"} = CorrelationGrouping.latest("individual", child.id)
  end

  # Hold the real writer's outer transaction open and verify PostgreSQL reports
  # its backend as the blocker before allowing either transaction to commit.
  defp held(first, next) do
    owner = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          first.()
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:holding, pid})

          receive do
            :commit -> :ok
          after
            10_000 -> raise "holder timed out"
          end
        end)
      end)

    assert_receive {:holding, blocker}, 5_000

    waiter =
      Task.async(fn ->
        Repo.transaction(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:waiting, pid})
          next.()
        end)
      end)

    assert_receive {:waiting, waiting}, 5_000

    try do
      await_block(waiting, blocker, System.monotonic_time(:millisecond) + 3_000)
    after
      send(holder.pid, :commit)
    end

    assert {:ok, _} = Task.await(holder)
    assert {:ok, _} = Task.await(waiter)
  end

  defp await_block(waiting, blocker, deadline) do
    [[blocked]] = Repo.query!("SELECT $2=ANY(pg_blocking_pids($1))", [waiting, blocker]).rows

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_block(waiting, blocker, deadline)
    end
  end
end
