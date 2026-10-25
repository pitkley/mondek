# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceSelectionTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    Maintenance,
    MaintenanceWindow,
    MaintenanceEvent,
    ResultStream,
    NotificationWorker,
    Sweeper
  }

  test "a canonical selection is one deduplicated union with per-selector counts and one audit" do
    {_input, [first, second]} = inventory(2)
    target = target(first)
    check = check(first)
    p = proposal([target, check, target])
    assert {:ok, review} = Maintenance.preview(p, 1, at())
    assert review["counts"] == %{"matched_results" => 3, "matched_checks" => 2}
    assert length(review["proposal"]["selections"]) == 2
    assert Enum.sort(Enum.map(review["selection_summary"], & &1["matched_results"])) == [2, 2]

    assert Enum.find(review["selection_summary"], &(&1["scope"] == "check"))["check_label"] ==
             first.label

    assert Enum.find(review["selection_summary"], &(&1["scope"] == "target"))["target_label"] ==
             "Orders volume"

    assert {:ok, saved} =
             Maintenance.apply(review["review_token"], proposal([check, target]), at())

    assert saved["selections"] == review["proposal"]["selections"]
    assert Repo.aggregate(MaintenanceWindow, :count) == 1
    assert Repo.aggregate(MaintenanceEvent, :count) == 1
    assert Enum.map(Maintenance.for_assignment(first.id, at()), & &1["id"]) == [saved["id"]]
    assert length(hd(Maintenance.for_assignment(first.id, at()))["matching_stream_ids"]) == 2
    assert length(hd(Maintenance.for_assignment(second.id, at()))["matching_stream_ids"]) == 1
    assert Maintenance.list(%{"assignment_id" => second.id}, at())["total"] == 1
    assert {:ok, inspected} = Maintenance.get(saved["id"], at())
    assert inspected["match_count"] == 3
    assert inspected["selection_summary"] == review["selection_summary"]
    assert hd(inspected["history"])["snapshot"]["selection_count"] == 2
    assert hd(inspected["history"])["snapshot"]["scope_window_id"] == saved["id"]
    refute Map.has_key?(hd(inspected["history"])["snapshot"], "selections")
    assert Repo.one!(MaintenanceEvent).snapshot["selections"] == saved["selections"]
  end

  test "logical monitoring gaps match exact targets without borrowing check membership" do
    {_input, [first]} = inventory(1, "maintenance.selection", "production")
    target_window = save(proposal([target(first)]))
    check_window = save(proposal([check(first)]))

    declared = %{
      "key" => "declared",
      "assignment_id" => nil,
      "source_id" => first.source_id,
      "environment" => first.environment,
      "target" => %{"kind" => "volume", "key" => "orders"}
    }

    rows = [
      declared,
      Map.merge(declared, %{"key" => "admitted", "assignment_id" => first.id}),
      Map.merge(declared, %{"key" => "other-environment", "environment" => "staging"}),
      Map.merge(declared, %{"key" => "other-source", "source_id" => "other"}),
      Map.merge(declared, %{"key" => "unscoped", "environment" => nil}),
      Map.merge(declared, %{"key" => "unbound", "target" => nil})
    ]

    windows = Maintenance.active_for_rows(rows, at())
    assert Enum.map(windows["declared"], & &1.id) == [target_window["id"]]

    assert Enum.sort(Enum.map(windows["admitted"], & &1.id)) ==
             Enum.sort([target_window["id"], check_window["id"]])

    for key <- ~w(other-environment other-source unscoped unbound),
        do: assert(windows[key] == [])

    {:ok, end_at, _} = DateTime.from_iso8601(target_window["ends_at"])
    assert Maintenance.active_for_rows([declared], end_at) == %{"declared" => []}
    assert Maintenance.active_for_rows([], at()) == %{}

    Repo.insert!(%Mondek.MonitoringGap{
      key: "declared-target-gap",
      scope_key: "coverage:" <> first.source_id,
      details: declared,
      since_at: at(),
      ready_at: DateTime.add(at(), 120)
    })

    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get(MaintenanceWindow, target_window["id"])
    refute Repo.get(MaintenanceWindow, check_window["id"])
  end

  test "check membership stays with its instance while targets survive retirement and movement" do
    {input, [first]} = inventory(1)
    saved = save(proposal([check(first), target(first)]))

    assert {:ok, _} =
             Monitoring.inventory(%{input | "inventory_revision" => 2, "checks" => []}, at())

    assert {:ok, empty} = Maintenance.get(saved["id"], at())
    assert empty["match_count"] == 0
    assert Enum.all?(empty["selection_summary"], &(&1["matched_results"] == 0))
    edited = Map.put(empty["proposal"], "reason", "Keep the target window while moving")
    assert save(edited)["revision"] == 2
    {_replacement, [next]} = inventory(1)
    assert next.id != first.id
    assert {:ok, restored} = Maintenance.get(saved["id"], at())
    assert restored["match_count"] == 1
    assert hd(restored["current_matches"])["assignment_id"] == next.id

    assert Enum.find(restored["selection_summary"], &(&1["scope"] == "check"))["matched_results"] ==
             0

    assert Enum.find(restored["selection_summary"], &(&1["scope"] == "target"))["matched_results"] ==
             1

    assert Enum.find(restored["selection_summary"], &(&1["scope"] == "check"))["retired"]
  end

  test "a selected check includes future outputs but exact targets do not infer host children or namespaces" do
    {input, [first]} = inventory(1, "maintenance.selection", "production")
    check_window = save(proposal([check(first)]))
    target_window = save(proposal([target(first)]))

    newer =
      update_in(input["checks"], fn checks ->
        Enum.map(
          checks,
          &Map.update!(&1, "outputs", fn outputs -> outputs ++ [output("logs")] end)
        )
      end)

    assert {:ok, _} = Monitoring.inventory(%{newer | "inventory_revision" => 2}, at())
    assert {:ok, detail} = Maintenance.get(check_window["id"], at())
    assert detail["match_count"] == 3
    assert {:ok, exact} = Maintenance.get(target_window["id"], at())
    assert exact["match_count"] == 1
    {_other_env, _} = inventory(1, "maintenance.selection", "staging")
    {_other_source, _} = inventory(1, "maintenance.other", "production")
    {_default_env, _} = inventory(1, "maintenance.selection", nil)
    assert {:ok, exact} = Maintenance.get(target_window["id"], at())
    assert exact["match_count"] == 1
    assert Enum.all?(Maintenance.for_assignment(first.id, at()), &(&1["scope"] == "selection"))
  end

  test "review rejects inventory, configuration and overlap drift without partial persistence" do
    {input, [first]} = inventory(1)
    p = proposal([check(first), target(first)])
    {:ok, review} = Maintenance.preview(p, 1, at())
    Monitoring.change(first, %{revision: first.revision + 1})
    assert {:error, :review_changed} = Maintenance.apply(review["review_token"], p, at())
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    {:ok, review} = Maintenance.preview(p, 1, at())
    overlap = save(proposal([target(first)]))
    assert {:error, :review_changed} = Maintenance.apply(review["review_token"], p, at())
    assert Repo.aggregate(MaintenanceWindow, :count) == 1
    assert {:ok, _} = Maintenance.cancel(overlap["id"], 1, "Complete overlapping work", at())
    {:ok, review} = Maintenance.preview(p, 1, at())

    newer =
      update_in(input["checks"], fn checks ->
        checks ++ [Map.put(hd(checks), "key", "new-check")]
      end)

    assert {:ok, _} = Monitoring.inventory(%{newer | "inventory_revision" => 2}, at())
    assert {:error, :review_changed} = Maintenance.apply(review["review_token"], p, at())
    assert Repo.aggregate(MaintenanceWindow, :count) == 1
  end

  test "overlapping shared selectors remain visible when all current matches disappear" do
    {input, [first]} = inventory(1)
    one = save(proposal([target(first)]))
    two = save(proposal([check(first), target(first)]))

    assert {:ok, _} =
             Monitoring.inventory(%{input | "inventory_revision" => 2, "checks" => []}, at())

    {:ok, detail} = Maintenance.get(two["id"], at())

    {:ok, review} =
      Maintenance.preview(Map.put(detail["proposal"], "reason", "No current observers"), 1, at())

    assert review["counts"]["matched_results"] == 0
    assert Enum.map(review["overlaps"], & &1["id"]) == [one["id"]]
    assert {:ok, _} = Maintenance.cancel(one["id"], 1, "Cancel shared overlap", at())

    assert {:error, :review_changed} =
             Maintenance.apply(review["review_token"], review["proposal"], at())
  end

  test "mixed delivery gates keep occurrence identities, retry budgets and independent acknowledgements" do
    {input, [first, second]} = inventory(2)
    ingest_inventory(input, [first, second])
    occurrences = Repo.all(Occurrence)
    original_jobs = Repo.all(Oban.Job) |> Map.new(&{&1.id, {&1.attempt, &1.max_attempts}})
    original_payloads = Map.new(occurrences, &{&1.id, &1.payload})
    selected = save(proposal([target(first)]))
    one_check = save(proposal([check(first)]))

    parents =
      Repo.all(
        from i in Incident, join: a in Assignment, on: a.id == i.assignment_id, select: {i, a}
      )

    grouped = Maintenance.active_for_many(parents, at())

    for {i, a} <- parents do
      direct = Maintenance.active_for(i, a, at())
      assert Enum.sort(Enum.map(grouped[i.id], & &1.id)) == Enum.sort(Enum.map(direct, & &1.id))

      expected =
        if i.result_key == "orders",
          do: if(a.id == first.id, do: 2, else: 1),
          else: if(a.id == first.id, do: 1, else: 0)

      assert length(direct) == expected
    end

    covered =
      Enum.find(parents, fn {i, a} -> a.id == first.id and i.result_key == "orders" end)
      |> elem(0)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(covered.id, 3600, "Still investigating", at())

    assert {:ok, _} = Maintenance.cancel(selected["id"], 1, "Target work complete", at())
    assert {:ok, _} = Maintenance.cancel(one_check["id"], 1, "Check work complete", at())
    occurrence = Enum.find(occurrences, &(&1.incident_id == covered.id))
    assert {:ok, {:gated, 3600}} = NotificationWorker.begin_attempt(occurrence.id, at())
    assert Repo.all(Oban.Job) |> Map.new(&{&1.id, {&1.attempt, &1.max_attempts}}) == original_jobs
    assert Repo.all(Occurrence) |> Map.new(&{&1.id, &1.payload}) == original_payloads
    assert Repo.aggregate(Attempt, :count) == 0
    assert Enum.all?(Repo.all(Occurrence), &(&1.gate_revision >= 0))
  end

  test "cancellation wakes one existing job after a selection hold without renewing its budget" do
    connect()
    ingest(measurement("CRIT"))

    saved =
      save(
        proposal([
          %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000001"},
          %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000002"}
        ])
      )

    occurrence = Repo.one!(Occurrence)

    job =
      Monitoring.change(Repo.one!(Oban.Job), %{state: "executing", attempt: 1, attempted_at: at()})

    assert {:ok, {:gated, 3600}} = NotificationWorker.begin_attempt(occurrence.id, at(), job)
    assert {:ok, _} = Maintenance.cancel(saved["id"], 1, "Done", at())
    assert :ok = Oban.Engines.Basic.snooze_job(Oban.config(), job, 3600)
    assert {:ok, {1, _}} = Sweeper.wake_held_notifications(at())
    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert Repo.get!(Oban.Job, job.id).attempt == 0
    assert Repo.one!(Occurrence).payload == occurrence.payload
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "gates, wakeups and retained audit use the incident's frozen environment" do
    {input, [first]} = inventory(1, "frozen.environment", "production")
    ingest_inventory(input, [first])
    saved = save(proposal([target(first)]))

    incident =
      Repo.one!(
        from i in Incident, where: i.assignment_id == ^first.id and i.result_key == "orders"
      )

    stream = Repo.get!(ResultStream, incident.stream_id)
    Monitoring.change(stream, %{environment: "staging"})
    assert Enum.map(Maintenance.active_for(incident, first, at()), & &1.id) == [saved["id"]]

    assert Enum.map(Maintenance.active_for_many([{incident, first}], at())[incident.id], & &1.id) ==
             [saved["id"]]

    original = Repo.one!(from o in Occurrence, where: o.incident_id == ^incident.id)
    assert {:ok, _} = Maintenance.cancel(saved["id"], 1, "Finish production work", at())
    assert Repo.get!(Occurrence, original.id).gate_revision == original.gate_revision + 1
    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get!(MaintenanceWindow, saved["id"])
  end

  test "selection maintenance history survives cleanup while a related incident remains" do
    connect()
    ingest(measurement("CRIT"))

    saved =
      save(
        proposal([
          %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000001"}
        ])
      )

    assert {:ok, _} = Maintenance.cancel(saved["id"], 1, "Done", at())
    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get!(MaintenanceWindow, saved["id"])
    assert Repo.aggregate(MaintenanceEvent, :count) == 2
    ingest(measurement("OK", 2))
    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: at()])
    assert {:ok, _} = Sweeper.sweep(DateTime.add(at(), 40 * 86_400))
    assert Repo.get(MaintenanceWindow, saved["id"]) == nil
    assert Repo.aggregate(MaintenanceEvent, :count) == 0
  end

  test "reviewed large selections page the whole union and cancellation remains possible after growth" do
    {input, checks} = inventory(512, "large.selection", nil, 1)
    p = proposal(Enum.map(checks, &check/1))
    assert {:ok, review} = Maintenance.preview(p, 21, at())
    assert review["total"] == 512
    assert review["pages"] == 21
    assert length(review["rows"]) == 12
    assert length(review["selection_summary"]) == 512
    assert {:ok, saved} = Maintenance.apply(review["review_token"], p, at())

    expanded =
      update_in(input["checks"], fn checks ->
        Enum.map(
          checks,
          &Map.put(&1, "outputs", Enum.map(1..9, fn n -> output("volume-#{n}") end))
        )
      end)

    assert {:ok, _} = Monitoring.inventory(%{expanded | "inventory_revision" => 2}, at())
    {:ok, detail} = Maintenance.get(saved["id"], at())
    assert detail["match_count"] == 4608
    assert {:error, {:invalid, message}} = Maintenance.preview(detail["proposal"], 1, at())
    assert message =~ "4096"
    assert {:ok, cancelled} = Maintenance.cancel(saved["id"], 1, "End large window", at())
    assert cancelled["status"] == "cancelled"
  end

  test "simultaneous saves create one window and stale edits cannot change its immutable selection" do
    {_input, [first, second]} = inventory(2)
    p = proposal([check(first), check(second)])
    {:ok, review} = Maintenance.preview(p, 1, at())

    results =
      Enum.map(1..2, fn _ ->
        Task.async(fn -> Maintenance.apply(review["review_token"], p, at()) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :review_changed}, &1)) == 1
    saved = Repo.one!(MaintenanceWindow)
    {:ok, detail} = Maintenance.get(saved.id, at())

    assert {:error, {:invalid, message}} =
             Maintenance.preview(
               Map.put(detail["proposal"], "selections", [check(first)]),
               1,
               at()
             )

    assert message =~ "scope is fixed"

    {:ok, review} =
      Maintenance.preview(
        Map.put(detail["proposal"], "reason", "An edited common reason"),
        1,
        at()
      )

    assert {:ok, _} = Maintenance.cancel(saved.id, 1, "Concurrent cancellation", at())
    assert {:error, :stale} = Maintenance.apply(review["review_token"], review["proposal"], at())
    assert Repo.aggregate(MaintenanceEvent, :count) == 2
  end

  test "512 distinct target selections use batched validation and complete paged membership" do
    {input, checks} = inventory(512, "large.targets", nil, 1)

    updated =
      update_in(input["checks"], fn checks ->
        Enum.map(checks, &Map.put(&1, "outputs", [output("target-" <> &1["key"])]))
      end)

    assert {:ok, _} = Monitoring.inventory(%{updated | "inventory_revision" => 2}, at())

    selected =
      Enum.map(checks, fn a -> Map.put(target(a), "target_key", "target-" <> a.source_key) end)

    p = proposal(selected)
    handler = "maintenance-selection-queries-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:mondek, :repo, :query],
        fn _, _, _, owner -> send(owner, :maintenance_selection_query) end,
        self()
      )

    preview =
      try do
        assert {:ok, preview} = Maintenance.preview(p, 21, at())
        preview
      after
        :telemetry.detach(handler)
      end

    assert count_queries() < 30
    assert preview["total"] == 512
    assert preview["counts"] == %{"matched_results" => 512, "matched_checks" => 512}
    assert length(preview["rows"]) == 12
    assert length(preview["selection_summary"]) == 512
    assert {:ok, saved} = Maintenance.apply(preview["review_token"], p, at())
    assert {:ok, detail} = Maintenance.get(saved["id"], at())
    assert detail["match_count"] == 512
    assert {:ok, _} = Maintenance.cancel(saved["id"], 1, "All target work finished", at())
  end

  test "opposite selection orders across sources acquire locks without deadlock" do
    {_one, [first]} = inventory(1, "z-last-source")
    {_two, [second]} = inventory(1, "a-first-source")
    selected = [target(first), check(first), target(second), check(second)]

    tasks =
      for scopes <- [selected, Enum.reverse(selected)],
          do: Task.async(fn -> Maintenance.preview(proposal(scopes), 1, at()) end)

    assert [{:ok, one}, {:ok, two}] = Enum.map(tasks, &Task.await(&1, 10_000))
    assert one["proposal"] == two["proposal"]
    assert one["counts"] == %{"matched_checks" => 2, "matched_results" => 4}
    assert two["counts"] == one["counts"]
  end

  test "a hundred revisions retain full fixed scope in storage but return compact history" do
    selected =
      for index <- 1..512 do
        %{
          "scope" => "target",
          "assignment_id" => nil,
          "source_id" => String.duplicate("s", 200),
          "environment" => String.duplicate("e", 128),
          "target_kind" => String.duplicate("k", 64),
          "target_key" => String.pad_leading(Integer.to_string(index), 200, "t")
        }
      end
      |> Enum.sort()

    reason = fn revision -> String.pad_trailing("Work revision #{revision}", 500, "x") end

    window =
      Repo.insert!(%MaintenanceWindow{
        revision: 100,
        name: String.duplicate("w", 200),
        reason: reason.(100),
        actor: "Local operator",
        scope: "selection",
        selections: selected,
        starts_at: at(),
        ends_at: DateTime.add(at(), 3_700),
        inserted_at: at(),
        updated_at: DateTime.add(at(), 100)
      })

    original = Monitoring.public(window)

    events =
      for revision <- 1..100 do
        instant = DateTime.add(at(), revision)

        %{
          window_id: window.id,
          revision: revision,
          kind: if(revision == 1, do: "created", else: "updated"),
          actor: "Local operator",
          reason: reason.(revision),
          inserted_at: instant,
          snapshot:
            Map.merge(original, %{
              "revision" => revision,
              "reason" => reason.(revision),
              "ends_at" => Monitoring.iso(DateTime.add(at(), 3_600 + revision)),
              "updated_at" => Monitoring.iso(instant)
            })
        }
      end

    assert {100, nil} = Repo.insert_all(MaintenanceEvent, events)
    assert {:ok, detail} = Maintenance.get(window.id, at())
    assert detail["history_count"] == 100
    assert length(detail["history"]) == 100
    assert byte_size(Jason.encode!(detail["history"])) < 250 * 1_024

    for event <- detail["history"] do
      snapshot = event["snapshot"]
      revision = event["revision"]
      refute Map.has_key?(snapshot, "selections")
      assert snapshot["selection_count"] == 512
      assert snapshot["scope_window_id"] == window.id
      assert snapshot["reason"] == reason.(revision)
      assert event["reason"] == reason.(revision)
      assert event["inserted_at"] == Monitoring.iso(DateTime.add(at(), revision))
      assert snapshot["starts_at"] == Monitoring.iso(at())
      assert snapshot["ends_at"] == Monitoring.iso(DateTime.add(at(), 3_600 + revision))
    end

    assert {:ok, referenced} =
             Maintenance.get(hd(detail["history"])["snapshot"]["scope_window_id"], at())

    assert referenced["selections"] == selected

    assert %{rows: [[100]]} =
             Repo.query!(
               "SELECT count(*) FROM maintenance_events WHERE snapshot->'selections' = $1::text::jsonb AND NOT (snapshot ? 'scope_window_id')",
               [Jason.encode!(selected)]
             )
  end

  test "ordinary check history keeps the original complete public snapshot" do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, at())
    saved = save(Map.put(seed["proposal"], "reason", "Single-check history"))
    assert {:ok, detail} = Maintenance.get(saved["id"], at())
    assert hd(detail["history"])["snapshot"] == Repo.one!(MaintenanceEvent).snapshot
    refute Map.has_key?(hd(detail["history"])["snapshot"], "scope_window_id")
  end

  test "malformed selection shapes are rejected by both API validation and database constraints" do
    valid = %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000001"}

    for invalid <- [
          [],
          nil,
          %{},
          [nil],
          [%{"scope" => "selection"}],
          [Map.put(valid, "unexpected", true)],
          [Map.put(valid, "source_id", "mixed")],
          [
            %{
              "scope" => "target",
              "source_id" => %{},
              "target_kind" => "host",
              "target_key" => "one"
            }
          ],
          List.duplicate(valid, 513)
        ] do
      assert {:error, {:invalid, _}} = Maintenance.preview(proposal(invalid), 1, at())
    end

    saved = save(proposal([valid]))
    selector = hd(saved["selections"])

    for invalid <- [
          [],
          [selector, selector],
          [Map.delete(selector, "environment")],
          [Map.put(selector, "source_id", "bad")],
          [Map.put(selector, "unexpected", true)],
          [nil],
          List.duplicate(selector, 513)
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(w in MaintenanceWindow, where: w.id == ^saved["id"]),
          set: [selections: invalid]
        )
      end
    end

    assert Repo.get!(MaintenanceWindow, saved["id"]).selections == [selector]
  end

  defp proposal(selected) do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, at())

    seed["proposal"]
    |> Map.merge(%{
      "scope" => "selection",
      "assignment_id" => nil,
      "source_id" => nil,
      "environment" => nil,
      "target_kind" => nil,
      "target_key" => nil,
      "selections" => selected,
      "reason" => "Coordinated maintenance"
    })
  end

  defp count_queries(total \\ 0) do
    receive do
      :maintenance_selection_query -> count_queries(total + 1)
    after
      0 -> total
    end
  end

  defp save(p) do
    assert {:ok, review} = Maintenance.preview(p, 1, at())
    assert {:ok, saved} = Maintenance.apply(review["review_token"], p, at())
    saved
  end

  defp check(a), do: %{"scope" => "check", "assignment_id" => a.id}

  defp target(a),
    do: %{
      "scope" => "target",
      "source_id" => a.source_id,
      "environment" => a.environment,
      "target_kind" => "volume",
      "target_key" => "orders"
    }

  defp output(key),
    do: %{
      "key" => key,
      "label" => key,
      "target" => %{
        "kind" => "volume",
        "key" => key,
        "label" => if(key == "orders", do: "Orders volume", else: key)
      }
    }

  defp inventory(count, source \\ "maintenance.selection", environment \\ nil, outputs \\ 2) do
    input =
      control(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "prepared" => %{}
      })
      |> Map.merge(%{
        "runner_label" => "Volume observer",
        "source_id" => source,
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" =>
          Enum.map(1..count, fn n ->
            %{
              "key" => "volumes-#{n}",
              "label" => "Volumes #{n}",
              "definition_revision" => String.duplicate("b", 64),
              "environment" => environment,
              "params_owner" => "source",
              "params" => %{},
              "parameter_schema" => %{"fields" => %{}},
              "interval_seconds" => 3,
              "timeout_seconds" => 2,
              "freshness_seconds" => 12,
              "outputs" => Enum.take([output("orders"), output("other")], outputs)
            }
          end)
      })

    assert {:ok, _} = Monitoring.inventory(input, at())
    runner = Repo.get!(Mondek.Runner, input["installation_id"])

    checks =
      Repo.all(
        from a in Assignment,
          where: a.runner_id == ^runner.id and a.source_id == ^source,
          order_by: a.source_key
      )

    {input, checks}
  end

  defp ingest_inventory(input, checks) do
    identity = Map.take(input, ["installation_id", "session_id"])
    prepared = Map.new(checks, &{&1.id, &1.desired_generation})

    assert {:ok, _} =
             Monitoring.control(control(Map.merge(identity, %{"prepared" => prepared})), at())

    reports =
      Enum.map(checks, fn a ->
        measurement(
          "CRIT",
          1,
          Map.merge(identity, %{
            "assignment_id" => a.id,
            "generation" => a.desired_generation,
            "results" =>
              Enum.map(a.outputs, fn o ->
                %{
                  "key" => o["key"],
                  "health" => "CRIT",
                  "summary" => "Measured failure",
                  "source_at" => "2009-09-15T08:00:00.010000Z"
                }
              end)
          })
        )
      end)

    assert {:ok, _} = Monitoring.ingest(envelope(reports, identity), at())
  end
end
