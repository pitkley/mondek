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
    Repo.get_by!(Incident, assignment_id: assignment.id)
  end

  defp search(i), do: CorrelationCandidates.for_episode("individual", i.id)

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
