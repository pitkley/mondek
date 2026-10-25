# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.InventoryTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Inventory, ResultStream, SourceInventory}

  test "a complete source is runner-scoped, idempotent, and fenced across sessions" do
    p = inventory([check("shared")])
    assert {:ok, %{"accepted_checks" => 1}} = Monitoring.inventory(p, at())
    a = source_assignment()
    assert {:ok, _} = Monitoring.inventory(p, DateTime.add(at(), 1))
    assert Repo.get!(Assignment, a.id).revision == 1
    assert Repo.aggregate(SourceInventory, :count) == 1

    assert {:error, :inventory_conflict} =
             Monitoring.inventory(put_in(p, ["checks", Access.at(0), "label"], "Changed"), at())

    second =
      inventory([check("shared")], %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "runner_label" => "Node B"
      })

    assert {:ok, _} = Monitoring.inventory(second, at())

    assert {:ok, response} =
             Monitoring.control(
               control(Map.take(second, ~w(installation_id session_id boot))),
               at()
             )

    assert Enum.count(response["assignments"], &(&1["source_id"] == "source")) == 1
    refute Enum.any?(response["assignments"], &(&1["id"] == a.id))

    restarted = Map.merge(p, %{"boot" => 2, "session_id" => Ecto.UUID.generate()})
    assert {:ok, _} = Monitoring.inventory(restarted, at())

    assert {:error, :session_conflict} =
             Monitoring.inventory(Map.put(p, "inventory_revision", 20), at())

    assert {:ok, _} = Monitoring.inventory(Map.put(restarted, "inventory_revision", 2), at())
    assert {:error, :stale_inventory} = Monitoring.inventory(restarted, at())
  end

  test "independent result details retain their own measurement through sibling failure" do
    assert {:ok, _} = Monitoring.inventory(inventory([check("pair", ["left", "right"])]), at())
    a = source_assignment()
    activate(a)

    first =
      result_report(a, 1, [{"left", "CRIT"}, {"right", "OK"}])
      |> put_in(["results", Access.at(0), "details"], "Left failed\nBackup evidence")
      |> put_in(["results", Access.at(1), "details"], "Right is healthy\nSeparate evidence")

    assert disposition(ingest(first)) == "current"

    partial =
      result_report(a, 2, [{"left", "UNKNOWN"}, {"right", "WARN"}])
      |> Map.put("complete", false)
      |> put_in(["results", Access.at(0), "source_at"], nil)
      |> put_in(["results", Access.at(0), "details"], "Left API unavailable")
      |> put_in(["results", Access.at(1), "details"], "Right measured warning")

    assert disposition(ingest(partial)) == "current"
    left = Repo.get_by!(ResultStream, assignment_id: a.id, result_key: "left")
    right = Repo.get_by!(ResultStream, assignment_id: a.id, result_key: "right")
    assert left.current["details"] == "Left failed\nBackup evidence"
    assert left.current["execution_details"] == "Left API unavailable"
    assert left.current["confirmed_observation_id"] == first["id"]
    assert right.current["details"] == "Right measured warning"
    assert right.current["confirmed_observation_id"] == partial["id"]

    detail = Monitoring.stream_inspection(left.id, at())
    assert Enum.find(detail["evidence"], &(&1["id"] == partial["id"]))["payload"] == partial
    refute Jason.encode!(Repo.all(Occurrence) |> Enum.map(& &1.payload)) =~ "Backup evidence"
  end

  test "a failed or incomplete inventory cannot withdraw accepted membership" do
    p = inventory([check("first"), check("second")])
    assert {:ok, _} = Monitoring.inventory(p, at())

    bad =
      p |> Map.put("inventory_revision", 2) |> Map.put("checks", []) |> Map.put("complete", false)

    assert {:error, {:invalid, _}} = Monitoring.inventory(bad, at())

    assert Repo.aggregate(
             from(a in Assignment, where: a.source_id == "source" and is_nil(a.retired_at)),
             :count
           ) == 2

    assert Repo.one!(SourceInventory).revision == 1

    bad =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("checks", [check("first") |> Map.put("params", %{"limit" => -1})])

    assert {:error, {:invalid, _}} = Monitoring.inventory(bad, at())
    assert Repo.one!(SourceInventory).revision == 1
  end

  test "independent outputs open and recover independently, and partial failure preserves expectation" do
    assert {:ok, _} = Monitoring.inventory(inventory([check("pair", ["left", "right"])]), at())
    a = source_assignment()
    activate(a)
    first = result_report(a, 1, [{"left", "CRIT"}, {"right", "WARN"}])
    assert disposition(ingest(first)) == "current"
    assert Repo.aggregate(Incident, :count) == 2
    left = Repo.get_by!(Incident, assignment_id: a.id, result_key: "left")
    right = Repo.get_by!(Incident, assignment_id: a.id, result_key: "right")
    assert {:ok, _} = reviewed_acknowledgement_fixture(left.id, 60, "Investigating left", at())
    partial = result_report(a, 2, [{"left", "OK"}]) |> Map.put("complete", false)
    assert disposition(ingest(partial)) == "current"
    assert Repo.get!(Incident, left.id).closure_reason == "measured_recovery"
    assert Repo.get!(Incident, right.id).status == "open"

    streams =
      Monitoring.list_streams(%{search: "pair"}, at()).items |> Map.new(&{&1["result_key"], &1})

    assert streams["left"]["current"]["health"] == "OK"
    assert streams["left"]["current"]["knowledge"] == "fresh"
    assert streams["right"]["current"]["health"] == "WARN"
    assert streams["right"]["current"]["knowledge"] == "unavailable"
    assert streams["right"]["current"]["confirmed_observation_id"] == first["id"]
    assert Monitoring.list_streams(%{search: "pair"}, at()).total == 2
    inspection = Monitoring.stream_inspection(streams["right"]["id"], at())
    assert Enum.all?(inspection["incidents"], &(&1["result_key"] == "right"))
    assert Enum.find(inspection["evidence"], &(&1["id"] == first["id"]))["payload"] == first
    assert Monitoring.incident_detail(right.id, at())["stream"]["result_key"] == "right"
    assert Repo.get_by!(Occurrence, incident_id: right.id).payload["result_key"] == "right"
  end

  test "UI values survive source reload, incompatible changes roll back, and source cannot reclaim ownership" do
    p = inventory([check("delegated")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    assert {:ok, _} = Monitoring.save_assignment(a.id, 1, %{"limit" => 75})

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("source_revision", String.duplicate("c", 64))
      |> put_in(["checks", Access.at(0), "params"], %{"limit" => 12})

    assert {:ok, _} = Monitoring.inventory(changed, at())
    a = Repo.get!(Assignment, a.id)
    assert a.params == %{"limit" => 75}
    assert a.desired_generation == 3
    assert {:error, :stale} = Monitoring.save_assignment(a.id, 2, %{"limit" => 60})

    incompatible =
      changed
      |> Map.put("inventory_revision", 3)
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "maximum"], 50)

    assert {:error, {:invalid, _}} = Monitoring.inventory(incompatible, at())
    assert Repo.one!(SourceInventory).revision == 2
    assert Repo.get!(Assignment, a.id).revision == 3

    reclaimed =
      changed
      |> Map.put("inventory_revision", 3)
      |> put_in(["checks", Access.at(0), "params_owner"], "source")

    assert {:error, {:invalid, _}} = Monitoring.inventory(reclaimed, at())
  end

  test "source-owned empty parameters are valid and operator writes cannot change ownership or membership" do
    c =
      check("owned")
      |> Map.merge(%{
        "params_owner" => "source",
        "params" => %{},
        "parameter_schema" => %{"fields" => %{}}
      })

    assert {:ok, _} = Monitoring.inventory(inventory([c]), at())
    a = source_assignment()
    assert {:error, :source_owned} = Monitoring.save_assignment(a.id, 1, %{})

    assert Repo.get!(Assignment, a.id).retired_at == nil
  end

  test "source removal closes every output without measured recovery and reappearance has new identity" do
    p = inventory([check("pair", ["left", "right"])])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    first = result_report(a, 1, [{"left", "CRIT"}, {"right", "WARN"}])
    ingest(first)

    assert {:ok, %{"accepted_checks" => 0}} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "checks" => []}),
               at()
             )

    assert Enum.all?(
             Repo.all(Incident),
             &(&1.status == "closed" and &1.closure_reason == "source_removed" and
                 is_nil(&1.closing_observation_id))
           )

    assert Enum.all?(Repo.all(Occurrence), &(&1.status == "superseded"))

    assert Enum.all?(
             Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id),
             & &1.retired_at
           )

    assert disposition(ingest(first)) == "duplicate"

    assert disposition(ingest(result_report(a, 2, [{"left", "CRIT"}, {"right", "CRIT"}]))) ==
             "historical"

    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 3), at())

    replacement =
      Repo.one!(from a in Assignment, where: a.source_key == "pair" and is_nil(a.retired_at))

    refute replacement.id == a.id
    assert replacement.current == %{}
    assert Monitoring.list_streams(%{search: "pair", status: "all"}, at()).total == 4
    assert Monitoring.list_checks(%{search: "pair", status: "retired"}, at()).total == 1
  end

  test "target changes start a new incarnation while code changes fence recovery classification" do
    p = inventory([check("one")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    ingest(result_report(a, 1, [{"value", "CRIT"}]))

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("source_revision", String.duplicate("c", 64))

    assert {:ok, _} = Monitoring.inventory(changed, at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    ingest(result_report(a, 2, [{"value", "OK"}]))
    assert Repo.one!(Incident).closure_reason == "configuration_changed"

    retarget =
      changed
      |> Map.put("inventory_revision", 3)
      |> put_in(
        ["checks", Access.at(0), "outputs", Access.at(0), "target", "key"],
        "different-host"
      )

    assert {:ok, _} = Monitoring.inventory(retarget, at())
    refute Repo.get!(Assignment, a.id).retired_at

    replacement =
      Repo.one!(from a in Assignment, where: a.source_key == "one" and is_nil(a.retired_at))

    assert replacement.id == a.id
    streams = Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id)
    assert length(streams) == 2
    assert Enum.count(streams, &is_nil(&1.retired_at)) == 1
    assert Enum.find(streams, &is_nil(&1.retired_at)).current == %{}
  end

  test "inventory rejects attempts to adopt an existing identity without changing its evidence" do
    connect()
    first = measurement("CRIT")
    assert disposition(ingest(first)) == "current"
    saved = Repo.get!(Assignment, first["assignment_id"])
    incident = Repo.one!(Incident)
    c = Map.put(check("capacity", ["capacity"]), "adopt_assignment_id", saved.id)
    assert {:error, {:invalid, _}} = Monitoring.inventory(inventory([c]), at())
    assert Repo.get!(Assignment, saved.id) == saved
    assert Repo.one!(Incident) == incident
    assert Repo.get!(Observation, first["id"]).payload == first
    refute Repo.exists?(SourceInventory)
  end

  test "concurrent conflicting inventories commit one complete version without mixed membership" do
    p = inventory([check("first")])
    q = inventory([check("second")])
    results = for payload <- [p, q], do: Task.async(fn -> Monitoring.inventory(payload, at()) end)
    results = Enum.map(results, &Task.await(&1, 15000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :inventory_conflict} in results
    assert Repo.aggregate(from(a in Assignment, where: a.source_id == "source"), :count) == 1
  end

  test "five hundred checks use bounded pages, exact aggregate counts and runner-scoped control" do
    p = inventory(for n <- 1..500, do: check("check-#{String.pad_leading(to_string(n), 3, "0")}"))
    assert {:ok, %{"accepted_checks" => 500}} = Monitoring.inventory(p, at())
    first = Monitoring.list_streams(%{search: "check-", page_size: 37}, at())
    last = Monitoring.list_streams(%{search: "check-", page_size: 37, page: 14}, at())
    assert first.total == 500 and length(first.items) == 37
    assert length(last.items) == 19
    assert last.page == 14
    assert Monitoring.overview(at())["coverage"]["active"] == 503
    assert Monitoring.list_streams(%{search: "no match"}, at()).coverage["active"] == 503

    assert Monitoring.list_checks(%{search: "check-", page_size: 999}, at()).items |> length() ==
             100

    assert {:ok, response} = Monitoring.control(control(), at())
    assert length(response["assignments"]) == 503
    assert byte_size(Jason.encode!(Monitoring.overview(at()))) < 32_768

    assert Enum.all?(
             Monitoring.snapshot(at())["assignment_limits"]
             |> Map.take(["active_returned"])
             |> Map.values(),
             &(&1 <= 100)
           )

    second =
      inventory(Enum.map(1..20, &check("peer-#{&1}")), %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate()
      })

    assert {:ok, %{"accepted_checks" => 20}} = Monitoring.inventory(second, at())

    for view <- [Monitoring.overview(at()), Monitoring.snapshot(at())] do
      assert %{
               "active" => 523,
               "active_limit" => 512,
               "active_limit_scope" => "per_runner"
             } = view["assignment_limits"]
    end
  end

  test "declared 200-byte result keys are reportable and malformed exported scalars are rejected" do
    key = String.duplicate("k", 200)
    assert {:ok, _} = Monitoring.inventory(inventory([check("long", [key])]), at())
    a = source_assignment()
    activate(a)
    assert disposition(ingest(result_report(a, 1, [{key, "OK"}]))) == "current"
    bad = inventory([check("bad")]) |> put_in(["checks", Access.at(0), "label"], "bad" <> <<0>>)
    assert {:error, {:invalid, _}} = Inventory.validate(bad)

    bad =
      inventory([check("bad")])
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "choices"], [true])

    assert {:error, {:invalid, _}} = Inventory.validate(bad)
  end

  test "adding, removing, rebinding and reappearing outputs preserve an unchanged failing sibling" do
    p = inventory([check("pair", ["left", "right"])])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    ingest(result_report(a, 1, [{"left", "CRIT"}, {"right", "WARN"}]))
    left = Repo.get_by!(Incident, assignment_id: a.id, result_key: "left")
    right = Repo.get_by!(Incident, assignment_id: a.id, result_key: "right")
    reviewed_acknowledgement_fixture(left.id, 60, "Keep investigating left", at())

    added =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("checks", [check("pair", ["left", "right", "third"])])

    assert {:ok, _} = Monitoring.inventory(added, at())
    assert Repo.get!(Incident, left.id).status == "open"
    assert Repo.get!(Incident, left.id).stream_id == left.stream_id
    assert Repo.get!(Incident, left.id).acknowledged_until
    # The old generation can still serve unchanged outputs before preparation;
    # the newly declared output is still awaiting its first execution.
    assert disposition(ingest(result_report(a, 2, [{"left", "CRIT"}, {"right", "WARN"}]))) ==
             "current"

    third = Repo.get_by!(ResultStream, assignment_id: a.id, result_key: "third")
    assert third.current == %{}
    a = Repo.get!(Assignment, a.id)
    activate(a)
    ingest(result_report(a, 3, [{"left", "CRIT"}, {"right", "WARN"}, {"third", "CRIT"}]))
    third_incident = Repo.get_by!(Incident, stream_id: third.id)

    removed =
      added
      |> Map.put("inventory_revision", 3)
      |> Map.put("checks", [check("pair", ["left", "third"])])

    assert {:ok, _} = Monitoring.inventory(removed, at())
    assert Repo.get!(Incident, right.id).closure_reason == "source_removed"
    assert Repo.get!(Incident, left.id).status == "open"
    assert Repo.get!(ResultStream, right.stream_id).retired_at
    old_generation = result_report(a, 4, [{"left", "CRIT"}, {"right", "OK"}, {"third", "CRIT"}])
    a = Repo.get!(Assignment, a.id)
    activate(a)
    assert disposition(ingest(old_generation)) == "historical"
    assert Repo.get!(Incident, right.id).closure_reason == "source_removed"

    rebound =
      removed
      |> Map.put("inventory_revision", 4)
      |> put_in(
        ["checks", Access.at(0), "outputs", Access.at(1), "target", "key"],
        "replacement-host"
      )

    assert {:ok, _} = Monitoring.inventory(rebound, at())
    assert Repo.get!(Incident, third_incident.id).closure_reason == "source_removed"

    assert Monitoring.incident_detail(third_incident.id, at())["stream"]["target"]["key"] ==
             "third"

    replacement =
      Repo.one!(
        from s in ResultStream,
          where: s.assignment_id == ^a.id and s.result_key == "third" and is_nil(s.retired_at)
      )

    refute replacement.id == third.id

    assert disposition(ingest(result_report(a, 5, [{"left", "CRIT"}, {"third", "OK"}]))) ==
             "current"

    assert Repo.get!(ResultStream, replacement.id).current == %{}
    assert Repo.get!(Incident, left.id).status == "open"
    assert Monitoring.stream_inspection(left.stream_id, at())["incidents"] |> length() == 1

    reappeared =
      rebound
      |> Map.put("inventory_revision", 5)
      |> Map.put("checks", [check("pair", ["left", "right", "third"])])

    assert {:ok, _} = Monitoring.inventory(reappeared, at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    ingest(result_report(a, 6, [{"left", "CRIT"}, {"right", "WARN"}, {"third", "OK"}]))

    new_right =
      Repo.one!(
        from i in Incident,
          where: i.assignment_id == ^a.id and i.result_key == "right" and i.status == "open"
      )

    refute new_right.stream_id == right.stream_id
    refute new_right.id == right.id
    assert Repo.get!(Incident, left.id).status == "open"
    assert Repo.get!(Incident, left.id).acknowledged_until
    assert Monitoring.list_streams(%{search: "pair"}, at()).total == 3
    assert Monitoring.list_streams(%{search: "pair", status: "retired"}, at()).total == 3
  end

  test "control only returns the requesting runner's source-owned assignments" do
    owner = control()["installation_id"]

    other =
      control(%{"installation_id" => Ecto.UUID.generate(), "session_id" => Ecto.UUID.generate()})

    assert {:ok, %{"assignments" => []}} = Monitoring.control(other, at())
    assert Enum.all?(Repo.all(Assignment), &(&1.runner_id == owner))
    assert {:ok, %{"assignments" => mine}} = Monitoring.control(control(), at())
    assert length(mine) == 3

    assert Enum.all?(
             mine,
             &(&1["kind"] == "python" && &1["source_id"] == "controller-fixture-source")
           )

    assert {:ok, %{"assignments" => []}} = Monitoring.control(other, at())
  end

  test "publishing a new source preserves another source's current and retired membership" do
    id = "10000000-0000-4000-8000-000000000001"
    assert {:ok, _} = withdraw_source_fixture(id, "Intentionally stopped", at())
    retained = Repo.all(from a in Assignment, order_by: a.id)

    assert {:ok, %{"accepted_checks" => 1}} =
             Monitoring.inventory(inventory([check("new-check")]), at())

    for row <- retained, do: assert(Repo.get!(Assignment, row.id) == row)
    assert source_assignment().id not in Enum.map(retained, & &1.id)
    assert {:ok, response} = Monitoring.control(control(), at())
    assert length(response["assignments"]) == 3
    refute Enum.any?(response["assignments"], &(&1["id"] == id))
  end

  test "restoring UI parameters preserves the same recovery contract and selected provenance" do
    assert {:ok, _} = Monitoring.inventory(inventory([check("policy")]), at())
    a = source_assignment()
    activate(a)
    first = result_report(a, 1, [{"value", "CRIT"}])
    ingest(first)
    Monitoring.save_assignment(a.id, 1, %{"limit" => 90})
    Monitoring.save_assignment(a.id, 2, %{"limit" => 80})
    a = Repo.get!(Assignment, a.id)
    activate(a)
    ingest(result_report(a, 2, [{"value", "OK"}]))
    assert Repo.one!(Incident).closure_reason == "measured_recovery"
    stream = Repo.get_by!(ResultStream, assignment_id: a.id)

    assert Monitoring.stream_inspection(stream.id, at())["stream"]["current"]["confirmed_params"] ==
             %{"limit" => 80}
  end

  @tag empty_source_fixture: true
  test "concurrent sources share the durable per-runner capacity without partial admission" do
    assert {:ok, _} =
             Monitoring.inventory(inventory(for n <- 1..511, do: check("capacity-#{n}")), at())

    results =
      for source <- ~w(second third) do
        Task.async(fn ->
          Monitoring.inventory(inventory([check(source)], %{"source_id" => source}), at())
        end)
      end
      |> Enum.map(&Task.await(&1, 15000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:invalid, _}}, &1)) == 1

    assert Repo.aggregate(
             from(a in Assignment, where: a.runner_id == ^control()["installation_id"]),
             :count
           ) == 512

    assert Repo.aggregate(SourceInventory, :count) == 2
    assert {:ok, response} = Monitoring.control(control(), at())
    assert length(response["assignments"]) == 512

    assert Enum.all?(
             Repo.all(from a in Assignment, where: is_nil(a.source_id)),
             &is_nil(&1.runner_id)
           )
  end

  test "same-target reappearance cannot inherit a run from an earlier stream incarnation" do
    p = inventory([check("pair", ["left", "right"])])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    ingest(result_report(a, 1, [{"left", "CRIT"}, {"right", "CRIT"}]))
    old_right = Repo.get_by!(Incident, assignment_id: a.id, result_key: "right")

    assert {:ok, _} =
             Monitoring.inventory(
               p
               |> Map.put("inventory_revision", 2)
               |> Map.put("checks", [check("pair", ["left"])]),
               at()
             )

    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 3), at())

    right =
      Repo.one!(
        from s in ResultStream,
          where: s.assignment_id == ^a.id and s.result_key == "right" and is_nil(s.retired_at)
      )

    assert right.admission_generation == 3
    # Generation one is still authorized. It can advance left, but its right
    # result belongs to the retired incarnation even though the target matches.
    assert disposition(ingest(result_report(a, 2, [{"left", "CRIT"}, {"right", "OK"}]))) ==
             "current"

    assert Repo.get!(ResultStream, right.id).current == %{}
    assert Repo.get!(Incident, old_right.id).closure_reason == "source_removed"
    a = Repo.get!(Assignment, a.id)
    activate(a)

    assert disposition(ingest(result_report(a, 3, [{"left", "CRIT"}, {"right", "WARN"}]))) ==
             "current"

    assert Repo.get_by!(Incident, stream_id: right.id).status == "open"
  end

  test "historical generation membership remains readable after source output replacement" do
    c = check("disk", ["capacity"])
    p = inventory([c])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    old = result_report(a, 1, [{"capacity", "CRIT"}])
    assert disposition(ingest(old)) == "current"
    changed = Map.put(c, "outputs", check("replacement", ["new-capacity"])["outputs"])

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "checks" => [changed]}),
               at()
             )

    assert disposition(ingest(result_report(a, 2, [{"capacity", "OK"}]))) == "historical"
    assert Repo.get!(Observation, old["id"]).payload == old
  end

  test "retired stream and incident inspection cannot attribute a later incarnation's execution" do
    p = inventory([check("rebound")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    first = result_report(a, 1, [{"value", "CRIT"}])
    ingest(first)
    incident = Repo.one!(Incident)
    old_stream = Repo.get!(ResultStream, incident.stream_id)

    rebound =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "replacement")

    assert {:ok, _} = Monitoring.inventory(rebound, at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    second = result_report(a, 2, [{"value", "OK"}])
    ingest(second)
    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 3), at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    third = result_report(a, 3, [{"value", "WARN"}])
    ingest(third)

    for detail <- [
          Monitoring.stream_inspection(old_stream.id, at()),
          Monitoring.incident_detail(incident.id, at())
        ] do
      assert detail["stream"]["target"]["key"] == "value"
      assert detail["stream"]["current"]["observation_id"] == first["id"]
      assert Enum.any?(detail["evidence"], &(&1["id"] == first["id"]))
      refute Enum.any?(detail["evidence"], &(&1["id"] in [second["id"], third["id"]]))
    end
  end

  @tag empty_source_fixture: true
  test "target and source searches agree across result, configuration and incident inspection" do
    definition =
      check("pair", ["left", "right"])
      |> Map.update!("outputs", fn outputs ->
        Enum.map(outputs, fn output ->
          Map.put(output, "target", %{
            "key" => "mount/" <> output["key"],
            "kind" => "filesystem",
            "label" => "Storage vault"
          })
        end)
      end)

    assert {:ok, _} = Monitoring.inventory(inventory([definition]), at())
    a = source_assignment()
    activate(a)
    ingest(result_report(a, 1, [{"left", "CRIT"}, {"right", "WARN"}]))

    assert Monitoring.assignment_inspection(a.id, at())["assignment"]["runner_label"] == "Node A"

    for term <- ["Storage vault", "source"] do
      assert Monitoring.list_streams(%{search: term}, at()).total == 2
      checks = Monitoring.list_checks(%{search: term}, at())
      assert checks.total == 1
      assert Enum.map(checks.items, & &1["id"]) == [a.id]
      assert Monitoring.list_incidents(%{search: term}, at()).total == 2
    end

    assert Monitoring.list_checks(%{search: "mount/left"}, at()).total == 1
    assert Monitoring.list_incidents(%{search: "mount/left"}, at()).total == 1
    assert Monitoring.list_incidents(%{search: "unknown target"}, at()).total == 0
  end

  test "environment IDs separate equal labels and preserve historical grouping through rename" do
    checks =
      for {key, environment} <- [{"north-check", "north"}, {"south-check", "south"}] do
        Map.merge(check(key), %{
          "environment" => environment,
          "environment_label" => "Production"
        })
      end

    p = inventory(checks)
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = Repo.get_by!(Assignment, source_key: "north-check")
    activate(a)
    ingest(result_report(a, 1, [{"value", "CRIT"}]))
    incident = Repo.one!(Incident)
    stream = Repo.get!(ResultStream, incident.stream_id)

    assert Monitoring.list_streams(%{}, at()).facets["environments"] == [
             %{"id" => "north", "label" => "Production"},
             %{"id" => "south", "label" => "Production"}
           ]

    for environment <- ["north", "south"] do
      assert Monitoring.list_streams(%{environment: environment}, at()).total == 1
      assert Monitoring.list_checks(%{environment: environment}, at()).total == 1
    end

    renamed =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "environment_label"], "Primary production")

    assert {:ok, _} = Monitoring.inventory(renamed, at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    ingest(result_report(a, 2, [{"value", "CRIT"}]))
    current = Monitoring.stream_inspection(stream.id, at())["stream"]
    assert current["environment"] == "north"
    assert current["environment_label"] == "Primary production"
    assert Repo.one!(Incident).id == incident.id

    assert Monitoring.incident_detail(incident.id, at())["incident"]["environment_label"] ==
             "Production"

    rebound =
      renamed
      |> Map.put("inventory_revision", 3)
      |> put_in(["checks", Access.at(0), "environment"], "replacement")
      |> put_in(["checks", Access.at(0), "environment_label"], "Replacement site")
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "new-target")

    assert {:ok, _} = Monitoring.inventory(rebound, at())
    retired = Monitoring.stream_inspection(stream.id, at())["stream"]
    assert retired["environment"] == "north"
    assert retired["environment_label"] == "Primary production"
    assert Monitoring.list_streams(%{environment: "north", status: "retired"}, at()).total == 1
    assert Monitoring.list_streams(%{environment: "replacement"}, at()).total == 1
    assert Monitoring.list_incidents(%{environment: "north", status: "closed"}, at()).total == 1

    assert Monitoring.list_incidents(%{environment: "replacement", status: "all"}, at()).total ==
             0
  end

  test "environment display labels are bounded and require stable IDs" do
    p = inventory([check("sample")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert source_assignment().environment_label == "local"

    for invalid <- [
          check("sample") |> Map.put("environment_label", String.duplicate("x", 201)),
          check("sample") |> Map.delete("environment") |> Map.put("environment_label", "Orphan")
        ] do
      assert {:error, {:invalid, _}} =
               Monitoring.inventory(
                 Map.merge(p, %{"inventory_revision" => 2, "checks" => [invalid]}),
                 at()
               )
    end

    assert source_assignment().environment_label == "local"
    assert Repo.one!(SourceInventory).revision == 1
  end

  test "changing only the monitored environment creates a new result incarnation and maintenance scope" do
    p = inventory([check("sample")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)
    assert disposition(ingest(result_report(a, 1, [{"value", "CRIT"}]))) == "current"
    old = Repo.one!(from s in ResultStream, where: s.assignment_id == ^a.id)
    old_incident = Repo.one!(Incident)

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "environment"], "replacement")

    assert {:ok, _} = Monitoring.inventory(changed, at())
    assert Repo.get!(ResultStream, old.id).retired_at
    assert Repo.get!(ResultStream, old.id).environment == "local"
    assert Repo.get!(Incident, old_incident.id).closure_reason == "source_removed"

    current =
      Repo.one!(from s in ResultStream, where: s.assignment_id == ^a.id and is_nil(s.retired_at))

    assert current.id != old.id
    assert current.environment == "replacement"
    assert current.current == %{}

    assert {:ok, seed} = Mondek.Maintenance.seed(a.id, current.id, at())
    assert seed["proposal"]["environment"] == "replacement"
    proposal = Map.put(seed["proposal"], "reason", "Replacement environment deployment")
    assert {:ok, preview} = Mondek.Maintenance.preview(proposal, 1, at())
    assert {:ok, _} = Mondek.Maintenance.apply(preview["review_token"], proposal, at())
    a = Repo.get!(Assignment, a.id)
    activate(a)
    assert disposition(ingest(result_report(a, 2, [{"value", "CRIT"}]))) == "current"
    incident = Repo.one!(from i in Incident, where: i.status == "open")
    assert incident.stream_id == current.id
    assert incident.environment == "replacement"
    occurrence = Repo.get_by!(Occurrence, incident_id: incident.id, kind: "firing")
    assert {:ok, {:gated, _}} = Mondek.NotificationWorker.begin_attempt(occurrence.id, at())
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "an authorized run uses its recorded environment before a renamed definition activates" do
    p = inventory([Map.put(check("sample"), "environment_label", "Original site")])
    assert {:ok, _} = Monitoring.inventory(p, at())
    a = source_assignment()
    activate(a)

    renamed =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "environment_label"], "Renamed site")

    assert {:ok, _} = Monitoring.inventory(renamed, at())
    assert disposition(ingest(result_report(a, 1, [{"value", "CRIT"}]))) == "current"
    assert Repo.one!(Incident).environment_label == "Original site"
    assert Repo.one!(Occurrence).payload["environment_label"] == "Original site"

    assert Repo.one!(from(s in ResultStream, where: s.assignment_id == ^a.id)).environment_label ==
             "Renamed site"

    a = source_assignment()
    activate(a)
    ingest(result_report(a, 2, [{"value", "OK"}]))
    assert Repo.one!(Incident).closure_reason == "measured_recovery"
  end

  test "shared check-group admission corpus rejects malformed metadata" do
    cases = File.read!("../contracts/v1/check-groups.json") |> Jason.decode!()

    for example <- cases do
      declaration = check("group-contract")
      output = hd(declaration["outputs"]) |> Map.merge(example["output"])
      payload = inventory([%{declaration | "outputs" => [output]}])
      result = Inventory.validate(payload)
      assert result == :ok == example["valid"], example["name"]
    end
  end

  test "renaming, moving and removing a group preserves measurements and acknowledged incidents" do
    original = check("stable")

    grouped =
      put_in(original, ["outputs", Access.at(0), "group"], %{"key" => "host", "label" => "Host"})

    assert {:ok, _} = Monitoring.inventory(inventory([grouped]), at())
    assignment = source_assignment()
    activate(assignment)
    report = result_report(assignment, 1, [{"value", "CRIT"}])
    assert disposition(ingest(report)) == "current"
    stream = Repo.get_by!(ResultStream, assignment_id: assignment.id)
    incident = Repo.one!(Incident)
    assert {:ok, _} = reviewed_acknowledgement_fixture(incident.id, 3600, "Investigating", at())
    acknowledged = Repo.get!(Incident, incident.id)

    for {group, revision} <- [
          {%{"key" => "host", "label" => "Renamed"}, 2},
          {%{"key" => "misc", "label" => "Misc"}, 3},
          {nil, 4}
        ] do
      declaration =
        if group, do: put_in(original, ["outputs", Access.at(0), "group"], group), else: original

      assert {:ok, _} =
               Monitoring.inventory(
                 inventory([declaration], %{"inventory_revision" => revision}),
                 at()
               )

      retained = Repo.get!(ResultStream, stream.id)
      assert retained.check_group == group
      assert retained.current == stream.current
      assert retained.retired_at == nil
      assert Repo.get!(Incident, incident.id) == acknowledged
      assert Repo.get!(Assignment, assignment.id).params == assignment.params

      assert Repo.aggregate(
               from(s in ResultStream, where: s.assignment_id == ^assignment.id),
               :count
             ) == 1
    end
  end

  defp source_assignment, do: Repo.one!(from a in Assignment, where: a.source_id == "source")
  defp activate(a), do: connect(%{"prepared" => %{a.id => a.desired_generation}, "active" => %{}})

  defp inventory(checks, overrides \\ %{}) do
    control()
    |> Map.merge(%{
      "runner_label" => "Node A",
      "source_id" => "source",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => checks
    })
    |> Map.merge(overrides)
  end

  defp check(key, outputs \\ ["value"]) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "local",
      "params_owner" => "ui",
      "parameter_schema" => %{
        "fields" => %{"limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
      },
      "params" => %{"limit" => 80},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" =>
        Enum.map(outputs, fn output ->
          %{
            "key" => output,
            "label" => key <> " result",
            "target" => %{"key" => output, "kind" => "host", "label" => "Local host"}
          }
        end)
    }
  end

  defp result_report(a, sequence, results) do
    measurement("OK", sequence, %{
      "assignment_id" => a.id,
      "generation" => a.desired_generation,
      "results" =>
        Enum.map(results, fn {key, health} ->
          %{
            "key" => key,
            "health" => health,
            "summary" => key <> " " <> health,
            "value" => 1,
            "source_at" => "2009-09-15T08:00:00.010000Z"
          }
        end)
    })
  end
end
