# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.GroupedInspectionTest do
  use Mondek.DataCase, async: false
  alias Mondek.{ResultStream, Runner}

  setup do
    Repo.query!("TRUNCATE runners, assignments RESTART IDENTITY CASCADE")
    runner = observer()
    %{runner: runner}
  end

  test "identity groups independent observers but never names, sources or environments", %{
    runner: runner
  } do
    second = observer()
    original = result(runner, "a")
    result(second, "b", target_label: "Renamed host")
    result(runner, "c", target_key: "other")
    result(runner, "d", target_kind: "service")
    result(runner, "e", source_id: "different-source")
    result(runner, "f", environment: "staging")
    result(runner, "g", environment: nil)
    listing = Monitoring.list_grouped_streams(%{}, at())
    assert length(listing.groups) == 6
    group = Enum.find(listing.groups, &(&1["total"] == 2))
    assert group["observers"] == 2

    assert Enum.map(group["items"], & &1["runner_id"]) |> Enum.sort() ==
             Enum.sort([runner.id, second.id])

    Monitoring.change(original, %{
      target: %{"kind" => "host", "key" => "node", "label" => "New display name"}
    })

    renamed = Monitoring.list_grouped_streams(%{}, at()).groups |> Enum.find(&(&1["total"] == 2))
    assert renamed["id"] == group["id"]
    assert Repo.aggregate(Incident, :count) == 0
  end

  test "retained health and coverage sort independently with retired results last", %{
    runner: runner
  } do
    result(runner, "z-critical", health: "CRIT")
    result(runner, "y-critical-stale", health: "CRIT", source_at: DateTime.add(at(), -12))
    result(runner, "x-warning", health: "WARN")
    result(runner, "w-unavailable", health: "OK", knowledge: "unavailable")
    result(runner, "v-stale", source_at: DateTime.add(at(), -12))
    result(runner, "u-pending", current: %{})

    result(runner, "t-first-failed",
      health: "UNKNOWN",
      knowledge: "unavailable",
      confirmed: false
    )

    result(runner, "s-healthy")
    result(runner, "a-retired-critical", health: "CRIT", retired_at: at())

    [group] = Monitoring.list_grouped_streams(%{status: "all"}, at()).groups

    assert Enum.map(group["items"], & &1["label"]) == [
             "y-critical-stale",
             "z-critical",
             "x-warning",
             "t-first-failed",
             "w-unavailable",
             "v-stale",
             "u-pending",
             "s-healthy",
             "a-retired-critical"
           ]

    assert group["health_counts"] == %{"CRIT" => 3, "WARN" => 1, "UNKNOWN" => 0, "OK" => 3}

    assert group["knowledge_counts"] == %{
             "fresh" => 3,
             "stale" => 2,
             "unavailable" => 2,
             "awaiting" => 1,
             "retired" => 1
           }

    # The exact freshness boundary changes coverage, never the retained verdict.
    [later] = Monitoring.list_grouped_streams(%{}, DateTime.add(at(), 12)).groups
    assert later["health_counts"]["CRIT"] == 2
    assert later["knowledge_counts"]["fresh"] == 0

    assert Monitoring.list_grouped_streams(%{health: "UNKNOWN"}, at()).total == 0
    assert Monitoring.list_streams(%{health: "UNKNOWN"}, at()).total == 0
    assert Monitoring.list_grouped_streams(%{health: "not_measured"}, at()).total == 2
  end

  test "problems order whole groups before pagination and summaries cover all matching rows", %{
    runner: runner
  } do
    for index <- 1..530 do
      result(runner, "check-#{String.pad_leading(to_string(index), 4, "0")}",
        target_key: if(index <= 123, do: "large", else: "other-#{index}"),
        target_label: if(index <= 123, do: "Z large host", else: "A host #{index}"),
        health: if(index == 123, do: "CRIT", else: "OK")
      )
    end

    first = Monitoring.list_grouped_streams(%{}, at())
    assert first.total == 530
    assert length(first.items) == 50
    assert hd(first.items)["label"] == "check-0123"
    assert [group] = first.groups
    assert group["total"] == 123
    assert group["first_index"] == 1
    assert group["last_index"] == 50
    assert group["health_counts"] == %{"CRIT" => 1, "WARN" => 0, "UNKNOWN" => 0, "OK" => 122}

    second = Monitoring.list_grouped_streams(%{page: 2}, at())
    assert [continued] = second.groups
    assert continued["id"] == group["id"]
    assert continued["first_index"] == 51
    assert continued["last_index"] == 100
    assert continued["health_counts"] == group["health_counts"]
    assert Enum.all?(second.items, &(get_in(&1, ["current", "health"]) == "OK"))

    pages = for page <- 1..11, do: Monitoring.list_grouped_streams(%{page: page}, at())
    ids = Enum.flat_map(pages, &Enum.map(&1.items, fn row -> row["id"] end))
    assert length(ids) == 530
    assert length(Enum.uniq(ids)) == 530
    assert hd(Enum.at(pages, 2).groups)["last_index"] == 123
    assert List.last(pages).total == 530

    [filtered] = Monitoring.list_grouped_streams(%{health: "OK", search: "check-00"}, at()).groups
    assert filtered["total"] == 99
    assert filtered["health_counts"]["CRIT"] == 0
    assert Monitoring.list_grouped_streams(%{page_size: 999}, at()).page_size == 100
    assert Monitoring.list_grouped_streams(%{page: 999}, at()).page == 11
  end

  test "runner filtering narrows complete group counts without changing its identity", %{
    runner: runner
  } do
    second = observer()
    result(runner, "healthy")
    result(second, "failed", health: "CRIT")
    [all] = Monitoring.list_grouped_streams(%{}, at()).groups
    [filtered] = Monitoring.list_grouped_streams(%{runner_id: runner.id}, at()).groups
    assert filtered["id"] == all["id"]
    assert filtered["total"] == 1
    assert filtered["observers"] == 1
    assert filtered["health_counts"]["CRIT"] == 0
    assert Monitoring.list_grouped_streams(%{runner_id: "bad"}, at()).groups == []
    assert Monitoring.list_grouped_streams(%{search: "absent"}, at()).coverage["active"] == 2
  end

  test "historic environment and target identity survive assignment rebinding", %{runner: runner} do
    old = result(runner, "old", environment: "before", retired_at: at(), health: "CRIT")
    Monitoring.change(Repo.get!(Assignment, old.assignment_id), %{environment: "after"})
    result(runner, "new", environment: "after")
    listing = Monitoring.list_grouped_streams(%{status: "all"}, at())
    assert Enum.map(listing.groups, & &1["environment"]) == ["after", "before"]

    [retired] =
      Monitoring.list_grouped_streams(%{status: "retired", environment: "before"}, at()).groups

    assert retired["knowledge_counts"]["retired"] == 1

    assert Monitoring.list_grouped_streams(%{status: "retired", environment: "after"}, at()).total ==
             0
  end

  test "missing source or target metadata cannot merge unrelated historical results", %{
    runner: runner
  } do
    result(runner, "legacy-a", source_id: nil)
    result(runner, "legacy-b", source_id: nil)
    a = result(runner, "missing-a")
    b = result(runner, "missing-b")
    for row <- [a, b], do: Monitoring.change(row, %{target: %{}})
    assert length(Monitoring.list_grouped_streams(%{}, at()).groups) == 4
    for row <- [a, b], do: Monitoring.change(row, %{target: %{"key" => "same-key"}})
    assert length(Monitoring.list_grouped_streams(%{}, at()).groups) == 4
  end

  test "new sessions and authorized configurations require new evidence without losing retained health",
       %{runner: runner} do
    old = result(runner, "session-critical", health: "CRIT")
    result(runner, "session-healthy")
    Monitoring.change(runner, %{session_id: Ecto.UUID.generate()})
    [group] = Monitoring.list_grouped_streams(%{freshness: "awaiting"}, at()).groups
    assert group["total"] == 2
    assert group["knowledge_counts"]["awaiting"] == 2
    assert group["health_counts"]["CRIT"] == 1
    assert hd(group["items"])["id"] == old.id

    Monitoring.change(Repo.get!(Runner, runner.id), %{session_id: runner.session_id})
    Monitoring.change(Repo.get!(Assignment, old.assignment_id), %{authorized_generation: 2})
    [changed] = Monitoring.list_grouped_streams(%{freshness: "awaiting"}, at()).groups
    assert changed["id"] == group["id"]
    assert changed["total"] == 1
    assert changed["health_counts"]["CRIT"] == 1
    assert Monitoring.list_grouped_streams(%{freshness: "fresh"}, at()).total == 1
  end

  test "group navigation bounds results and preserves selection outside a local search",
       %{
         runner: runner
       } do
    for index <- 1..123 do
      result(runner, "large-#{index}",
        target_key: "large",
        target_label: "Large target",
        health: if(index == 123, do: "CRIT", else: "OK")
      )
    end

    for index <- 1..44 do
      result(runner, "small-#{index}", target_key: "node-#{index}", target_label: "Same name")
    end

    first = Monitoring.list_target_streams(%{}, at())
    assert first.total == 167
    assert first.target_total == 45
    assert first.target_page == 1
    assert first.target_page_size == 100
    assert length(first.target_groups) == 45
    assert first.selected_total == 123
    assert first.selected_target["label"] == "Large target"
    assert length(first.items) == 50
    assert hd(first.items)["label"] == "large-123"
    assert [group] = first.groups
    assert group["total"] == 123
    assert group["inventory_total"] == 123
    assert group["first_index"] == 1
    assert group["last_index"] == 50

    retained =
      Monitoring.list_target_streams(
        %{group_search: "Same name", target: group["id"], page: 999, page_size: 999},
        at()
      )

    assert length(retained.target_groups) == 44
    refute Enum.any?(retained.target_groups, &(&1["id"] == group["id"]))
    assert retained.selected_target["id"] == group["id"]
    assert retained.selected_total == 123
    assert retained.page_size == 100
    assert retained.page == 2
    assert length(retained.items) == 23
    assert hd(retained.groups)["first_index"] == 101

    fallback = Monitoring.list_target_streams(%{target_page: 999, target: "missing"}, at())
    assert fallback.target_page == 1
    assert fallback.selected_target == hd(fallback.target_groups)
    assert fallback.selected_total == 123

    filtered =
      Monitoring.list_target_streams(%{target: group["id"], search: "small", page: 3}, at())

    assert filtered.total == 44
    assert filtered.target_total == 44
    assert filtered.selected_target == hd(filtered.target_groups)
    assert filtered.selected_total == 1
    assert filtered.page == 1

    empty = Monitoring.list_target_streams(%{search: "absent", target_page: 10, page: 10}, at())
    assert empty.target_groups == []
    assert empty.groups == []
    assert empty.items == []
    assert empty.selected_target == nil
    assert empty.selected_total == 0
    assert empty.target_total == 0
    assert empty.total == 0
    assert empty.page == 1
    assert empty.target_page == 1
  end

  test "matching counts retain target membership across observers while respecting history", %{
    runner: runner
  } do
    second = observer()
    result(runner, "critical", health: "CRIT")
    result(runner, "healthy")
    result(second, "observer", health: "WARN")
    result(runner, "retired", retired_at: at())
    result(runner, "other-environment", environment: "staging")
    result(runner, "other-source", source_id: "unrelated")

    for list <- [&Monitoring.list_grouped_streams/2, &Monitoring.list_target_streams/2] do
      listing = list.(%{runner_id: runner.id, search: "critical", health: "CRIT"}, at())
      assert listing.total == 1
      assert [group] = listing.groups
      assert group["total"] == 1
      assert group["inventory_total"] == 3
      assert group["observers"] == 1

      [all] = list.(%{status: "all", search: "critical"}, at()).groups
      assert all["id"] == group["id"]
      assert all["inventory_total"] == 4

      [retired] = list.(%{status: "retired"}, at()).groups
      assert retired["inventory_total"] == 1
      assert retired["id"] == group["id"]
    end
  end

  test "filtered pages aggregate target summaries once across five hundred matching targets", %{
    runner: runner
  } do
    for index <- 0..499 do
      name = "exports/export-#{String.pad_leading(to_string(index), 4, "0")}.txt"
      result(runner, name, target_key: name, target_label: name, environment: "capacity-test")
    end

    # Realistic statistics expose the cross-table search's low row estimate.
    # The old plan recomputed complete aggregates inside each matching row's
    # loop and timed out even at 15 seconds in the packaged application.
    for table <- ~w(result_streams assignments runners), do: Repo.query!("ANALYZE " <> table)

    assert {:ok, :verified} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL statement_timeout = '2000ms'")
               assert Repo.query!("SHOW statement_timeout").rows == [["2s"]]
               filters = %{search: "exports/export-", environment: "capacity-test"}
               listing = Monitoring.list_grouped_streams(filters, at())
               assert listing.total == 500
               assert length(listing.items) == 50
               assert length(listing.groups) == 50
               assert hd(listing.items)["label"] == "exports/export-0000.txt"
               assert List.last(listing.items)["label"] == "exports/export-0049.txt"

               focused = Monitoring.list_target_streams(filters, at())
               assert focused.total == 500
               assert focused.target_total == 500
               assert length(focused.target_groups) == 100
               assert focused.selected_total == 1
               assert length(focused.items) == 1
               assert focused.selected_target["id"] == hd(listing.groups)["id"]

               last = Monitoring.list_grouped_streams(Map.put(filters, :page, 10), at())
               assert last.page == 10
               assert length(last.items) == 50
               assert List.last(last.items)["label"] == "exports/export-0499.txt"

               assert last.filter_counts == %{
                        "all" => 500,
                        "attention" => 0,
                        "critical" => 0,
                        "gaps" => 0
                      }

               :verified
             end)
  end

  test "tab counts follow search, runner, environment and membership independently of selected health",
       %{
         runner: runner
       } do
    Monitoring.change(runner, %{label: "Observer North"})
    second = observer()
    result(runner, "critical", health: "CRIT")
    result(runner, "critical-stale", health: "CRIT", source_at: DateTime.add(at(), -12))
    result(runner, "warning", health: "WARN")
    result(runner, "unknown", health: "UNKNOWN")
    result(runner, "healthy")
    result(runner, "pending", current: %{})
    result(runner, "unavailable", knowledge: "unavailable")
    result(runner, "retired", health: "CRIT", retired_at: at())
    result(second, "second-critical", health: "CRIT")
    result(runner, "staging-critical", health: "CRIT", environment: "staging")
    expected = %{"all" => 7, "attention" => 5, "critical" => 2, "gaps" => 3}

    filters = %{
      environment: "production",
      search: "Observer North",
      health: "OK",
      freshness: "fresh"
    }

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      assert list.(filters, at()).filter_counts == expected
      assert list.(Map.put(filters, :attention, true), at()).filter_counts == expected

      assert list.(%{environment: "production", runner_id: runner.id}, at()).filter_counts ==
               expected

      assert list.(%{search: "absent"}, at()).filter_counts == %{
               "all" => 0,
               "attention" => 0,
               "critical" => 0,
               "gaps" => 0
             }

      assert list.(%{environment: "production", runner_id: runner.id, freshness: "gaps"}, at()).total ==
               3

      assert list.(%{status: "retired", freshness: "gaps"}, at()).filter_counts == %{
               "all" => 1,
               "attention" => 1,
               "critical" => 1,
               "gaps" => 1
             }
    end
  end

  test "target IDs preserve compact JSON hashes and missing identities never share selection", %{
    runner: runner
  } do
    key = "node, \"quoted\" \\ unicode:ä\nline"
    exact = result(runner, "exact", target_key: key)
    missing_source = result(runner, "missing-source", source_id: nil)
    missing_target = result(runner, "missing-target")
    Monitoring.change(missing_target, %{target: %{}})

    listing = Monitoring.list_target_streams(%{}, at())
    assert listing.target_total == 3

    identities = [
      {exact, ["inventory.test", "production", "host", key, nil]},
      {missing_source, [nil, "production", "host", "node", missing_source.id]},
      {missing_target, ["inventory.test", "production", nil, nil, missing_target.id]}
    ]

    for {row, identity} <- identities do
      id =
        "target-" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(identity)), case: :lower)

      target = Enum.find(listing.target_groups, &(&1["id"] == id))
      assert target
      selected = Monitoring.list_target_streams(%{target: id}, at())
      assert selected.selected_target["id"] == id
      assert selected.selected_total == 1
      assert [item] = selected.items
      assert item["id"] == row.id
    end
  end

  test "exact-target scope filters every view and counts without merging independent evidence", %{
    runner: runner
  } do
    second = observer()
    critical = result(runner, "critical", health: "CRIT", source_at: DateTime.add(at(), -12))
    healthy = result(second, "healthy", target_label: "Renamed same subject")

    for opts <- [
          [target_key: "other"],
          [target_kind: "service"],
          [source_id: "other-source"],
          [environment: "staging"],
          [environment: nil]
        ] do
      result(runner, Ecto.UUID.generate(), opts)
    end

    id = Mondek.Inspection.target_id(Mondek.Inspection.stream_detail(critical.id, at()))

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      scoped = list.(%{target_scope: id}, at())
      assert scoped.total == 2

      assert MapSet.new(Enum.map(scoped.items, & &1["id"])) ==
               MapSet.new([critical.id, healthy.id])

      assert scoped.filter_counts == %{"all" => 2, "attention" => 1, "critical" => 1, "gaps" => 1}
      assert list.(%{target_scope: id, health: "CRIT"}, at()).total == 1
      assert list.(%{target_scope: id, freshness: "fresh"}, at()).total == 1
      assert list.(%{target_scope: id, runner_id: second.id}, at()).total == 1
    end

    [group] = Monitoring.list_grouped_streams(%{target_scope: id}, at()).groups
    assert group["id"] == id
    assert group["observers"] == 2
    assert group["health_counts"]["CRIT"] == 1
    assert group["health_counts"]["OK"] == 1
    assert group["knowledge_counts"]["stale"] == 1
    assert group["knowledge_counts"]["fresh"] == 1
    [problem] = Monitoring.list_grouped_streams(%{target_scope: id, health: "CRIT"}, at()).groups
    assert problem["total"] == 1
    assert problem["inventory_total"] == 2
  end

  test "exact-target boundary applies before pagination and unknown scopes never select another target",
       %{runner: runner} do
    rows = for n <- 1..57, do: result(runner, "scope-#{n}")
    unrelated = result(runner, "unrelated", target_key: "other")
    id = Mondek.Inspection.target_id(Mondek.Inspection.stream_detail(hd(rows).id, at()))

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      pages = for page <- 1..3, do: list.(%{target_scope: id, page: page, page_size: 25}, at())
      assert Enum.map(pages, &length(&1.items)) == [25, 25, 7]
      assert Enum.all?(pages, &(&1.total == 57 && &1.filter_counts["all"] == 57))

      assert pages |> Enum.flat_map(& &1.items) |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() ==
               57

      empty = list.(%{target_scope: "target-unknown", target: id, page: 9}, at())
      assert empty.total == 0
      assert empty.items == []
      assert empty.filter_counts["all"] == 0
    end

    empty = Monitoring.list_target_streams(%{target_scope: "target-unknown", target: id}, at())
    assert empty.selected_target == nil
    assert empty.target_groups == []
    # A selection preference outside the hard boundary cannot widen it.
    other_id =
      Mondek.Inspection.target_id(Mondek.Inspection.stream_detail(unrelated.id, at()))

    selected = Monitoring.list_target_streams(%{target_scope: id, target: other_id}, at())
    assert selected.selected_target["id"] == id
  end

  test "target scope preserves retirement membership and legacy isolated identities", %{
    runner: runner
  } do
    retired = result(runner, "retired-scope", target_key: "gone", retired_at: at())
    missing = result(runner, "missing-source-one", source_id: nil)
    result(runner, "missing-source-two", source_id: nil)
    escaped = result(runner, "escaped", target_key: "quote\" unicodeä slash\\ line\n")

    for row <- [retired, missing, escaped] do
      detail = Mondek.Inspection.stream_detail(row.id, at())
      id = Mondek.Inspection.target_id(detail)

      for list <- [
            &Monitoring.list_streams/2,
            &Monitoring.list_grouped_streams/2,
            &Monitoring.list_target_streams/2
          ] do
        scoped = list.(%{target_scope: id, status: "all"}, at())
        assert scoped.total == 1
        assert hd(scoped.items)["id"] == row.id
      end
    end

    id = Mondek.Inspection.target_id(Mondek.Inspection.stream_detail(retired.id, at()))
    assert Monitoring.list_target_streams(%{target_scope: id}, at()).selected_target == nil

    assert Monitoring.list_target_streams(%{target_scope: id, status: "retired"}, at()).selected_total ==
             1
  end

  test "named scope survives secondary zero-result filters without reviving retired targets", %{
    runner: runner
  } do
    healthy = result(runner, "healthy-scope", target_label: "Exact subject")
    id = Mondek.Inspection.target_id(Mondek.Inspection.stream_detail(healthy.id, at()))

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      for filters <- [
            %{health: "CRIT"},
            %{search: "does-not-exist"},
            %{runner_id: Ecto.UUID.generate()}
          ] do
        scoped = list.(Map.put(filters, :target_scope, id), at())
        assert scoped.items == []
        assert scoped.total == 0
        assert scoped.scope_target["id"] == id
        assert scoped.scope_target["label"] == "Exact subject"
        assert scoped.scope_target["source_id"] == "inventory.test"
        assert scoped.scope_target["environment"] == "production"
        assert scoped.scope_target["total"] == 1
      end

      assert list.(%{}, at()).scope_target == nil
      assert list.(%{target_scope: "target-absent"}, at()).scope_target == nil
    end

    Monitoring.change(healthy, %{retired_at: at()})

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      assert list.(%{target_scope: id}, at()).scope_target == nil
      retired = list.(%{target_scope: id, status: "retired", health: "CRIT"}, at())
      assert retired.items == []
      assert retired.scope_target["id"] == id
      assert retired.scope_target["knowledge_counts"]["retired"] == 1
    end
  end

  test "malformed nonempty target scope fails closed rather than widening API inventory", %{
    runner: runner
  } do
    result(runner, "present")

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      for invalid <- [
            String.duplicate("x", 201),
            %{"nested" => "value"},
            ["target"],
            17,
            false,
            " ",
            "target-" <> String.duplicate("z", 64)
          ] do
        scoped = list.(%{"target_scope" => invalid}, at())
        assert scoped.total == 0
        assert scoped.items == []
        assert scoped.scope_target == nil
        assert scoped.filter_counts["all"] == 0
      end

      assert list.(%{"target_scope" => ""}, at()).total == 1
    end
  end

  defp observer do
    Repo.insert!(%Runner{
      id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      boot: 1,
      last_seen_at: at(),
      label: "Observer"
    })
  end

  test "real failed and stale first collections remain unmeasured while failed later runs retain critical evidence" do
    definitions =
      for key <- ~w(awaiting failed stale retained) do
        %{
          "key" => key,
          "label" => key,
          "definition_revision" => String.duplicate("b", 64),
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{}},
          "params" => %{},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "capacity",
              "label" => key,
              "target" => %{"kind" => "host", "key" => "node", "label" => "Shared host"}
            }
          ]
        }
      end

    assert {:ok, _} =
             Monitoring.inventory(
               control(%{
                 "runner_label" => "Confirmation observer",
                 "source_id" => "inventory.confirmation",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => definitions
               }),
               at()
             )

    assignments =
      Repo.all(from a in Assignment, where: a.source_id == "inventory.confirmation")
      |> Map.new(&{&1.source_key, &1.id})

    assert {:ok, _} = connect(%{"prepared" => Map.new(assignments, fn {_key, id} -> {id, 1} end)})

    confirmed = measurement("CRIT", 1, %{"assignment_id" => assignments["retained"]})
    assert disposition(ingest(confirmed)) == "current"

    for {key, sequence} <- [{"failed", 1}, {"retained", 2}] do
      failed =
        measurement("UNKNOWN", sequence, %{
          "assignment_id" => assignments[key],
          "complete" => false
        })
        |> put_in(["results", Access.at(0), "source_at"], nil)

      assert disposition(ingest(failed)) == "current"
    end

    stale =
      measurement("OK", 1, %{"assignment_id" => assignments["stale"]})
      |> put_in(
        ["results", Access.at(0), "source_at"],
        DateTime.to_iso8601(DateTime.add(at(), -100))
      )

    assert disposition(ingest(stale)) == "current"

    [group] = Monitoring.list_grouped_streams(%{}, at()).groups
    assert group["total"] == 4
    assert group["health_counts"] == %{"CRIT" => 1, "WARN" => 0, "UNKNOWN" => 0, "OK" => 0}

    assert group["knowledge_counts"] == %{
             "fresh" => 0,
             "stale" => 1,
             "unavailable" => 2,
             "awaiting" => 1,
             "retired" => 0
           }

    assert hd(group["items"])["source_key"] == "retained"
    rows = Map.new(group["items"], &{&1["source_key"], &1})
    assert rows["failed"]["current"]["health"] == "UNKNOWN"
    refute rows["failed"]["current"]["confirmed_observation_id"]
    assert rows["retained"]["current"]["health"] == "CRIT"
    assert rows["retained"]["current"]["confirmed_observation_id"] == confirmed["id"]

    for list <- [
          &Monitoring.list_streams/2,
          &Monitoring.list_grouped_streams/2,
          &Monitoring.list_target_streams/2
        ] do
      assert list.(%{health: "not_measured"}, at()).total == 3
      assert list.(%{health: "not_measured", freshness: "awaiting"}, at()).total == 1
      assert list.(%{health: "not_measured", freshness: "unavailable"}, at()).total == 1
      assert list.(%{health: "not_measured", freshness: "stale"}, at()).total == 1
      assert list.(%{health: "UNKNOWN"}, at()).total == 0
      assert list.(%{health: "OK"}, at()).total == 0
      assert list.(%{health: "CRIT", freshness: "unavailable"}, at()).total == 1
      assert list.(%{attention: true}, at()).total == 4
    end
  end

  test "check groups are source/environment scoped and preserve exact target investigation", %{
    runner: runner
  } do
    group = %{"key" => "fleet", "label" => "Zulu Fleet"}
    a = result(runner, "container-a", target_key: "a")
    b = result(runner, "container-b", target_key: "b")
    c = result(observer(), "second-observer", target_key: "a")
    different_source = result(runner, "other-source", source_id: "other")
    different_environment = result(runner, "other-environment", environment: "staging")

    for stream <- [a, b, c, different_source, different_environment],
        do: Monitoring.change(stream, %{check_group: group})

    result(runner, "ungrouped",
      target_key: "fleet",
      target_kind: "check-group",
      target_label: "A first target"
    )

    listing = Monitoring.list_target_streams(%{}, at())
    assert listing.target_total == 4
    fleet = Enum.find(listing.target_groups, &(&1["total"] == 3))
    assert fleet["is_check_group"]
    assert fleet["target_key"] == nil
    assert fleet["observers"] == 2
    assert fleet["id"] =~ "group-"
    focused = Monitoring.list_target_streams(%{target: fleet["id"]}, at())
    exact_id = Mondek.Inspection.target_id(Enum.find(focused.items, &(&1["id"] == a.id)))
    unsupported = Monitoring.list_target_streams(%{target: exact_id}, at())
    assert unsupported.selected_target["id"] == listing.selected_target["id"]
    refute unsupported.selected_target["id"] == fleet["id"]
    assert length(Monitoring.list_grouped_streams(%{}, at()).groups) == 4
    exact = Monitoring.list_target_streams(%{target_scope: exact_id}, at())
    assert exact.total == 2
    assert Enum.sort(Enum.map(exact.items, & &1["id"])) == Enum.sort([a.id, c.id])
    refute exact.scope_target["is_check_group"]

    hidden =
      Monitoring.list_target_streams(
        %{target: fleet["id"], group_search: "no matching group"},
        at()
      )

    assert hidden.target_groups == []
    assert hidden.group_total == 0
    assert hidden.total == listing.total
    assert hidden.selected_target == fleet
    assert length(hidden.items) == 3
  end

  test "group sidebar loads a bounded cumulative prefix with literal local search", %{
    runner: runner
  } do
    for index <- 1..105 do
      stream = result(runner, "entry-#{index}", target_key: "#{index}")

      Monitoring.change(stream, %{
        check_group: %{"key" => "g-#{index}", "label" => "Group #{index}"}
      })
    end

    first = Monitoring.list_target_streams(%{}, at())
    assert length(first.target_groups) == 100
    assert first.group_has_more
    assert first.group_total == 105

    more =
      Monitoring.list_target_streams(
        %{group_limit: 200, target: first.selected_target["id"]},
        at()
      )

    assert Enum.take(more.target_groups, 100) == first.target_groups
    assert length(more.target_groups) == 105
    refute more.group_has_more
    assert more.selected_target == first.selected_target
    empty = Monitoring.list_target_streams(%{group_search: "%"}, at())
    assert empty.group_total == 0
    assert empty.selected_total == 1
  end

  defp result(runner, name, opts \\ []) do
    id = Ecto.UUID.generate()
    environment = Keyword.get(opts, :environment, "production")

    Repo.insert!(%Assignment{
      id: id,
      kind: "10000000-0000-4000-8000-000000000003",
      label: name,
      source_key: name,
      source_id: Keyword.get(opts, :source_id, "inventory.test"),
      runner_id: runner.id,
      environment: environment,
      params: %{},
      expected_keys: [name],
      authorized_generation: 1
    })

    current =
      Keyword.get(opts, :current, %{
        "generation" => 1,
        "session_id" => runner.session_id,
        "health" => Keyword.get(opts, :health, "OK"),
        "knowledge" => Keyword.get(opts, :knowledge, "fresh"),
        "source_at" => DateTime.to_iso8601(Keyword.get(opts, :source_at, at()))
      })

    current =
      if current != %{} && Keyword.get(opts, :confirmed, true) do
        observation_id = Ecto.UUID.generate()

        payload =
          measurement(current["health"], 1, %{
            "id" => observation_id,
            "assignment_id" => id,
            "installation_id" => runner.id,
            "session_id" => runner.session_id
          })
          |> put_in(["results", Access.at(0), "key"], name)
          |> put_in(["results", Access.at(0), "source_at"], current["source_at"])

        observation =
          Repo.insert!(%Observation{
            id: observation_id,
            assignment_id: id,
            installation_id: runner.id,
            session_id: runner.session_id,
            generation: 1,
            sequence: 1,
            started_at: at(),
            evaluated_at: at(),
            received_at: at(),
            payload: payload,
            disposition: "current"
          })

        Map.merge(current, %{
          "confirmed_observation_id" => observation.id,
          "confirmed_generation" => 1
        })
      else
        current
      end

    Repo.insert!(%ResultStream{
      assignment_id: id,
      result_key: name,
      label: name,
      environment: environment,
      environment_label: environment,
      target: %{
        "key" => Keyword.get(opts, :target_key, "node"),
        "label" => Keyword.get(opts, :target_label, "Host"),
        "kind" => Keyword.get(opts, :target_kind, "host")
      },
      current: current,
      retired_at: Keyword.get(opts, :retired_at)
    })
  end
end
