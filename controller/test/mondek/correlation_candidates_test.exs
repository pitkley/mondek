# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationCandidatesTest do
  use Mondek.DataCase, async: false
  alias Mondek.{CorrelationCandidates, CoverageFixtures, Configuration}
  @moduletag :empty_source_fixture

  @target %{
    "type" => "target",
    "source_id" => "coverage-test",
    "kind" => "service",
    "key" => "up"
  }
  @group %{"namespace" => "net", "key" => "up", "label" => "Upstream"}
  defp hint(selector),
    do: %{"dimension" => "network", "depends_on" => selector, "window_seconds" => 10}

  defp episode(name, target, hints, offset, options \\ []) do
    time = DateTime.add(at(), offset)
    check = CoverageFixtures.check(name, options[:env], target)

    check =
      update_in(check["outputs"], fn [output] ->
        output = Map.put(output, "correlation_hints", hints)

        [
          if(options[:condition],
            do: Map.put(output, "condition", options[:condition]),
            else: output
          )
        ]
      end)

    pub =
      CoverageFixtures.publication([CoverageFixtures.candidate(check)], %{
        "source_id" => options[:source] || "coverage-test"
      })

    pub = Map.delete(pub, "coverage")
    assert {:ok, _} = Monitoring.inventory(pub, time)
    CoverageFixtures.activate(pub, time)
    CoverageFixtures.sample(pub, "CRIT", 1, time)
    [assignment] = CoverageFixtures.assignments(pub)
    incident = Repo.get_by!(Incident, assignment_id: assignment.id)
    if options[:publication], do: {incident, pub}, else: incident
  end

  defp search(i), do: CorrelationCandidates.for_episode("individual", i.id)

  alias Mondek.CorrelationRelationships, as: Links
  defp individual(id), do: %{"id" => id, "type" => "individual"}

  defp add_link(child, parent) do
    %{
      "action" => "add",
      "subject" => individual(child.id),
      "target" => individual(parent.id),
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Confirmed network evidence",
      "dimension" => "network"
    }
  end

  test "review is bound to selected matches, survives unrelated candidates, and replays once" do
    child = episode("app", "app", [hint(@target)], 0)
    parent = episode("network", "up", [], -1)
    p = add_link(child, parent)
    assert {:ok, review} = Links.preview(p)
    episode("unrelated", "up", [], 1)

    assert {:ok, primary} =
             Mondek.Correlations.preview(%{
               "action" => "create",
               "request_id" => Ecto.UUID.generate(),
               "episodes" => [individual(child.id), individual(parent.id)],
               "reason" => "Shared outage",
               "title" => "Primary case"
             })

    assert {:ok, %{"case_id" => case_id}} = Mondek.Correlations.apply(primary["review_token"])

    snapshot = fn ->
      {Mondek.Correlations.detail(case_id), Repo.all(from o in Occurrence, order_by: o.id),
       Repo.all(from a in Attempt, order_by: a.id),
       Repo.all(from c in Mondek.Control, order_by: c.id)}
    end

    before = snapshot.()

    assert {:ok, %{"relationship_id" => id, "replayed" => false}} =
             Links.apply(review["review_token"], at())

    assert {:ok, %{"relationship_id" => ^id, "replayed" => true}} =
             Links.apply(review["review_token"], at())

    assert {:error, {:invalid, _}} = Links.preview(%{p | "request_id" => Ecto.UUID.generate()})

    assert [%{"id" => ^id, "status" => "active", "revision" => 1} = item] =
             Links.list("individual", child.id)["items"]

    assert item["matches"] == review["matches"]
    assert Links.list("individual", parent.id)["items"] == [item]
    assert Links.list("individual", parent.id, 2)["items"] == []

    remove = %{
      "action" => "remove",
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Disproved",
      "subject" => individual(parent.id),
      "relationship_id" => id
    }

    assert {:ok, r} = Links.preview(remove)
    assert r["relationship"] == item
    assert {:ok, _} = Links.apply(r["review_token"], DateTime.add(at(), 1))
    assert {:ok, %{"replayed" => true}} = Links.apply(r["review_token"], DateTime.add(at(), 1))

    assert [
             %{
               "status" => "removed",
               "revision" => 2,
               "removal_reason" => "Disproved",
               "reason" => "Confirmed network evidence",
               "matches" => matches
             }
           ] = Links.list("individual", child.id)["items"]

    assert matches == item["matches"]
    assert before == snapshot.()

    assert {:ok, 0} =
             Repo.transaction(fn -> Links.prune!(DateTime.add(at(), 1), 1) end)

    assert {:ok, 1} =
             Repo.transaction(fn -> Links.prune!(DateTime.add(at(), 2), 1) end)

    assert Repo.aggregate(Mondek.CorrelationRelationshipReceipt, :count) == 0
  end

  test "competing final slots serialize and closed links release capacity" do
    {first, pub} = episode("first", "up", [], 0, publication: true)
    child = episode("app", "app", [hint(@target)], 0)
    parents = [first | for(n <- 2..17, do: episode("parent-#{n}", "up", [], 0))]
    proposals = Enum.map(parents, &add_link(child, &1))

    tokens =
      Enum.map(proposals, fn proposal ->
        {:ok, report} = Links.preview(proposal)
        report["review_token"]
      end)

    {accepted, competing} = Enum.split(tokens, 15)
    Enum.each(accepted, fn token -> assert {:ok, _} = Links.apply(token) end)

    results =
      competing |> Task.async_stream(&Links.apply/1) |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :review_changed})) == 1
    assert Links.list("individual", child.id)["total"] == 16
    CoverageFixtures.sample(pub, "OK", 2, DateTime.add(at(), 1))
    failed = Enum.find_index(results, &(&1 == {:error, :review_changed}))
    assert {:ok, %{"replayed" => false}} = Links.apply(Enum.at(competing, failed))
    assert Links.list("individual", child.id)["total"] == 17
  end

  test "a reviewed add cannot override an intervening add and removal" do
    child = episode("app", "app", [hint(@target)], 0)
    parent = episode("up", "up", [], 0)
    proposal = add_link(child, parent)
    assert {:ok, earliest} = Links.preview(%{proposal | "request_id" => Ecto.UUID.generate()})

    assert {:ok, %{"relationship_id" => earliest_id}} =
             Links.apply(earliest["review_token"], at())

    del = %{
      "action" => "remove",
      "subject" => individual(parent.id),
      "relationship_id" => earliest_id,
      "reason" => "Earlier decision",
      "request_id" => Ecto.UUID.generate()
    }

    assert {:ok, d} = Links.preview(del)
    assert {:ok, _} = Links.apply(d["review_token"], DateTime.add(at(), -1))
    assert [prior] = Links.list("individual", child.id)["items"]
    assert prior["removed_at"] == prior["inserted_at"]

    assert {:ok, old} = Links.preview(proposal)
    assert {:ok, newer} = Links.preview(%{proposal | "request_id" => Ecto.UUID.generate()})
    assert {:ok, %{"relationship_id" => id}} = Links.apply(newer["review_token"])

    remove = %{
      "action" => "remove",
      "subject" => individual(parent.id),
      "relationship_id" => id,
      "reason" => "Operator override",
      "request_id" => Ecto.UUID.generate()
    }

    assert {:ok, r} = Links.preview(remove)
    assert {:ok, _} = Links.apply(r["review_token"])
    assert {:ok, 1} = Repo.transaction(fn -> Links.prune!(DateTime.add(at(), 1), 1) end)
    assert {:error, :review_changed} = Links.apply(old["review_token"])
  end

  test "a closed endpoint ends the exact reviewed episode despite a new failure" do
    child = episode("app", "app", [hint(@target)], 0)
    {parent, pub} = episode("network", "up", [], -1, publication: true)
    p = add_link(child, parent)
    assert {:ok, review} = Links.preview(p)
    assert {:ok, _} = Links.apply(review["review_token"])
    CoverageFixtures.sample(pub, "OK", 2, DateTime.add(at(), 2))
    CoverageFixtures.sample(pub, "CRIT", 3, DateTime.add(at(), 3))

    assert [%{"status" => "endpoint_closed", "target" => %{"status" => "closed", "id" => id}}] =
             Links.list("individual", child.id)["items"]

    assert id == parent.id
    assert [%{"id" => other}] = search(child)["candidates"]
    refute other == parent.id
    assert Links.list("individual", other)["items"] == []
  end

  test "stale selected provenance, noncanonical refs, wrong dimension and environment are rejected" do
    child = episode("app", "app", [hint(@target)], 0)
    parent = episode("net", "up", [], 0, condition: @group)

    assert Links.list("individual", parent.id) ==
             Links.list("condition", parent.condition_incident_id)

    outside = episode("foreign", "up", [], 0, env: "outside")
    p = add_link(child, parent)
    assert {:error, {:invalid, _}} = Links.preview(p)
    assert {:error, {:invalid, _}} = Links.preview(add_link(child, outside))
    p = %{p | "target" => %{"type" => "condition", "id" => parent.condition_incident_id}}
    assert {:error, {:invalid, _}} = Links.preview(%{p | "dimension" => "db"})
    assert {:ok, r} = Links.preview(p)
    Repo.delete!(Repo.get_by!(Configuration, assignment_id: child.assignment_id, generation: 1))
    assert {:error, :review_changed} = Links.apply(r["review_token"])
  end

  test "exact environment and source, both arrival orders, inclusive window and opening generation" do
    old = episode("ancient", "up", [], -100)
    child = episode("app", "app", [hint(@target)], 0)

    assert [%{"id" => old_id, "matches" => [%{"timing" => "overlap"}]}] =
             search(child)["candidates"]

    assert old_id == old.id
    late = episode("at-edge", "up", [], 10)
    episode("outside", "up", [], 11)
    episode("other-env", "up", [], 0, env: "prod")
    episode("other-source", "up", [], 0, source: "other")
    [first, second] = search(child)["candidates"]
    assert first["id"] == late.id and second["id"] == old.id

    assert [%{"timing" => "later_opening", "contributors" => [%{"generation" => 1}]}] =
             first["matches"]

    config = Repo.get_by!(Configuration, assignment_id: child.assignment_id, generation: 1)

    Repo.insert!(%Configuration{
      assignment_id: child.assignment_id,
      generation: 2,
      params: %{},
      definition: %{"outputs" => []},
      saved_at: at()
    })

    assert search(child)["hint_count"] == 1
    Repo.delete!(config)
    assert search(child)["status"] == "unavailable"
    assert search(old)["status"] == "complete"
    assert search(old)["hint_count"] == 0
  end

  test "canonical subjects and parents merge reasons and surface differing member declarations" do
    parent = episode("network-a", "up", [], -1, condition: @group)
    episode("network-b", "up", [], -1, condition: @group)
    cond_hint = hint(@group |> Map.delete("label") |> Map.put("type", "condition"))
    group = %{@group | "key" => "app"}
    child = episode("app-a", "app", [cond_hint, hint(@target)], 0, condition: group)
    episode("app-b", "app", [hint(@target)], 0, condition: group)
    result = search(child)
    assert result == CorrelationCandidates.for_episode("condition", child.condition_incident_id)
    assert result["conflicting_hints"]
    assert [%{"type" => "condition", "id" => id, "matches" => matches}] = result["candidates"]
    assert id == parent.condition_incident_id
    assert Enum.sort(Enum.map(matches, &length(&1["contributors"]))) == [1, 2]
  end

  test "a later target contribution uses its own detection time before canonicalization" do
    old = episode("old-network", "unrelated", [], -100, condition: @group)
    child = episode("app", "app", [hint(@target)], 0)
    episode("too-late", "up", [], 11, condition: @group)
    assert search(child)["candidates"] == []
    episode("eligible", "up", [], 5, condition: @group)

    assert [%{"id" => id, "opened_at" => opened, "matches" => [%{"timing" => "later_opening"}]}] =
             search(child)["candidates"]

    assert id == old.condition_incident_id and opened == Monitoring.iso(old.opened_at)
  end

  test "each declaring member's own opening bounds eligibility and provenance" do
    group = %{@group | "key" => "app"}
    first = episode("first-child", "app", [hint(@target)], 0, condition: group)
    second = episode("second-child", "app", [hint(@target)], 100, condition: group)
    up = episode("up", "up", [], 105)

    assert [%{"id" => id, "matches" => [%{"timing" => "later_opening", "contributors" => [ref]}]}] =
             search(first)["candidates"]

    assert id == up.id and ref["incident_id"] == second.id
  end

  test "returned matches and their provenance are capped independently" do
    episode("network", "up", [], 0)
    hints = for n <- 1..5, do: Map.put(hint(@target), "dimension", "net-#{n}")
    children = for n <- 1..5, do: episode("app-#{n}", "app", hints, 0, condition: @group)

    assert %{
             "status" => "incomplete",
             "truncated" => true,
             "hint_count" => 5,
             "candidates" => [%{"matches" => matches}]
           } = search(hd(children))

    assert length(matches) == 4
    assert Enum.all?(matches, &(length(&1["contributors"]) == 4))
  end

  test "candidate cap, deterministic ties and exclusion of the subject" do
    subject = episode("app", "up", [hint(@target)], 0)
    ids = for n <- 1..21, do: episode("peer-#{n}", "up", [], 1).id
    result = search(subject)
    assert result["truncated"] and result["status"] == "incomplete"
    assert Enum.map(result["candidates"], & &1["id"]) == Enum.take(Enum.sort(ids), 20)
  end
end
