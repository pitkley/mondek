# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.PublisherLifecycleTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    PublisherLifecycle,
    PublisherLifecycleEvent,
    PublisherLifecycleEvidence,
    SourceInventory,
    Coverage,
    CoverageDeclaration,
    ResultStream,
    Conditions,
    ConditionIncident
  }

  alias Mondek.CoverageFixtures, as: F

  test "retirement is atomic, source-scoped, fenced and preserves original evidence and controls" do
    p = publication()

    other =
      F.publication(
        [F.candidate(F.check("other"))],
        Map.merge(Map.take(p, ~w(installation_id session_id boot)), %{
          "source_id" => "other-source"
        })
      )

    assert {:ok, _} = Monitoring.inventory(other, at())
    assert {:ok, _} = F.activate(other)
    assert disposition(F.sample(p, "CRIT")) == "current"
    [a] = F.assignments(p)
    incident = Repo.get_by!(Incident, assignment_id: a.id)
    evidence = Repo.one!(Observation)
    occurrences = Repo.all(Occurrence)
    {review, proposal} = preview(p, "retire")
    assert review["summary"]["assignments"] == 1
    assert review["summary"]["open_incidents"] == 1
    assert review["summary"]["scopes_losing_last_publisher"] == 1
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert result["publisher"]["lifecycle_status"] == "retired"
    assert F.assignments(p) == []
    assert length(F.assignments(other)) == 1
    assert Repo.get!(Observation, evidence.id) == evidence
    closed = Repo.get!(Incident, incident.id)
    assert closed.closure_reason == "publisher_retired"
    assert closed.closing_observation_id == nil
    assert Enum.all?(occurrences, fn o -> Repo.get!(Occurrence, o.id).payload == o.payload end)

    assert {:error, :publisher_retired} =
             Monitoring.inventory(Map.put(p, "inventory_revision", 999), at())

    assert {:ok, reply} = F.activate(p)
    assert length(reply["assignments"]) == 1
    assert hd(reply["assignments"])["id"] == hd(F.assignments(other)).id
    assert reply["assignments_authoritative"]
    assert Coverage.scopes(%{"source_id" => p["source_id"]}, at())["total"] == 0
    assert Repo.aggregate(CoverageDeclaration, :count) == 2

    assert Enum.any?(
             Monitoring.incident_detail(incident.id, at())["controls"],
             &(&1["kind"] == "publisher_retired")
           )
  end

  test "restore requests successful newer discovery, creates new identities and never repeats a consumed action" do
    p = publication()
    [old] = F.assignments(p)
    old_stream = Repo.get_by!(ResultStream, assignment_id: old.id)
    {review, proposal} = preview(p, "retire")
    assert {:ok, retired} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    {restore, restore_proposal} = preview(p, "restore")
    assert restore["summary"]["scopes_losing_last_publisher"] == 0
    assert restore["summary"]["scopes_losing_last_selected"] == 0
    assert restore["summary"]["replacement_gaps"] == 0

    assert {:ok, waiting} =
             PublisherLifecycle.apply(restore["review_token"], restore_proposal, at())

    assert waiting["publisher"]["lifecycle_status"] == "awaiting_inventory"
    assert waiting["publisher"]["resume_after_revision"] == 1
    assert Coverage.scopes(%{}, at())["total"] == 0
    assert {:error, :publication_refresh_required} = Monitoring.inventory(p, at())
    assert {:ok, control} = F.activate(p)

    assert control["inventory_refresh"] == %{
             p["source_id"] => %{"after_revision" => 1, "lifecycle_revision" => 3}
           }

    assert {:ok, replayed} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert replayed["receipt"] == retired["receipt"]
    assert replayed["publisher"]["lifecycle_status"] == "awaiting_inventory"
    assert Repo.aggregate(PublisherLifecycleEvent, :count) == 2

    assert {:error, :publication_refresh_required} =
             Monitoring.inventory(Map.put(p, "inventory_revision", 999), at())

    assert {:error, :publication_refresh_required} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "restoration_revision" => 2}),
               at()
             )

    restored = Map.merge(p, %{"inventory_revision" => 2, "restoration_revision" => 3})
    assert {:ok, _} = Monitoring.inventory(restored, at())
    assert {:ok, _} = Monitoring.inventory(restored, at())
    [new] = F.assignments(p)
    refute new.id == old.id
    refute Repo.get_by!(ResultStream, assignment_id: new.id).id == old_stream.id
    assert Repo.get!(Assignment, old.id).retired_at
    assert {:ok, control} = F.activate(p)
    assert control["inventory_refresh"] == %{}
    assert hd(Coverage.scopes(%{}, at())["items"])["status"] == "awaiting"
    assert disposition(F.sample(p, "OK")) == "current"
    assert hd(Coverage.scopes(%{}, at())["items"])["status"] == "observed"
  end

  test "replacement requires exact fresh successor authority and compatible effective settings" do
    predecessor = publication()
    successor = publication()
    assert disposition(F.sample(predecessor, "CRIT")) == "current"
    {blocked, _} = preview(predecessor, "replace", successor)
    refute blocked["can_apply"]
    assert hd(blocked["items"])["replacement_status"] == "not_fresh"
    assert disposition(F.sample(successor, "OK")) == "current"
    {review, proposal} = preview(predecessor, "replace", successor)
    assert review["can_apply"]
    [row] = review["items"]
    assert row["successor_observation_id"]

    assert {:error, {:invalid, _}} =
             PublisherLifecycle.apply(review["review_token"], proposal, DateTime.add(at(), 13))

    assert is_nil(source(predecessor).retired_at)
    assert disposition(F.sample(successor, "OK", 2, DateTime.add(at(), 14))) == "current"

    assert {:ok, result} =
             PublisherLifecycle.apply(review["review_token"], proposal, DateTime.add(at(), 14))

    assert result["publisher"]["replacement_id"] == source(successor).id
    assert Repo.one!(Incident).closure_reason == "publisher_replaced"
    assert Repo.one!(Incident).closing_observation_id == nil

    assert {:ok, event} =
             PublisherLifecycle.event(source(predecessor).id, result["receipt"]["id"])

    [saved] = event["items"]
    assert saved["successor_observation_id"] != row["successor_observation_id"]
    assert saved["successor_health"] == "OK"
    assert saved["assignment_id"] != saved["successor_assignment_id"]

    assert {:error, :not_found} =
             PublisherLifecycle.event(source(successor).id, result["receipt"]["id"])
  end

  test "routine measurements preserve review while episode, acknowledgement and inventory changes invalidate it" do
    p = publication()
    assert disposition(F.sample(p, "CRIT")) == "current"
    {review, proposal} = preview(p, "retire")
    assert disposition(F.sample(p, "CRIT", 2)) == "current"
    assert {:ok, _} = PublisherLifecycle.preview(proposal, 1, at(), review["review_token"])
    incident = Repo.one!(Incident)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
               "Investigating",
               at()
             )

    assert {:error, :review_changed} =
             PublisherLifecycle.apply(review["review_token"], proposal, at())

    {review, proposal} = preview(p, "retire")
    assert disposition(F.sample(p, "OK", 3)) == "current"

    assert {:error, :review_changed} =
             PublisherLifecycle.apply(review["review_token"], proposal, at())

    {review, proposal} = preview(p, "retire")
    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 2), at())

    assert {:error, :review_changed} =
             PublisherLifecycle.apply(review["review_token"], proposal, at())
  end

  test "failed successor shares the existing episode, acknowledgement, occurrence and retry budget" do
    one = publication(true)
    two = publication(true)
    for p <- [one, two], do: assert(disposition(F.sample(p, "CRIT")) == "current")
    group = Repo.one!(ConditionIncident)

    assert {:ok, _} =
             Conditions.acknowledge(
               group.id,
               %{
                 "mode" => "until_incident_ends",
                 "revision" => 0,
                 "attention_revision" => group.attention_revision
               },
               "Same ongoing problem",
               at()
             )

    before = Repo.one!(Occurrence)
    jobs = Repo.all(from j in Oban.Job, select: {j.id, j.attempt, j.max_attempts, j.args})
    {review, proposal} = preview(one, "replace", two)
    assert review["can_apply"]
    assert {:ok, _} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    saved = Repo.get!(ConditionIncident, group.id)
    assert saved.status == "open"
    assert Monitoring.acknowledgement_active?(saved, at())
    assert Repo.one!(Occurrence).id == before.id
    assert Repo.one!(Occurrence).payload == before.payload
    assert Repo.all(from j in Oban.Job, select: {j.id, j.attempt, j.max_attempts, j.args}) == jobs
    assert Repo.aggregate(from(i in Incident, where: i.status == "open"), :count) == 1
    closed = Repo.one!(from i in Incident, where: i.status == "closed")
    assert closed.closure_reason == "publisher_replaced"
    detail = Mondek.ConditionInspection.detail(group.id, %{}, at())
    assert Enum.any?(detail["controls"], &(&1["kind"] == "publisher_replaced"))
  end

  test "unknown catalogues still preview every affected result and cannot claim replacement" do
    p = F.publication([F.candidate(F.check())]) |> Map.delete("coverage")
    assert {:ok, _} = Monitoring.inventory(p, at())
    replacement = publication()
    assert disposition(F.sample(replacement, "OK")) == "current"
    {review, _} = preview(p, "retire")
    [row] = review["items"]
    assert row["catalogue_unknown"]
    assert row["assignment_id"] == hd(F.assignments(p)).id
    assert row["stream_id"]
    assert row["source_key"] == "service"
    assert review["can_apply"]
    {review, _} = preview(p, "replace", replacement)
    refute review["can_apply"]
    assert Enum.any?(review["blockers"], &String.contains?(&1, "catalogues"))
  end

  test "zero selected, unresolved and incompatible settings prevent complete replacement" do
    successor = publication()
    assert disposition(F.sample(successor, "OK")) == "current"

    for p <- [F.publication([]), F.publication([F.candidate(F.check(), false)])] do
      assert {:ok, _} = Monitoring.inventory(p, at())
      {review, _} = preview(p, "replace", successor)
      refute review["can_apply"]
    end

    predecessor = publication()
    [a] = F.assignments(predecessor)
    # An effective schema contract difference can never be hidden by matching targets.
    Repo.update_all(from(a in Assignment, where: a.id == ^a.id), set: [interval_seconds: 4.0])
    {review, _} = preview(predecessor, "replace", successor)
    refute review["can_apply"]
    assert hd(review["items"])["replacement_status"] == "incompatible"
  end

  test "public code differences are reviewed while effective contract remains explicit" do
    one = publication()

    two =
      F.publication([F.candidate(F.check())])
      |> put_in(["coverage", "code_revision"], String.duplicate("f", 64))

    assert {:ok, _} = Monitoring.inventory(two, at())
    assert {:ok, _} = F.activate(two)
    assert disposition(F.sample(two, "OK")) == "current"
    {review, _} = preview(one, "replace", two)
    assert review["can_apply"]
    assert review["summary"]["code_differs"]
    refute review["summary"]["runtime_differs"]
  end

  test "large publication preview and retained impact history are independently paginated" do
    candidates = for n <- 1..30, do: F.candidate(F.check("service-#{n}"))
    p = F.publication(candidates)
    assert {:ok, _} = Monitoring.inventory(p, at())
    {review, proposal} = preview(p, "retire")
    assert review["total"] == 30 and length(review["items"]) == 25
    assert {:ok, page2} = PublisherLifecycle.preview(proposal, 2, at(), review["review_token"])
    assert page2["review_token"] == review["review_token"]
    assert length(page2["items"]) == 5
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert {:ok, event} = PublisherLifecycle.event(source(p).id, result["receipt"]["id"], 2)
    assert event["items"] == page2["items"]
    assert event["total"] == 30
    assert {:ok, detail} = PublisherLifecycle.get(source(p).id)
    assert detail["summary"]["assignments"] == 0
    refute Map.has_key?(hd(detail["history"]["items"]), "impact_items")
    assert byte_size(Jason.encode!(detail["history"])) < 10000

    assert Repo.get!(PublisherLifecycleEvent, result["receipt"]["id"]).snapshot["impact_items"]
           |> length() == 30
  end

  test "source-owned checks restore with new identities" do
    original = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    check =
      F.check("disk")
      |> Map.merge(%{
        "params_owner" => "ui",
        "params" => original.params,
        "parameter_schema" => %{
          "fields" => %{
            "path" => %{"type" => "string"},
            "warn_percent" => %{"type" => "number"},
            "crit_percent" => %{"type" => "number"}
          }
        },
        "outputs" => [
          %{
            "key" => "capacity",
            "label" => "Capacity",
            "target" => %{"kind" => "host", "key" => "node", "label" => "Node"}
          }
        ]
      })

    p = F.publication([F.candidate(check)]) |> Map.put("checks", [check])
    assert {:ok, _} = Monitoring.inventory(p, at())
    old_id = hd(F.assignments(p)).id
    act(p, "retire")
    act(p, "restore")

    assert {:ok, %{"accepted_checks" => 1}} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "restoration_revision" => 3}),
               at()
             )

    [new] = F.assignments(p)
    refute new.id == old_id
    assert Repo.get!(Assignment, old_id).retired_at
  end

  test "concurrent retirement and publication preserve either the reviewed fence or the newer inventory" do
    p = publication()
    {review, proposal} = preview(p, "retire")

    results =
      concurrent(p, [
        fn -> PublisherLifecycle.apply(review["review_token"], proposal, at()) end,
        fn -> Monitoring.inventory(Map.put(p, "inventory_revision", 2), at()) end
      ])

    if source(p).retired_at do
      assert match?([{:ok, _}, {:error, :publisher_retired}], results)
      assert source(p).revision == 1
      assert F.assignments(p) == []
    else
      assert match?([{:error, :review_changed}, {:ok, _}], results)
      assert source(p).revision == 2
      assert length(F.assignments(p)) == 1
    end
  end

  test "concurrent duplicate apply returns one durable receipt" do
    p = publication()
    {review, proposal} = preview(p, "retire")

    [{:ok, one}, {:ok, two}] =
      concurrent(
        p,
        List.duplicate(
          fn -> PublisherLifecycle.apply(review["review_token"], proposal, at()) end,
          2
        )
      )

    assert one["receipt"] == two["receipt"]
    assert Repo.aggregate(PublisherLifecycleEvent, :count) == 1
  end

  test "invalid reasons, forged reviews and invalid lifecycle database shapes fail without mutation" do
    p = publication()
    {review, proposal} = preview(p, "retire")
    assert {:error, :invalid_review} = PublisherLifecycle.apply("forged", proposal, at())

    assert {:error, :review_changed} =
             PublisherLifecycle.apply(
               review["review_token"],
               Map.put(proposal, "reason", "Different reason"),
               at()
             )

    for reason <- ["", "bad\ntext", String.duplicate("x", 501), %{}] do
      assert {:error, {:invalid, _}} =
               PublisherLifecycle.preview(Map.put(proposal, "reason", reason), 1, at())
    end

    id = source(p).id

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(s in SourceInventory, where: s.id == ^id), set: [retired_at: at()])
    end

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(s in SourceInventory, where: s.id == ^id),
        set: [resume_after_revision: 2]
      )
    end

    assert Repo.aggregate(PublisherLifecycleEvent, :count) == 0
  end

  test "restoration at the maximum inventory revision has an explicit blocker" do
    p =
      F.publication([F.candidate(F.check())], %{"inventory_revision" => 9_223_372_036_854_775_806})

    assert {:ok, _} = Monitoring.inventory(p, at())
    act(p, "retire")
    {review, _} = preview(p, "restore")
    refute review["can_apply"]
    assert Enum.any?(review["blockers"], &String.contains?(&1, "revision limit"))
  end

  test "a prior restoration marker cannot authorize a later restoration and buffered evidence stays historical" do
    p = publication()
    [a] = F.assignments(p)

    report =
      measurement("CRIT", 1, %{
        "assignment_id" => a.id,
        "installation_id" => p["installation_id"],
        "session_id" => p["session_id"],
        "generation" => a.desired_generation,
        "started_at" => Monitoring.iso(at()),
        "evaluated_at" => Monitoring.iso(at()),
        "results" => [
          %{
            "key" => "health",
            "health" => "CRIT",
            "summary" => "Buffered failure",
            "source_at" => Monitoring.iso(at())
          }
        ]
      })

    act(p, "retire")

    assert disposition(
             Monitoring.ingest(
               envelope([report], Map.take(p, ~w(installation_id session_id))),
               at()
             )
           ) == "historical"

    assert Repo.get!(Observation, report["id"]).payload == report
    assert Repo.aggregate(Incident, :count) == 0
    act(p, "restore")
    refreshed = Map.merge(p, %{"inventory_revision" => 2, "restoration_revision" => 3})
    assert {:ok, _} = Monitoring.inventory(refreshed, at())
    act(p, "retire")
    act(p, "restore")

    assert {:error, :publication_refresh_required} =
             Monitoring.inventory(Map.put(refreshed, "inventory_revision", 3), at())

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(refreshed, %{"inventory_revision" => 3, "restoration_revision" => 5}),
               at()
             )

    assert Repo.get!(Assignment, a.id).retired_at
    assert Repo.aggregate(Incident, :count) == 0
  end

  test "complete replacement rejects different exact namespaces, old sessions and unconfirmed catalogues" do
    p = publication()

    for {environment, target} <- [
          {nil, "service"},
          {"staging", "service"},
          {"production", "other"}
        ] do
      other = F.publication([F.candidate(F.check("service", environment, target))])
      assert {:ok, _} = Monitoring.inventory(other, at())
      assert {:ok, _} = F.activate(other)
      assert disposition(F.sample(other)) == "current"
      {review, _} = preview(p, "replace", other)
      refute review["can_apply"]
      assert hd(review["items"])["replacement_status"] == "missing"
    end

    other = publication()
    assert disposition(F.sample(other)) == "current"
    {review, _} = preview(p, "replace", other)
    assert review["can_apply"]
    restarted = Map.merge(other, %{"boot" => 2, "session_id" => Ecto.UUID.generate()})
    assert {:ok, _} = F.activate(restarted)
    {review, _} = preview(p, "replace", restarted)
    refute review["can_apply"]
    assert hd(review["items"])["successor_measurement_state"] == "pending"
    downgraded = restarted |> Map.delete("coverage") |> Map.put("inventory_revision", 2)
    assert {:ok, _} = Monitoring.inventory(downgraded, at())
    assert {:ok, _} = F.activate(downgraded)
    assert disposition(F.sample(downgraded, "OK", 2)) == "current"
    {review, _} = preview(p, "replace", downgraded)
    refute review["can_apply"]
    assert Enum.any?(review["blockers"], &String.contains?(&1, "confirmed"))
  end

  test "maximum complete catalogue retains all 8192 impact identities behind bounded inspection" do
    candidates =
      for n <- 1..512 do
        outputs =
          for k <- 1..16,
              do: %{
                "key" => "result-#{k}",
                "label" => "Result #{k}",
                "target" => %{"key" => "node-#{n}", "kind" => "host", "label" => "Node #{n}"}
              }

        F.candidate(Map.put(F.check("check-#{n}"), "outputs", outputs), false)
      end

    p = F.publication(candidates)
    assert {:ok, _} = Monitoring.inventory(p, at())
    {review, proposal} = preview(p, "retire")
    assert review["total"] == 8192 and length(review["items"]) == 25
    assert review["summary"]["scopes_losing_last_publisher"] == 8192
    assert {:ok, last} = PublisherLifecycle.preview(proposal, 9999, at(), review["review_token"])
    assert last["page"] == 328 and length(last["items"]) == 17
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert {:ok, event} = PublisherLifecycle.event(source(p).id, result["receipt"]["id"], 9999)
    assert event["items"] == last["items"] and event["total"] == 8192
    assert {:ok, detail} = PublisherLifecycle.get(source(p).id)
    assert byte_size(Jason.encode!(detail)) < 15000

    assert length(
             Repo.get!(PublisherLifecycleEvent, result["receipt"]["id"]).snapshot["impact_items"]
           ) == 8192
  end

  test "saved replacement witnesses retain exact observations and configuration until their decision is removed" do
    predecessor = publication()
    successor = publication()
    assert disposition(F.sample(successor)) == "current"
    {review, proposal} = preview(predecessor, "replace", successor)
    witness = hd(review["items"])["successor_observation_id"]
    original = Repo.get!(Observation, witness)
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    evidence = Repo.one!(PublisherLifecycleEvidence)
    assert evidence.event_id == result["receipt"]["id"] and evidence.observation_id == witness
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(original) end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%PublisherLifecycleEvidence{
        event_id: evidence.event_id,
        observation_id: witness
      })
    end

    for sequence <- 2..105,
        do: assert(disposition(F.sample(successor, "OK", sequence)) == "current")

    ordinary =
      Repo.one!(from o in Observation, where: o.id != ^witness, order_by: o.sequence, limit: 1)

    assert {:ok, proof} =
             PublisherLifecycle.evidence(source(predecessor).id, evidence.event_id, witness)

    assert proof["observation"]["payload"] == original.payload
    assert proof["referenced_result_keys"] == ["health"]
    assert proof["configuration"]["generation"] == original.generation

    assert {:error, :not_found} =
             PublisherLifecycle.evidence(source(successor).id, evidence.event_id, witness)

    assert {:error, :not_found} =
             PublisherLifecycle.evidence(source(predecessor).id, evidence.event_id, ordinary.id)

    assert {:error, :not_found} =
             PublisherLifecycle.evidence(source(predecessor).id, evidence.event_id + 100, witness)

    assert {:error, :not_found} =
             PublisherLifecycle.evidence(source(predecessor).id, evidence.event_id, "invalid")

    [assignment] = F.assignments(successor)

    for revision <- 2..25 do
      revision_source =
        revision |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

      assert {:ok, _} =
               Monitoring.inventory(
                 Map.merge(successor, %{
                   "inventory_revision" => revision,
                   "source_revision" => revision_source
                 }),
                 at()
               )
    end

    assert Repo.aggregate(
             from(c in Mondek.Configuration, where: c.assignment_id == ^assignment.id),
             :count
           ) == 25

    act(successor, "retire")
    future = DateTime.add(at(), 40 * 86_400)
    assert {:ok, _} = Mondek.Sweeper.sweep(future)
    assert Repo.get!(Observation, witness) == original

    assert {:ok, retained_proof} =
             PublisherLifecycle.evidence(source(predecessor).id, evidence.event_id, witness)

    assert retained_proof == proof
    assert Repo.get(Observation, ordinary.id) == nil
    assert Repo.get_by!(Mondek.Configuration, assignment_id: assignment.id, generation: 1)
    assert {:ok, saved} = PublisherLifecycle.event(source(predecessor).id, evidence.event_id)
    assert hd(saved["items"])["successor_observation_id"] == witness

    Repo.delete!(Repo.get!(PublisherLifecycleEvent, evidence.event_id))
    assert Repo.aggregate(PublisherLifecycleEvidence, :count) == 0
    assert {:ok, _} = Mondek.Sweeper.sweep(future)
    assert Repo.get(Observation, witness) == nil

    assert Repo.get_by(Mondek.Configuration, assignment_id: assignment.id, generation: 1) ==
             nil
  end

  test "restoration capacity is explicit and retirement of a waiting source releases one request" do
    p = publication()
    act(p, "retire")

    rows =
      for n <- 1..512,
          do: %{
            runner_id: p["installation_id"],
            source_id: "waiting-#{n}",
            revision: 1,
            source_revision: p["source_revision"],
            payload: %{},
            received_at: at(),
            lifecycle_revision: 3,
            resume_after_revision: 1
          }

    assert {512, _} = Repo.insert_all(SourceInventory, rows)
    {review, proposal} = preview(p, "restore")
    refute review["can_apply"]
    assert Enum.any?(review["blockers"], &String.contains?(&1, "512 restoration requests"))

    assert {:error, {:invalid, _}} =
             PublisherLifecycle.apply(review["review_token"], proposal, at())

    assert {:ok, control} = F.activate(p)
    assert map_size(control["inventory_refresh"]) == 512
    refute Map.has_key?(control["inventory_refresh"], p["source_id"])

    waiting = %{p | "source_id" => "waiting-1"}
    {cancel, cancel_proposal} = preview(waiting, "retire")
    assert cancel["summary"]["scopes_losing_last_publisher"] == 0
    assert {:ok, _} = PublisherLifecycle.apply(cancel["review_token"], cancel_proposal, at())
    assert {:ok, restored} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert restored["publisher"]["lifecycle_status"] == "awaiting_inventory"
    assert {:ok, control} = F.activate(p)
    assert map_size(control["inventory_refresh"]) == 512
    assert control["inventory_refresh"][p["source_id"]]["lifecycle_revision"] == 3
    refute Map.has_key?(control["inventory_refresh"], "waiting-1")
  end

  test "restoration cannot emit a lifecycle challenge above the protocol integer bound" do
    p = publication()
    act(p, "retire")
    id = source(p).id

    Repo.update_all(from(s in SourceInventory, where: s.id == ^id),
      set: [lifecycle_revision: 9_223_372_036_854_775_806]
    )

    {review, proposal} = preview(p, "restore")
    refute review["can_apply"]
    assert Enum.any?(review["blockers"], &String.contains?(&1, "lifecycle revision limit"))

    assert {:error, {:invalid, _}} =
             PublisherLifecycle.apply(review["review_token"], proposal, at())

    assert {:ok, control} = F.activate(p)
    assert control["inventory_refresh"] == %{}
  end

  test "one retained multi-output report distinguishes decision witnesses from unrelated sibling outputs" do
    p = publication()
    check = F.check()
    extra = %{hd(check["outputs"]) | "key" => "diagnostic", "label" => "Diagnostic"}
    check = Map.update!(check, "outputs", &(&1 ++ [extra]))
    successor = F.publication([F.candidate(check)])
    assert {:ok, _} = Monitoring.inventory(successor, at())
    assert {:ok, _} = F.activate(successor)
    [a] = F.assignments(successor)

    report =
      measurement("OK", 1, %{
        "assignment_id" => a.id,
        "installation_id" => successor["installation_id"],
        "session_id" => successor["session_id"],
        "generation" => a.desired_generation,
        "started_at" => Monitoring.iso(at()),
        "evaluated_at" => Monitoring.iso(at()),
        "results" =>
          for(
            key <- ["health", "diagnostic"],
            do: %{
              "key" => key,
              "health" => "OK",
              "summary" => "Measured #{key}",
              "source_at" => Monitoring.iso(at())
            }
          )
      })

    assert disposition(
             Monitoring.ingest(
               envelope([report], Map.take(successor, ~w(installation_id session_id))),
               at()
             )
           ) == "current"

    {review, proposal} = preview(p, "replace", successor)
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    assert Repo.aggregate(PublisherLifecycleEvidence, :count) == 1

    assert {:ok, proof} =
             PublisherLifecycle.evidence(source(p).id, result["receipt"]["id"], report["id"])

    assert proof["referenced_result_keys"] == ["health"]
    assert proof["observation"]["payload"] == report
    assert length(proof["witnesses"]) == 1
  end

  defp publication(grouped \\ false) do
    p = F.publication([F.candidate(F.check())])

    p =
      if grouped,
        do:
          put_in(p, ["checks", Access.at(0), "outputs", Access.at(0), "condition"], %{
            "namespace" => "app",
            "key" => "service",
            "label" => "Service"
          }),
        else: p

    assert {:ok, _} = Monitoring.inventory(p, at())
    assert {:ok, _} = F.activate(p)
    p
  end

  defp source(p),
    do: Repo.get_by!(SourceInventory, runner_id: p["installation_id"], source_id: p["source_id"])

  defp preview(p, action, successor \\ nil) do
    proposal = %{
      "publisher_id" => source(p).id,
      "action" => action,
      "reason" => "Operator reviewed lifecycle change"
    }

    proposal =
      if successor, do: Map.put(proposal, "successor_id", source(successor).id), else: proposal

    assert {:ok, review} = PublisherLifecycle.preview(proposal, 1, at())
    {review, proposal}
  end

  defp act(p, action) do
    {review, proposal} = preview(p, action)
    assert {:ok, result} = PublisherLifecycle.apply(review["review_token"], proposal, at())
    result
  end

  defp concurrent(p, functions) do
    parent = self()

    {:ok, tasks} =
      Mondek.ConfigurationRepository.transaction("inventory", fn ->
        Mondek.ConfigurationRules.lock_source!(p["source_id"])
        [[holder]] = Repo.query!("SELECT pg_backend_pid()").rows

        tasks =
          for function <- functions do
            Task.async(fn ->
              Repo.checkout(fn ->
                [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {:waiting, pid})
                function.()
              end)
            end)
          end

        for _ <- tasks do
          receive do
            {:waiting, pid} ->
              await_blocked(pid, holder, System.monotonic_time(:millisecond) + 5000)
          after
            5000 -> flunk("Lifecycle task did not start")
          end
        end

        tasks
      end)

    Enum.map(tasks, &Task.await(&1, 10000))
  end

  defp await_blocked(pid, holder, deadline) do
    [[blocked]] = Repo.query!("SELECT $2=ANY(pg_blocking_pids($1))", [pid, holder]).rows

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline
      await_blocked(pid, holder, deadline)
    end
  end
end
