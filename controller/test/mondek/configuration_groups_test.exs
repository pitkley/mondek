# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationGroupsTest do
  use Mondek.DataCase, async: false
  alias Mondek.{ConfigurationRules, Parameters}

  test "declarations group repeated observers and complete multi-result executions" do
    first = inventory()
    check = hd(first["checks"])
    output = hd(check["outputs"])
    check = Map.put(check, "outputs", [output, Map.put(output, "key", "second")])
    first = Map.put(first, "checks", [check])
    assert {:ok, _} = Monitoring.inventory(first, at())
    second = inventory() |> put_in(["checks", Access.at(0), "label"], "Other volume")
    assert {:ok, _} = Monitoring.inventory(second, at())

    assert %{"total" => 1, "groups" => [group]} = ConfigurationRules.groups("Orders")
    assert group["check_count"] == 2
    assert group["result_count"] == 3
    assert group["label_count"] == 2
    assert group["environments"] == ["production"]
    assert group["schema_fingerprint"] == Parameters.schema_fingerprint(check["parameter_schema"])
    assert {:ok, seed} = ConfigurationRules.seed(group["check_id"])
    assert seed["parameter_contract"] == group["parameter_contract"]
    assert group["fields"] == [%{"key" => "limit", "label" => "limit"}]
  end

  test "source, explicit contract and exact normalized semantics determine compatibility" do
    base = inventory()
    assert {:ok, _} = Monitoring.inventory(base, at())

    for {path, value} <- [
          {["source_id"], "other-source"},
          {["checks", Access.at(0), "parameter_contract"], "other-contract"},
          {["checks", Access.at(0), "parameter_schema", "fields", "limit", "unit"], "bytes"},
          {["checks", Access.at(0), "parameter_schema", "fields", "limit", "label"], "Queue size"}
        ] do
      assert {:ok, _} = Monitoring.inventory(put_in(inventory(), path, value), at())
    end

    explicit =
      inventory()
      |> put_in(["checks", Access.at(0), "parameter_schema", "comparisons"], [])
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "maximum"], 100.0)

    assert {:ok, _} = Monitoring.inventory(explicit, at())
    assert %{"total" => 5, "groups" => groups} = ConfigurationRules.groups()
    assert Enum.sum(Enum.map(groups, & &1["check_count"])) == 6
    assert %{"total" => 1, "groups" => [named]} = ConfigurationRules.groups("queue SIZE")
    assert named["fields"] == [%{"key" => "limit", "label" => "Queue size"}]
    assert ConfigurationRules.groups("other-source")["total"] == 1
    assert ConfigurationRules.groups("other-contract")["total"] == 1
  end

  test "broad review retains incompatible current units without approving a partial group" do
    first = inventory()
    assert {:ok, _} = Monitoring.inventory(first, at())

    second =
      inventory()
      |> put_in(["checks", Access.at(0), "label"], "Bytes pending")
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "unit"], "bytes")

    assert {:ok, _} = Monitoring.inventory(second, at())

    row =
      Repo.get_by!(Assignment, runner_id: first["installation_id"], source_id: first["source_id"])

    assert {:ok, proposal} = ConfigurationRules.seed(row.id)

    proposal =
      Map.merge(proposal, %{
        "target_kind" => nil,
        "target_key" => nil,
        "environment" => nil,
        "params" => %{"limit" => 65}
      })

    assert {:ok, review} = ConfigurationRules.preview(proposal)
    assert review["counts"]["matched"] == 2
    assert review["scope_counts"]["proposed_full"] == 2
    assert review["scope_counts"]["excluded"] == 0
    assert review["counts"]["conflicts"] == 1
    assert review["review_token"] == nil
    current = Enum.find(review["rows"], &(&1["label"] == "Bytes pending"))
    assert current["current_params"] == %{"limit" => 80}
    assert current["parameter_schema"]["fields"]["limit"]["unit"] == "bytes"
    assert current["proposed_params"] == nil
    assert current["error"] =~ "different parameter schema"
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 80}

    # An instance exception can mask this incompatible rule. Both the before
    # and after values still have the assignment's units, not the rule's.
    other = Repo.get!(Assignment, current["id"])
    assert {:ok, _} = Monitoring.save_assignment(other.id, other.revision, %{"limit" => 90})
    assert {:ok, masked} = ConfigurationRules.preview(proposal)
    assert masked["counts"]["conflicts"] == 0
    assert masked["review_token"]
    unchanged = Enum.find(masked["rows"], &(&1["id"] == other.id))
    assert unchanged["proposed_params"] == %{"limit" => 90}
    assert unchanged["origin"] == %{"kind" => "exception"}
    assert unchanged["parameter_schema"]["fields"]["limit"]["unit"] == "bytes"
  end

  test "code-owned, retired and undeclared contracts never appear as shared groups" do
    for transform <- [
          &update_in(&1, ["checks", Access.at(0)], fn check ->
            check |> Map.put("params_owner", "source") |> Map.delete("parameter_contract")
          end),
          &update_in(&1, ["checks", Access.at(0)], fn check ->
            Map.delete(check, "parameter_contract")
          end)
        ] do
      assert {:ok, _} = Monitoring.inventory(transform.(inventory()), at())
    end

    retired = inventory()
    assert {:ok, _} = Monitoring.inventory(retired, at())

    assert {:ok, _} =
             Monitoring.inventory(%{retired | "inventory_revision" => 2, "checks" => []}, at())

    assert ConfigurationRules.groups() == %{
             "groups" => [],
             "total" => 0,
             "page" => 1,
             "pages" => 1,
             "page_size" => 25
           }
  end

  test "pagination covers all groups with bounded stable rows and literal search" do
    p = inventory()
    base = hd(p["checks"])

    checks =
      for n <- 1..61 do
        Map.merge(base, %{
          "key" => "volume-#{n}",
          "parameter_contract" => "volume-#{n}",
          "label" => "Volume #{String.pad_leading(to_string(n), 3, "0")}"
        })
      end

    assert {:ok, _} = Monitoring.inventory(Map.put(p, "checks", checks), at())
    first = ConfigurationRules.groups("volume", 1)
    second = ConfigurationRules.groups("volume", "2")
    last = ConfigurationRules.groups("volume", 9999)
    assert first["total"] == 61
    assert first["pages"] == 3
    assert length(first["groups"]) == 25
    assert length(second["groups"]) == 25
    assert last["page"] == 3
    assert length(last["groups"]) == 11

    assert Enum.uniq_by(first["groups"] ++ second["groups"] ++ last["groups"], & &1["check_id"])
           |> length() == 61

    assert ConfigurationRules.groups("%_")["total"] == 0
    assert ConfigurationRules.groups("volume", "invalid") == first
  end

  test "scope suggestions preserve identity, names and bounded complete-group choices" do
    p = inventory()
    base = hd(p["checks"])
    output = hd(base["outputs"])

    checks =
      for n <- 1..103 do
        Map.merge(base, %{
          "key" => "volume-#{n}",
          "environment" => "env-#{n}",
          "environment_label" => "Environment #{n}",
          "outputs" => [
            Map.put(output, "target", %{
              "kind" => "volume",
              "key" => "volume-#{n}",
              "label" => "Volume #{n}"
            })
          ]
        })
      end

    assert {:ok, _} = Monitoring.inventory(Map.put(p, "checks", checks), at())
    choices = ConfigurationRules.scope_choices(p["source_id"], base["parameter_contract"])
    assert length(choices["environments"]) == 100
    assert length(choices["targets"]) == 100
    assert choices["environments_truncated"]
    assert choices["targets_truncated"]
    assert %{"id" => "env-1", "label" => "Environment 1"} in choices["environments"]
    assert %{"kind" => "volume", "key" => "volume-1", "label" => "Volume 1"} in choices["targets"]
    assert ConfigurationRules.scope_choices("absent", base["parameter_contract"])["targets"] == []
    [group] = ConfigurationRules.groups()["groups"]
    assert group["environment_count"] == 103
    assert length(group["environments"]) == 5
  end

  test "omitted string length defaults and explicit defaults remain one group" do
    p = inventory()
    check = hd(p["checks"])

    check =
      Map.merge(check, %{
        "parameter_schema" => %{"fields" => %{"path" => %{"type" => "string"}}},
        "params" => %{"path" => "/data"}
      })

    assert {:ok, _} = Monitoring.inventory(Map.put(p, "checks", [check]), at())
    explicit = put_in(check, ["parameter_schema", "fields", "path", "max_length"], 2048)
    assert {:ok, _} = Monitoring.inventory(Map.put(inventory(), "checks", [explicit]), at())
    assert %{"total" => 1, "groups" => [%{"check_count" => 2}]} = ConfigurationRules.groups()
  end

  test "scope counts separate narrowed declaration, exclusions and prior enabled impact" do
    first = inventory()
    assert {:ok, _} = Monitoring.inventory(first, at())

    assert {:ok, _} =
             Monitoring.inventory(
               put_in(inventory(), ["checks", Access.at(0), "environment"], "staging"),
               at()
             )

    other =
      put_in(
        inventory(),
        ["checks", Access.at(0), "outputs", Access.at(0), "target", "key"],
        "volume:other"
      )

    assert {:ok, _} = Monitoring.inventory(other, at())

    row =
      Repo.get_by!(Assignment, runner_id: first["installation_id"], source_id: first["source_id"])

    assert {:ok, seed} = ConfigurationRules.seed(row.id)
    broad = Map.merge(seed, %{"environment" => nil, "target_kind" => nil, "target_key" => nil})
    assert {:ok, preview} = ConfigurationRules.preview(broad)
    assert preview["scope_counts"]["proposed_full"] == 3
    assert {:ok, saved} = ConfigurationRules.apply(preview["review_token"], broad)

    narrowed =
      Map.merge(saved["rule"], %{
        "environment" => "production",
        "target_kind" => "volume",
        "target_key" => "volume:orders"
      })

    assert {:ok, review} = ConfigurationRules.preview(narrowed)
    assert review["counts"]["matched"] == 3

    assert review["scope_counts"] == %{
             "source_contract_total" => 3,
             "proposed_full" => 1,
             "proposed_partial" => 0,
             "excluded" => 2,
             "leaving_previous_scope" => 2,
             "released_from_rule" => 2,
             "proposed_enabled" => true
           }

    disabled = Map.put(saved["rule"], "enabled", false)
    assert {:ok, review} = ConfigurationRules.preview(disabled)
    assert review["counts"]["matched"] == 3
    assert review["scope_counts"]["proposed_full"] == 3
    assert review["scope_counts"]["excluded"] == 0
    assert review["scope_counts"]["leaving_previous_scope"] == 0
    assert review["scope_counts"]["released_from_rule"] == 3
    refute review["scope_counts"]["proposed_enabled"]

    disabled_new = Map.put(broad, "enabled", false)
    assert {:ok, review} = ConfigurationRules.preview(disabled_new)
    assert review["counts"]["matched"] == 0
    assert review["scope_counts"]["proposed_full"] == 3
    assert review["scope_counts"]["released_from_rule"] == 0
  end

  test "partially matching multi-target execution remains in scope and visibly conflicts" do
    p = inventory()
    check = hd(p["checks"])
    output = hd(check["outputs"])
    other = output |> Map.put("key", "other") |> put_in(["target", "key"], "volume:other")
    p = put_in(p, ["checks", Access.at(0), "outputs"], [output, other])
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = Repo.get_by!(Assignment, runner_id: p["installation_id"], source_id: p["source_id"])
    assert {:ok, seed} = ConfigurationRules.seed(row.id)
    proposal = Map.merge(seed, %{"target_kind" => "volume", "target_key" => "volume:orders"})
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    assert preview["scope_counts"]["proposed_full"] == 0
    assert preview["scope_counts"]["proposed_partial"] == 1
    assert preview["scope_counts"]["excluded"] == 0
    assert preview["counts"]["matched"] == 1
    assert preview["counts"]["conflicts"] == 1
    assert preview["review_token"] == nil
  end

  defp inventory(runner \\ Ecto.UUID.generate()) do
    control(%{
      "installation_id" => runner,
      "session_id" => Ecto.UUID.generate(),
      "prepared" => %{}
    })
    |> Map.merge(%{
      "runner_label" => "Volume observer",
      "source_id" => "durable-volume-monitoring",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [
        %{
          "key" => "volume",
          "label" => "Orders volume",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => "production",
          "params_owner" => "ui",
          "parameter_contract" => "volume.pending-items.v1",
          "params" => %{"limit" => 80},
          "parameter_schema" => %{
            "fields" => %{
              "limit" => %{
                "type" => "integer",
                "unit" => "items",
                "minimum" => 0,
                "maximum" => 100
              }
            }
          },
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "pending",
              "label" => "Pending items",
              "target" => %{
                "kind" => "volume",
                "key" => "volume:orders",
                "label" => "Orders volume"
              }
            }
          ]
        }
      ]
    })
  end
end
