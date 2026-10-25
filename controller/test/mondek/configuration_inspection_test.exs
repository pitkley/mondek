# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationInspectionTest do
  use Mondek.DataCase, async: false
  alias Mondek.Inventory

  test "desired-version stages preserve measured milestones through stale or failed collection" do
    rows = publish(~w(saved prepared active measured-stale measured-failed retired))
    set_stage(rows["saved"], desired_generation: 2)
    set_stage(rows["prepared"], desired_generation: 2, prepared_generation: 2)

    set_stage(rows["active"],
      desired_generation: 2,
      prepared_generation: 2,
      active_generation: 2,
      observed_generation: 1,
      current: %{"generation" => 2, "confirmed_generation" => 1, "knowledge" => "unavailable"}
    )

    for {key, knowledge} <- [{"measured-stale", "stale"}, {"measured-failed", "unavailable"}] do
      set_stage(rows[key],
        desired_generation: 2,
        prepared_generation: 2,
        active_generation: 2,
        observed_generation: 2,
        params_owner: "source",
        parameter_contract: nil,
        parameter_schema_fingerprint: nil,
        current: %{"generation" => 2, "confirmed_generation" => 2, "knowledge" => knowledge}
      )
    end

    set_stage(rows["retired"],
      observed_generation: 1,
      retired_at: at(),
      retirement_reason: "Source withdrew this check"
    )

    filters = %{"environment" => "adoption-test", "status" => "all"}
    all = Monitoring.list_checks(filters, at())
    assert all.total == 6

    assert Enum.find(all.items, &(&1["source_key"] == "retired"))["configuration_stage"] ==
             "retired"

    for {stage, keys} <- [
          {"saved", ["saved"]},
          {"prepared", ["prepared"]},
          {"active", ["active"]},
          {"measured", ["measured-failed", "measured-stale"]}
        ] do
      page =
        Monitoring.list_checks(
          Map.put(filters, "configuration_stage", stage),
          DateTime.add(at(), 3600)
        )

      assert Enum.map(page.items, & &1["source_key"]) == keys
      assert page.total == length(keys)
      assert page.configuration_summary["scope_total"] == 6
      assert page.configuration_summary["global_total"] == 8

      assert page.configuration_summary["global_counts"] == %{
               "saved" => 4,
               "prepared" => 1,
               "active" => 1,
               "measured" => 2
             }
    end

    # Legacy receipt semantics use confirmed evidence, not an old observed field
    # which could have advanced on incomplete collection before migration.
    set_stage("10000000-0000-4000-8000-000000000002",
      desired_generation: 2,
      active_generation: 2,
      observed_generation: 2,
      current: %{"confirmed_generation" => 1, "knowledge" => "unavailable"}
    )

    legacy =
      Monitoring.list_checks(%{"search" => "HTTP", "configuration_stage" => "active"}, at())

    refute Enum.any?(legacy.items, &(&1["id"] == "10000000-0000-4000-8000-000000000002"))

    assert Monitoring.list_checks(Map.put(filters, "configuration_stage", "unknown"), at()).total ==
             6
  end

  test "stage paging and bulk matching share the full filtered scope with independent global totals" do
    keys = for index <- 1..57, do: "check-#{String.pad_leading(to_string(index), 2, "0")}"
    rows = publish(keys)
    prepared_ids = keys |> Enum.take(55) |> Enum.map(&rows[&1])

    Repo.update_all(from(a in Assignment, where: a.id in ^prepared_ids),
      set: [prepared_generation: 1]
    )

    filters = %{
      "environment" => "adoption-test",
      "configuration_stage" => "prepared",
      "page" => 99,
      "page_size" => 10
    }

    page = Monitoring.list_checks(filters, at())
    assert {page.page, page.total, length(page.items)} == {6, 55, 5}
    assert page.configuration_summary["scope_total"] == 57
    assert page.configuration_summary["global_total"] == 60
    assert page.configuration_summary["global_counts"]["saved"] == 5
    assert {:ok, selection} = Monitoring.select_bulk_configuration(filters)
    assert selection["total_matching"] == 55
    assert length(selection["selection"]) == 55

    active_ids = Enum.take(prepared_ids, 50)

    Repo.update_all(from(a in Assignment, where: a.id in ^active_ids),
      set: [active_generation: 1]
    )

    after_progress = Monitoring.list_checks(filters, at())
    assert {after_progress.page, after_progress.total, length(after_progress.items)} == {1, 5, 5}
    assert after_progress.configuration_summary["global_counts"]["active"] == 50
    assert after_progress.configuration_summary["scope_total"] == 57
  end

  defp set_stage(id, fields),
    do: Repo.get!(Assignment, id) |> Ecto.Changeset.change(fields) |> Repo.update!()

  defp publish(keys) do
    checks =
      for key <- keys do
        %{
          "key" => key,
          "label" => key,
          "environment" => "adoption-test",
          "definition_revision" => String.duplicate("b", 64),
          "params_owner" => "ui",
          "parameter_contract" => "limit.v1",
          "parameter_schema" => %{"fields" => %{"limit" => %{"type" => "integer"}}},
          "params" => %{"limit" => 80},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "result",
              "label" => key,
              "target" => %{"key" => key, "kind" => "node", "label" => key}
            }
          ]
        }
      end

    assert {:ok, _} =
             Inventory.reconcile(
               control()
               |> Map.merge(%{
                 "runner_label" => "Adoption inspection runner",
                 "source_id" => "adoption.source",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               at()
             )

    Repo.all(
      from a in Assignment, where: a.source_id == "adoption.source", select: {a.source_key, a.id}
    )
    |> Map.new()
  end
end
