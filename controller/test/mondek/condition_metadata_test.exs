# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionMetadataTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Configuration, Protocol, ResultStream, SourceInventory}
  alias Mondek.Repo.Migrations.LinkConditionMeasurementHistory

  @endpoint MondekWeb.Endpoint

  unless Code.ensure_loaded?(LinkConditionMeasurementHistory) do
    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20261121120000_link_condition_measurement_history.exs",
        __DIR__
      )
    )
  end

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

  test "timeline follows Condition addition, change, removal and reintroduction on the same output" do
    assert {:ok, _} = Monitoring.inventory(inventory(nil), at())
    original = stream(assignment())
    activate(assignment())
    first = timeline_sample(assignment(), "Originally ungrouped", 1, 0)
    assert disposition(ingest(first, at())) == "current"

    assert {:ok, _} = Monitoring.inventory(inventory(@condition, 2), at())
    grouped = stream(assignment())
    assert grouped.predecessor_stream_id == original.id
    grouped_assignment = assignment()
    activate(grouped_assignment)
    second = timeline_sample(grouped_assignment, "Original Condition", 2, 1)
    assert disposition(ingest(second, DateTime.add(at(), 1))) == "current"

    renamed = Map.put(@condition, "label", "Readable label")
    assert {:ok, _} = Monitoring.inventory(inventory(renamed, 3), at())
    assert stream(assignment()).id == grouped.id

    changed = Map.put(@condition, "key", "orders:availability")
    assert {:ok, _} = Monitoring.inventory(inventory(changed, 4), at())
    changed_stream = stream(assignment())
    assert changed_stream.predecessor_stream_id == grouped.id
    activate(assignment())
    third = timeline_sample(assignment(), "Changed Condition", 3, 2)
    assert disposition(ingest(third, DateTime.add(at(), 2))) == "current"

    later = timeline_sample(grouped_assignment, "Delayed historical receipt", 4, 3)
    assert disposition(ingest(later, DateTime.add(at(), 3))) == "historical"

    assert {:ok, _} = Monitoring.inventory(inventory(nil, 5), at())
    ungrouped = stream(assignment())
    assert ungrouped.predecessor_stream_id == changed_stream.id
    assert {:ok, _} = Monitoring.inventory(inventory(@condition, 6), at())
    current = stream(assignment())
    assert current.predecessor_stream_id == ungrouped.id

    detail = Monitoring.stream_inspection(current.id, DateTime.add(at(), 4))
    assert detail["incidents"] == []
    assert detail["controls"] == []
    assert detail["evidence"] == []

    assert Enum.map(
             detail["measurement_history"],
             &{&1["stream_id"], &1["observation_id"], &1["generation"]}
           ) ==
             [
               {grouped.id, later["id"], 2},
               {changed_stream.id, third["id"], 4},
               {grouped.id, second["id"], 2},
               {original.id, first["id"], 1}
             ]

    assert Mondek.Inspection.stream_inspection(original.id, at())["measurement_history"]
           |> Enum.map(& &1["observation_id"]) == [first["id"]]

    conn = get(build_conn(), "/api/v1/results/#{current.id}/inspection")

    assert json_response(conn, 200)["data"]["measurement_history"] ==
             detail["measurement_history"]

    previous = hd(detail["measurement_history"])
    assert previous["disposition"] == "historical"

    assert json_response(get(build_conn(), previous["evidence_path"]), 200)["data"]["id"] ==
             later["id"]

    scoped = get(build_conn(), "/api/v1/results/#{current.id}/evidence/#{later["id"]}")
    assert scoped.status == 404

    for path <- ["/results/#{current.id}", "/results/#{current.id}/full"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "[id$='preview-result-history']", "Delayed historical receipt")
      assert has_element?(view, "[id$='preview-result-history']", "Historical receipt")

      for {ancestor, generation} <- [{grouped.id, 2}, {changed_stream.id, 4}] do
        assert has_element?(
                 view,
                 "[id$='preview-result-history'] a[href='/results/#{ancestor}/full']",
                 "Previous stream · Generation #{generation}"
               )
      end

      assert has_element?(
               view,
               "[id$='preview-result-history'] a[href='/results/#{ungrouped.id}/full']",
               "View preceding result stream"
             )
    end
  end

  test "rebinds and output withdrawal break measurement continuity" do
    initial = inventory(@condition) |> with_sibling()
    assert {:ok, _} = Monitoring.inventory(initial, at())
    original = timeline_stream()

    changed = Map.put(@condition, "key", "change-with-target")

    rebound =
      inventory(changed, 2)
      |> with_sibling()
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "new-target")

    assert {:ok, _} = Monitoring.inventory(rebound, at())
    target_stream = timeline_stream()
    refute target_stream.predecessor_stream_id
    refute target_stream.id == original.id

    changed = Map.put(changed, "key", "change-with-environment")

    environment =
      rebound
      |> Map.put("inventory_revision", 3)
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "condition"], changed)
      |> put_in(["checks", Access.at(0), "environment"], "staging")

    assert {:ok, _} = Monitoring.inventory(environment, at())
    environment_stream = timeline_stream()
    refute environment_stream.predecessor_stream_id
    refute environment_stream.id == target_stream.id

    removed =
      environment
      |> Map.put("inventory_revision", 4)
      |> update_in(["checks", Access.at(0), "outputs"], &tl/1)

    assert {:ok, _} = Monitoring.inventory(removed, at())
    assert {:ok, _} = Monitoring.inventory(Map.put(environment, "inventory_revision", 5), at())
    refute timeline_stream().predecessor_stream_id
    refute timeline_stream().id == environment_stream.id
  end

  test "sibling-only receipts cannot consume the measurement timeline budget" do
    assert {:ok, _} = Monitoring.inventory(with_sibling(inventory(nil)), at())
    current = assignment()
    activate(current)
    stream = timeline_stream()
    first = timeline_sample(current, "Still inspectable after sibling activity", 1, 0, false)
    assert disposition(ingest(first)) == "current"

    for id <- 2..16 do
      receipt = DateTime.add(at(), id)

      sibling =
        timeline_sample(current, "Sibling only", id, id, false)
        |> put_in(["results", Access.at(0), "key"], "side")

      assert disposition(ingest(sibling, receipt)) == "current"
    end

    detail = Monitoring.stream_inspection(stream.id, DateTime.add(at(), 17))
    assert Enum.map(detail["measurement_history"], & &1["observation_id"]) == [first["id"]]
    assert length(detail["evidence"]) > length(detail["measurement_history"])
  end

  test "backfill requires adjacent scope plus recorded Condition-change audit" do
    assert {:ok, _} = Monitoring.inventory(inventory(nil), at())
    original = timeline_stream()
    assert {:ok, _} = Monitoring.inventory(inventory(@condition, 2), at())
    continuous = timeline_stream()

    rebound =
      inventory(nil, 3)
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "unrelated")

    assert {:ok, _} = Monitoring.inventory(rebound, at())
    unrelated = timeline_stream()
    Repo.update_all(ResultStream, set: [predecessor_stream_id: nil])

    Repo.query!(LinkConditionMeasurementHistory.backfill_sql())
    assert Repo.get!(ResultStream, continuous.id).predecessor_stream_id == original.id
    refute Repo.get!(ResultStream, unrelated.id).predecessor_stream_id

    Repo.update_all(ResultStream, set: [predecessor_stream_id: nil])

    Repo.delete_all(
      from c in Mondek.Control,
        where: c.stream_id == ^original.id and c.kind == "condition_changed"
    )

    Repo.query!(LinkConditionMeasurementHistory.backfill_sql())
    refute Repo.get!(ResultStream, continuous.id).predecessor_stream_id
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

  defp timeline_stream do
    owner = assignment()

    Repo.one!(
      from s in ResultStream,
        where:
          s.assignment_id == ^owner.id and s.result_key == "capacity" and is_nil(s.retired_at)
    )
  end

  defp timeline_sample(owner, summary, sequence, offset, complete \\ true) do
    stamp = at() |> DateTime.add(offset) |> DateTime.to_iso8601()

    sample(owner, "OK", sequence)
    |> Map.merge(%{"complete" => complete, "started_at" => stamp, "evaluated_at" => stamp})
    |> put_in(["results", Access.at(0), "source_at"], stamp)
    |> put_in(["results", Access.at(0), "summary"], summary)
  end

  defp with_sibling(inventory) do
    update_in(inventory, ["checks", Access.at(0), "outputs"], fn [first] ->
      [first, first |> Map.delete("condition") |> Map.put("key", "side")]
    end)
  end

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
