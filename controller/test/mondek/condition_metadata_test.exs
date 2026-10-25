# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionMetadataTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Configuration, Protocol, ResultStream, SourceInventory}

  @condition %{
    "namespace" => "infrastructure",
    "key" => "orders:storage-pressure",
    "label" => "Orders storage pressure"
  }
  @impact %{"key" => "writes-blocked", "label" => "Writes blocked"}

  test "condition identity is explicit, separate from target and frozen in accepted definitions" do
    p = inventory(@condition)
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = assignment()
    original = stream(a)
    assert original.condition == @condition
    assert original.environment == "production"
    assert original.target["key"] == "linux-volume"

    assert Repo.get_by!(Configuration, assignment_id: a.id, generation: 1).definition["outputs"]
           |> hd()
           |> Map.fetch!("condition") == @condition

    renamed = Map.put(@condition, "label", "Readable new condition label")
    assert {:ok, _} = Monitoring.inventory(inventory(renamed, 2), at())
    assert stream(a).id == original.id
    assert stream(a).condition == renamed

    assert Repo.get_by!(Configuration, assignment_id: a.id, generation: 1).definition["outputs"]
           |> hd()
           |> Map.fetch!("condition") == @condition

    for invalid <- [
          "same-name",
          %{},
          Map.delete(@condition, "namespace"),
          Map.put(@condition, "environment", "staging"),
          Map.put(@condition, "key", "with spaces"),
          Map.put(@condition, "label", String.duplicate(" ", 200) <> "x"),
          Map.put(@condition, "namespace", "bad\0text")
        ] do
      assert {:error, {:invalid, _}} = Monitoring.inventory(inventory(invalid, 3), at())
      assert Repo.one!(SourceInventory).revision == 2
      assert stream(a).condition == renamed
    end
  end

  test "relationship changes retire the old stream and control without admitting old runs to the replacement" do
    assert {:ok, _} = Monitoring.inventory(inventory(@condition), at())
    old = assignment()
    activate(old)
    first = sample(old, "CRIT", 1)
    assert disposition(ingest(first)) == "current"
    incident = Repo.one!(Incident)
    original = stream(old)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               incident.id,
               %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
               "Investigating original condition",
               at()
             )

    replacement = Map.put(@condition, "key", "orders:availability")
    assert {:ok, _} = Monitoring.inventory(inventory(replacement, 2), at())
    current = stream(old)
    refute current.id == original.id
    assert current.current == %{}
    assert current.admission_generation == 2
    assert Repo.get!(ResultStream, original.id).condition == @condition
    assert Repo.get!(Incident, incident.id).closure_reason == "condition_changed"
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id), at())
    assert disposition(ingest(sample(old, "OK", 2))) == "historical"
    assert Repo.get!(ResultStream, current.id).current == %{}
    assert Repo.get!(Observation, first["id"]).payload == first

    next = assignment()
    activate(next)
    assert disposition(ingest(sample(next, "CRIT", 3))) == "current"
    new_incident = Repo.get_by!(Incident, stream_id: current.id)
    refute new_incident.id == incident.id
    refute Monitoring.acknowledgement_active?(new_incident, at())
    assert {:ok, _} = Monitoring.inventory(inventory(nil, 3), at())
    assert is_nil(stream(old).condition)
    refute stream(old).id == current.id
    assert Repo.get!(Incident, new_incident.id).closure_reason == "condition_changed"
  end

  test "database constraints reject malformed condition identity without losing existing streams" do
    assert {:ok, _} = Monitoring.inventory(inventory(@condition), at())
    row = stream(assignment())

    for invalid <- [
          %{},
          Map.put(@condition, "key", nil),
          Map.put(@condition, "namespace", "-invalid"),
          Map.put(@condition, "label", "bad\nlabel"),
          Map.put(@condition, "label", String.duplicate("é", 101))
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(s in ResultStream, where: s.id == ^row.id),
          set: [condition: invalid]
        )
      end

      assert Repo.get!(ResultStream, row.id).condition == @condition
    end
  end

  test "condition labels use the same ASCII control boundary in the protocol and database" do
    condition = Map.put(@condition, "label", "Orders\u0085storage pressure")
    assert Protocol.condition?(condition)
    assert {:ok, _} = Monitoring.inventory(inventory(condition), at())
    row = stream(assignment())
    assert row.condition == condition

    for codepoint <- Enum.to_list(1..31) ++ [127] do
      invalid = Map.put(condition, "label", "Orders" <> <<codepoint::utf8>> <> "storage")
      refute Protocol.condition?(invalid)

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(s in ResultStream, where: s.id == ^row.id),
          set: [condition: invalid]
        )
      end

      assert Repo.get!(ResultStream, row.id).condition == condition
    end

    refute Protocol.condition?(Map.put(condition, "label", "Orders\0storage"))
  end

  test "impact evidence is bounded, replay-safe and retained through unavailable or stale collection" do
    connect()
    first = put_in(measurement("CRIT"), ["results", Access.at(0), "impacts"], [@impact])
    assert disposition(ingest(first)) == "current"
    assert disposition(ingest(first)) == "duplicate"
    changed = put_in(first, ["results", Access.at(0), "impacts"], [])
    assert disposition(ingest(changed)) == "conflict"

    row =
      Repo.one!(
        from s in ResultStream, where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
      )

    assert row.current["impacts"] == [@impact]

    failed =
      measurement("UNKNOWN", 2, %{"complete" => false})
      |> put_in(["results", Access.at(0), "source_at"], nil)

    assert disposition(ingest(failed)) == "current"
    assert Repo.get!(ResultStream, row.id).current["impacts"] == [@impact]
    assert Repo.get!(ResultStream, row.id).current["execution_impacts"] == []
    assert disposition(ingest(measurement("OK", 3), DateTime.add(at(), 1000))) == "current"
    assert Repo.get!(ResultStream, row.id).current["impacts"] == [@impact]
    recovered_at = DateTime.add(at(), 1001)
    recovered_time = DateTime.to_iso8601(recovered_at)

    recovered =
      measurement("OK", 4, %{"started_at" => recovered_time, "evaluated_at" => recovered_time})
      |> put_in(["results", Access.at(0), "source_at"], recovered_time)

    assert disposition(ingest(recovered, recovered_at)) == "current"
    assert Repo.get!(ResultStream, row.id).current["impacts"] == []
    assert Repo.get!(Observation, first["id"]).payload == first
  end

  test "invalid or contradictory impacts cannot enter the evidence ledger" do
    connect()

    invalids = [
      nil,
      %{},
      [@impact, @impact],
      List.duplicate(@impact, 17),
      [%{"key" => "x"}],
      [Map.put(@impact, "key", "with spaces")],
      [Map.put(@impact, "extra", "field")],
      [Map.put(@impact, "label", String.duplicate(" ", 201) <> "x")],
      [Map.put(@impact, "label", "bad\0label")]
    ]

    for impacts <- invalids do
      report = put_in(measurement("CRIT"), ["results", Access.at(0), "impacts"], impacts)
      assert {:error, {:invalid, _}} = Protocol.report(report, at())
      assert disposition(ingest(report)) == "rejected"
    end

    contradictory = put_in(measurement("OK"), ["results", Access.at(0), "impacts"], [@impact])
    assert disposition(ingest(contradictory)) == "rejected"
    assert Repo.aggregate(Observation, :count) == 0
    maximum = Enum.map(1..16, &Map.put(@impact, "key", "impact-#{&1}"))

    assert :ok =
             Protocol.report(
               put_in(measurement("CRIT"), ["results", Access.at(0), "impacts"], maximum),
               at()
             )
  end

  defp assignment, do: Repo.one!(from a in Assignment, where: a.source_id == "conditions")

  defp stream(a),
    do:
      Repo.one!(from s in ResultStream, where: s.assignment_id == ^a.id and is_nil(s.retired_at))

  defp activate(a), do: connect(%{"prepared" => %{a.id => a.desired_generation}, "active" => %{}})

  defp sample(a, health, sequence),
    do:
      measurement(health, sequence, %{
        "assignment_id" => a.id,
        "generation" => a.desired_generation
      })

  defp inventory(condition, revision \\ 1) do
    output = %{
      "key" => "capacity",
      "label" => "Linux storage pressure",
      "target" => %{"kind" => "volume", "key" => "linux-volume", "label" => "Orders data"}
    }

    output = if condition, do: Map.put(output, "condition", condition), else: output

    control()
    |> Map.merge(%{
      "runner_label" => "Node observer",
      "source_id" => "conditions",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => revision,
      "complete" => true,
      "checks" => [
        %{
          "key" => "linux-disk",
          "label" => "Linux disk",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => "production",
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{}},
          "params" => %{},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [output]
        }
      ]
    })
  end
end
