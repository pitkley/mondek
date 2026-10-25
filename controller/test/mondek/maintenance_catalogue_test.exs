# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceCatalogueTest do
  use Mondek.DataCase, async: false
  alias Mondek.{MaintenanceSelection, ResultStream}

  test "target identities preserve namespaces and counts include observers outside discovery filters" do
    {first, _} = publish("catalogue", "production", ["orders"])
    publish("catalogue", "production", ["orders"])
    publish("catalogue", "staging", ["orders"])
    publish("catalogue", nil, ["orders"])
    publish("other-catalogue", "production", ["orders"])
    filters = %{"kind" => "target", "source_id" => "catalogue"}
    assert MaintenanceSelection.list(filters)["total"] == 3
    restricted = Map.put(filters, "runner_id", first["installation_id"])
    assert %{"total" => 1, "items" => [row]} = MaintenanceSelection.list(restricted)
    assert row["matched_results"] == 2
    assert row["observer_count"] == 2
    selected = MaintenanceSelection.normalize([row, row])
    assert length(selected) == 1
    publish("catalogue", "production", ["orders"])
    assert [updated] = MaintenanceSelection.describe(selected)
    assert updated["matched_results"] == 3
    assert updated["observer_count"] == 3
  end

  test "paging is bounded and clamped while add all captures identities rather than filters" do
    publish(
      "catalogue-pages",
      nil,
      Enum.map(1..30, &"volume-#{String.pad_leading(to_string(&1), 2, "0")}")
    )

    filters = %{"kind" => "target", "source_id" => "catalogue-pages"}
    one = MaintenanceSelection.list(filters)
    two = MaintenanceSelection.list(Map.put(filters, "page", "2"))
    assert one["total"] == 30
    assert length(one["items"]) == 25
    assert length(two["items"]) == 5
    assert MaintenanceSelection.list(Map.put(filters, "page", "999"))["page"] == 2
    assert MaintenanceSelection.list(Map.put(filters, "page", "bad"))["page"] == 1

    assert MaintenanceSelection.list(
             Map.merge(filters, %{"page" => "2", "search" => "volume-30"})
           )["page"] == 1

    {:ok, all} = MaintenanceSelection.all(filters)
    assert MapSet.new(all, & &1["key"]) == MapSet.new(one["items"] ++ two["items"], & &1["key"])
    proposal = MaintenanceSelection.proposal(all, at())
    assert length(proposal["selections"]) == 30
    refute Map.has_key?(proposal, "search")
  end

  test "selected scopes follow readable labels across pages without changing canonical identity" do
    targets = Enum.map(0..30, &"volume-#{String.pad_leading(to_string(&1), 4, "0")}")
    {input, _} = publish("catalogue-order", nil, Enum.reverse(targets))

    {:ok, rows} =
      MaintenanceSelection.all(%{"kind" => "target", "source_id" => "catalogue-order"})

    canonical = MaintenanceSelection.normalize(rows)

    assert Enum.map(MaintenanceSelection.describe(Enum.reverse(rows)), & &1["label"]) == targets
    assert MaintenanceSelection.normalize(MaintenanceSelection.describe(rows)) == canonical

    assert {:ok, _} =
             Monitoring.inventory(%{input | "inventory_revision" => 2, "checks" => []}, at())

    retired = MaintenanceSelection.describe(rows ++ rows)
    assert Enum.map(retired, & &1["label"]) == Enum.map(targets, &"volume: #{&1}")
    assert MaintenanceSelection.normalize(retired) == canonical
  end

  test "withdrawal removes discovery choices but retained selections remain inspectable" do
    {input, [check]} = publish("catalogue-retired", nil, ["orders"])

    {:ok, targets} =
      MaintenanceSelection.all(%{"kind" => "target", "source_id" => "catalogue-retired"})

    {:ok, checks} =
      MaintenanceSelection.all(%{"kind" => "check", "source_id" => "catalogue-retired"})

    selected = checks ++ targets

    assert {:ok, _} =
             Monitoring.inventory(%{input | "inventory_revision" => 2, "checks" => []}, at())

    assert MaintenanceSelection.list(%{"source_id" => "catalogue-retired"})["total"] == 0
    described = MaintenanceSelection.describe(selected)
    assert length(described) == 2
    assert Enum.all?(described, &(&1["matched_results"] == 0 and not &1["available"]))
    assert Enum.find(described, &(&1["scope"] == "check"))["label"] == check.label
    assert Repo.one!(from s in ResultStream, where: s.assignment_id == ^check.id).retired_at
  end

  test "literal search and malformed filters cannot broaden selection or crash PostgreSQL" do
    publish("catalogue-literal", nil, ["literal_%", "literal-other"])

    for kind <- ["check", "target"] do
      filters = %{"kind" => kind, "source_id" => "catalogue-literal", "search" => "literal_%"}
      assert MaintenanceSelection.list(filters)["total"] == 1

      for field <- ~w(search environment source_id runner_id),
          invalid <- ["bad\0text", %{}, ["bad"]] do
        malformed = Map.put(filters, field, invalid)
        assert MaintenanceSelection.list(malformed)["total"] == 0
        assert {:ok, []} = MaintenanceSelection.all(malformed)
      end
    end

    refute MaintenanceSelection.valid?([%{"scope" => "selection"}])
    refute MaintenanceSelection.valid?([%{"scope" => "check", "assignment_id" => "invalid\0id"}])
    assert MaintenanceSelection.valid?([])
    assert MaintenanceSelection.normalize(%{}) == []
  end

  @tag timeout: 120_000
  test "adding more than 512 choices rejects the whole request without truncation" do
    publish("catalogue-limit", nil, Enum.map(1..257, &"first-#{&1}"))
    publish("catalogue-limit", nil, Enum.map(1..257, &"second-#{&1}"))

    for kind <- ["check", "target"] do
      filters = %{"kind" => kind, "source_id" => "catalogue-limit"}
      assert MaintenanceSelection.list(filters)["total"] == 514
      assert {:error, {:invalid, message}} = MaintenanceSelection.all(filters)
      assert message =~ "nothing was added"
      assert {:ok, [_]} = MaintenanceSelection.all(Map.put(filters, "search", "first-257"))
    end

    refute MaintenanceSelection.valid?(
             List.duplicate(
               %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000002"},
               513
             )
           )
  end

  defp publish(source, environment, targets) do
    input =
      control(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "prepared" => %{}
      })
      |> Map.merge(%{
        "runner_label" => "Catalogue observer",
        "source_id" => source,
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" =>
          Enum.with_index(targets, fn target, index ->
            %{
              "key" => "check-#{index}",
              "label" => "Check #{target}",
              "definition_revision" => String.duplicate("b", 64),
              "environment" => environment,
              "params_owner" => "source",
              "params" => %{},
              "parameter_schema" => %{"fields" => %{}},
              "interval_seconds" => 3,
              "timeout_seconds" => 2,
              "freshness_seconds" => 12,
              "outputs" => [
                %{
                  "key" => "value",
                  "label" => "Value #{target}",
                  "target" => %{"kind" => "volume", "key" => target, "label" => target}
                }
              ]
            }
          end)
      })

    assert {:ok, _} = Monitoring.inventory(input, at())

    checks =
      Repo.all(
        from a in Assignment,
          where: a.runner_id == ^input["installation_id"],
          order_by: a.source_key
      )

    {input, checks}
  end
end
