# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.OutputSustainTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Mondek.{
    ConditionIncident,
    Configuration,
    Inventory,
    ResultStream,
    SourceInventory,
    Sweeper
  }

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture
  @base ~U[2026-11-21 08:00:00.000000Z]
  @vectors Path.expand("../../../contracts/v1/output-sustain.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "shared policy corpus and zero canonicalization preserve inventory replay" do
    for example <- @vectors["policy"] do
      declaration = declaration("link", %{})
      output = declaration["outputs"] |> hd() |> Map.merge(example["output"])
      payload = inventory([%{declaration | "outputs" => [output]}])
      assert Inventory.validate(payload) == :ok == example["valid"], example["name"]
    end

    assert {:ok, _} = Monitoring.inventory(inventory([declaration("link", %{})]), @base)
    zero = declaration("link", %{"sustain_seconds" => 0})
    source = Repo.one!(SourceInventory)
    Monitoring.change(source, %{payload: Map.put(source.payload, "checks", [zero])})
    assignment = Repo.one!(Assignment)
    Monitoring.change(assignment, %{outputs: zero["outputs"]})
    assert {:ok, _} = Monitoring.inventory(inventory([zero]), @base)
    newer = inventory([declaration("link", %{})]) |> Map.put("inventory_revision", 2)
    assert {:ok, _} = Monitoring.inventory(newer, @base)
    assert Repo.one!(Assignment).desired_generation == 1
  end

  test "pre-upgrade definitions with a previously ignored sustain field remain safe" do
    plain = declaration("link", %{})
    assert {:ok, _} = Monitoring.inventory(inventory([plain]), @base)
    assignment = Repo.one!(Assignment)
    configuration = Repo.one!(Configuration)
    arbitrary = declaration("link", %{"sustain_seconds" => "previously ignored"})

    Monitoring.change(configuration, %{
      definition: Map.put(configuration.definition, "outputs", arbitrary["outputs"])
    })

    assert {:ok, _} = activate([assignment], @base)
    first = sample_report(assignment, 1, @base, reported("health", "CRIT", @base, []))
    assert disposition(ingest(first, @base)) == "current"
    assert Repo.one!(Incident).opening_observation_id == first["id"]
  end

  test "durable application agrees with exact timing and impact vectors" do
    vectors = @vectors["qualification"]
    sequences = Enum.with_index(vectors["sequences"], 1)

    checks =
      for {_sequence, index} <- sequences do
        declaration("link-#{index}", %{"sustain_seconds" => vectors["sustain_seconds"]})
      end

    assert {:ok, _} = Monitoring.inventory(inventory(checks), @base)
    assignments = Map.new(Repo.all(Assignment), &{&1.source_key, &1})
    assert {:ok, _} = activate(Repo.all(Assignment), @base)

    for {sequence, index} <- sequences do
      assignment = assignments["link-#{index}"]
      stream = Repo.get_by!(ResultStream, assignment_id: assignment.id)

      Enum.reduce(Enum.with_index(sequence["samples"], 1), %{}, fn {sample, id}, reports ->
        receipt = tick(sample["receipt_us"])
        source = sample["source_us"] && tick(sample["source_us"])
        result = reported("health", sample["reported"], source, sample["impacts"] || [])
        report = sample_report(assignment, id, receipt, result)
        assert disposition(ingest(report, receipt)) == "current", sequence["name"]
        assert Repo.get!(Observation, report["id"]).payload == report
        reports = Map.put(reports, id, report["id"])
        detail = Mondek.Inspection.stream_detail(stream.id, receipt)
        qualification = detail["qualification"]

        assert get_in(List.last(qualification["pending"]), ["health"]) ==
                 sample["pending"]

        assert qualification["effective_health"] == sample["effective"]
        assert qualification["effective_observation_id"] == reports[sample["evidence"]]

        incident = Repo.get_by(Incident, stream_id: stream.id)

        if sample["effective"] in ["WARN", "CRIT"] do
          assert incident.health == sample["effective"]
          assert incident.latest_failure_observation_id == reports[sample["evidence"]]

          if sample["effective_impacts"],
            do: assert(Enum.map(incident.impacts, & &1["key"]) == sample["effective_impacts"])
        else
          if sample["effective"] == "OK",
            do: assert(incident.status == "closed"),
            else: refute(incident)
        end

        if index == 1 do
          case id do
            4 ->
              assert {:ok, _} =
                       reviewed_acknowledgement_fixture(incident.id, 60, "Known link", receipt)

            5 ->
              assert Monitoring.acknowledgement_active?(incident, receipt)

            6 ->
              refute Monitoring.acknowledgement_active?(incident, receipt)

            _ ->
              :ok
          end
        end

        reports
      end)
    end
  end

  test "partial collection qualifies a valid grouped output and never supplies the absent sibling" do
    condition = %{"namespace" => "network", "key" => "link", "label" => "Link"}
    grouped = %{"sustain_seconds" => 5, "condition" => condition}
    check = declaration("link", grouped)
    sibling = hd(check["outputs"]) |> Map.put("key", "sibling") |> Map.delete("condition")
    check = Map.update!(check, "outputs", &(&1 ++ [sibling]))
    assert {:ok, _} = Monitoring.inventory(inventory([check]), @base)
    assignment = Repo.one!(Assignment)
    assert {:ok, _} = activate([assignment], @base)

    for {id, seconds} <- [{1, 0}, {2, 5}] do
      stamp = tick(seconds * 1_000_000)
      results = reported("health", "CRIT", stamp, [])

      assert disposition(ingest(sample_report(assignment, id, stamp, results, false), stamp)) ==
               "current"

      assert Repo.aggregate(ConditionIncident, :count) == id - 1
    end

    assert Repo.one!(ConditionIncident).health == "CRIT"
    assert Repo.get_by!(ResultStream, result_key: "sibling").sustain["effective_health"] == nil
    assert Repo.get!(Assignment, assignment.id).observed_generation == nil
  end

  test "an expired candidate stays cleared after retention and a clock rollback" do
    check = declaration("link", %{"sustain_seconds" => 5})
    assert {:ok, _} = Monitoring.inventory(inventory([check]), @base)
    assignment = Repo.one!(Assignment)
    assert {:ok, _} = activate([assignment], @base)

    for {id, delta} <- [{1, 0}, {2, 2_000_000}] do
      stamp = tick(delta)

      assert disposition(
               ingest(
                 sample_report(assignment, id, stamp, reported("health", "WARN", stamp, [])),
                 stamp
               )
             ) == "current"
    end

    stream = Repo.one!(ResultStream)
    first = stream.sustain["warn"]["observation_id"]
    assert {:ok, _} = Sweeper.sweep(tick(11_999_999), 10)
    assert Repo.get!(ResultStream, stream.id).sustain["warn"]["observation_id"] == first
    assert {:ok, _} = Sweeper.sweep(tick(12_000_000), 10)
    refute Repo.get!(ResultStream, stream.id).sustain["warn"]

    rolled_back = tick(5_000_000)

    sample =
      sample_report(assignment, 3, rolled_back, reported("health", "WARN", rolled_back, []))

    assert disposition(ingest(sample, rolled_back)) == "current"
    refute Repo.one(Incident)
    assert Repo.get!(ResultStream, stream.id).sustain["warn"]["observation_id"] == sample["id"]
  end

  test "a changed desired freshness leaves authorized continuity intact until adoption" do
    check = declaration("link", %{"sustain_seconds" => 5})
    payload = inventory([check])
    assert {:ok, _} = Monitoring.inventory(payload, @base)
    old = Repo.one!(Assignment)
    assert {:ok, _} = activate([old], @base)
    first = sample_report(old, 1, @base, reported("health", "WARN", @base, []))
    assert disposition(ingest(first, @base)) == "current"

    updated =
      payload
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "freshness_seconds"], 1)

    assert {:ok, _} = Monitoring.inventory(updated, tick(1_000_000))

    pending =
      sample_report(old, 2, tick(4_000_000), reported("health", "WARN", tick(2_000_000), []))

    assert disposition(ingest(pending, tick(4_000_000))) == "current"
    stream = Repo.one!(ResultStream)
    assert stream.sustain["warn"]["observation_id"] == first["id"]
    assert stream.current["knowledge"] == "stale"

    # The qualified previous-generation timer cannot cross the new authority fence.
    new = Repo.one!(Assignment)
    assert {:ok, _} = activate([new], tick(4_000_000))

    assert Mondek.Inspection.stream_detail(stream.id, tick(4_000_000))["qualification"]["pending"] ==
             []

    fenced =
      sample_report(old, 3, tick(5_000_000), reported("health", "WARN", tick(5_000_000), []))

    assert disposition(ingest(fenced, tick(5_000_000))) == "historical"
    assert disposition(ingest(first, tick(5_000_000))) == "duplicate"

    fresh =
      sample_report(new, 4, tick(5_000_000), reported("health", "WARN", tick(5_000_000), []))

    assert disposition(ingest(fresh, tick(5_000_000))) == "current"
    assert Repo.get!(ResultStream, stream.id).sustain["warn"]["observation_id"] == fresh["id"]
    refute Repo.one(Incident)
  end

  test "disabling sustain keeps prior qualified evidence until a fresh authorized result" do
    check = declaration("link", %{"sustain_seconds" => 5})
    payload = inventory([check])
    assert {:ok, _} = Monitoring.inventory(payload, @base)
    old = Repo.one!(Assignment)
    assert {:ok, _} = activate([old], @base)

    for {id, verdict, stamp} <- [{1, "OK", @base}, {2, "CRIT", tick(1_000_000)}] do
      assert disposition(
               ingest(
                 sample_report(old, id, stamp, reported("health", verdict, stamp, [])),
                 stamp
               )
             ) == "current"
    end

    stream = Repo.one!(ResultStream)
    assert stream.sustain["effective_health"] == "OK"

    assert {:ok, _} =
             Monitoring.inventory(
               payload
               |> Map.put("inventory_revision", 2)
               |> Map.put("checks", [declaration("link", %{})]),
               tick(2_000_000)
             )

    new = Repo.one!(Assignment)
    assert {:ok, _} = activate([new], tick(3_000_000))
    unavailable = sample_report(new, 3, tick(3_000_000), reported("health", "UNKNOWN", nil, []))
    assert disposition(ingest(unavailable, tick(3_000_000))) == "current"
    qualified = Mondek.Inspection.stream_detail(stream.id, tick(3_000_000))["qualification"]
    assert qualified["effective_health"] == "OK"
    assert qualified["pending"] == []
    refute Repo.one(Incident)

    fresh =
      sample_report(new, 4, tick(4_000_000), reported("health", "CRIT", tick(4_000_000), []))

    assert disposition(ingest(fresh, tick(4_000_000))) == "current"
    assert Repo.one!(Incident).opening_observation_id == fresh["id"]
    assert Repo.get!(ResultStream, stream.id).sustain == %{}
  end

  test "session replacement fences pending continuity while retaining qualified evidence" do
    check = declaration("link", %{"sustain_seconds" => 5})
    assert {:ok, _} = Monitoring.inventory(inventory([check]), @base)
    assignment = Repo.one!(Assignment)
    assert {:ok, _} = activate([assignment], @base)
    healthy = sample_report(assignment, 1, @base, reported("health", "OK", @base, []))
    assert disposition(ingest(healthy, @base)) == "current"

    pending =
      sample_report(
        assignment,
        2,
        tick(1_000_000),
        reported("health", "WARN", tick(1_000_000), [])
      )

    assert disposition(ingest(pending, tick(1_000_000))) == "current"
    stream = Repo.one!(ResultStream)

    session = %{"session_id" => Ecto.UUID.generate()}

    assert {:ok, _} =
             Monitoring.control(
               control(Map.merge(session, %{"boot" => 2, "prepared" => %{assignment.id => 1}})),
               tick(4_000_000)
             )

    qualified = Mondek.Inspection.stream_detail(stream.id, tick(4_000_000))["qualification"]
    assert qualified["pending"] == []
    assert qualified["effective_observation_id"] == healthy["id"]

    missing_runner =
      Mondek.OutputSustain.public(
        Repo.get!(ResultStream, stream.id),
        assignment,
        nil,
        tick(4_000_000)
      )

    assert missing_runner["pending"] == []
    assert missing_runner["effective_observation_id"] == healthy["id"]

    next =
      sample_report(
        assignment,
        3,
        tick(6_000_000),
        reported("health", "WARN", tick(6_000_000), [])
      )
      |> Map.merge(session)

    assert disposition(Monitoring.ingest(envelope([next], session), tick(6_000_000))) == "current"
    assert Repo.get!(ResultStream, stream.id).sustain["warn"]["observation_id"] == next["id"]
    refute Repo.one(Incident)
  end

  test "both retention limits preserve active candidate and effective observation references" do
    previous = Application.get_env(:mondek, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mondek, :retention, previous),
        else: Application.delete_env(:mondek, :retention)
    end)

    check = declaration("link", %{"sustain_seconds" => 5})
    assert {:ok, _} = Monitoring.inventory(inventory([check]), @base)
    assignment = Repo.one!(Assignment)
    assert {:ok, _} = activate([assignment], @base)

    for {id, verdict} <- [{1, "OK"}, {2, "WARN"}, {3, "WARN"}, {4, "WARN"}] do
      stamp = tick(id * 1_000_000)

      assert disposition(
               ingest(
                 sample_report(assignment, id, stamp, reported("health", verdict, stamp, [])),
                 stamp
               )
             ) == "current"
    end

    stream = Repo.one!(ResultStream)

    for policy <- [
          %{receipt_days: 0, max_observations: 100},
          %{receipt_days: 7, max_observations: 1}
        ] do
      Application.put_env(:mondek, :retention, Map.put(policy, :history_days, 30))
      assert {:ok, _} = Sweeper.sweep(tick(5_000_000), 10)
      assert Repo.get!(Observation, stream.sustain["warn"]["observation_id"])
      assert Repo.get!(Observation, stream.sustain["effective_observation_id"])
      assert Repo.aggregate(Observation, :count) == 3
    end
  end

  test "result fly-over and full page show the same qualified and raw state" do
    now = DateTime.utc_now()
    check = declaration("link", %{"sustain_seconds" => 5}) |> Map.put("freshness_seconds", 600)
    assert {:ok, _} = Monitoring.inventory(inventory([check]), now)
    assignment = Repo.one!(Assignment)
    assert {:ok, _} = activate([assignment], now)
    first = sample_report(assignment, 1, now, reported("health", "CRIT", now, []))
    assert disposition(ingest(first, now)) == "current"
    stream = Repo.one!(ResultStream)

    for path <- ["/results/#{stream.id}", "/results/#{stream.id}/full"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, ".preview-result-measurement", "Critical")
      assert has_element?(view, "[id$='result-qualified-health']", "Awaiting qualification")
      assert has_element?(view, "[data-sustain-severity='CRIT']", "Critical · 5 s")
    end

    conn = get(build_conn(), "/api/v1/results/#{stream.id}/inspection")

    assert %{"current" => %{"health" => "CRIT"}, "qualification" => %{"effective_health" => nil}} =
             json_response(conn, 200)["data"]["stream"]
  end

  defp tick(microseconds), do: DateTime.add(@base, microseconds, :microsecond)

  defp declaration(key, attrs) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "interval_seconds" => 1,
      "timeout_seconds" => 1,
      "freshness_seconds" => @vectors["qualification"]["freshness_seconds"],
      "outputs" => [
        Map.merge(
          %{
            "key" => "health",
            "label" => "Link health",
            "target" => %{"key" => key, "kind" => "host", "label" => key}
          },
          attrs
        )
      ]
    }
  end

  defp inventory(checks) do
    Map.merge(control(), %{
      "runner_label" => "Link observer",
      "source_id" => "network",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => checks
    })
  end

  defp activate(assignments, stamp) do
    prepared = Map.new(assignments, &{&1.id, &1.desired_generation})
    Monitoring.control(control(%{"prepared" => prepared, "active" => %{}}), stamp)
  end

  defp reported(_, nil, _, _), do: []

  defp reported(key, health, source, impacts) do
    [
      %{
        "key" => key,
        "health" => health,
        "summary" => "Link sample",
        "source_at" => source && DateTime.to_iso8601(source),
        "impacts" => Enum.map(impacts, &%{"key" => &1, "label" => &1})
      }
    ]
  end

  defp sample_report(a, sequence, receipt, results, complete \\ true) do
    source = results |> List.first(%{}) |> Map.get("source_at")

    evaluation =
      if source && DateTime.after?(Monitoring.parse!(source), receipt),
        do: source,
        else: DateTime.to_iso8601(receipt)

    report(%{
      "id" => Ecto.UUID.generate(),
      "sequence" => sequence,
      "assignment_id" => a.id,
      "generation" => a.desired_generation,
      "started_at" => evaluation,
      "evaluated_at" => evaluation,
      "complete" => complete and results != [],
      "results" => results
    })
  end
end
