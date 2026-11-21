# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.SchemaMigrationPreviewTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest, except: [json_response: 2]
  import Mondek.APIResponse
  import Plug.Conn

  alias Mondek.{
    Configuration,
    ConfigurationRepository,
    ConfigurationRule,
    ConfigurationRules,
    SchemaMigrationPreview,
    SourceInventory
  }

  @endpoint MondekWeb.Endpoint
  @path "/api/v1/configuration/schema-migration/preview"

  test "the HTTP preview identifies a shared rule and an exception without changing saved state" do
    production = inventory("production")
    [check] = production["checks"]
    sibling = %{check | "key" => "volume-sibling"}
    production = %{production | "checks" => [check, sibling]}
    matching_peer = inventory("production")
    staging = inventory("staging")

    for publication <- [production, matching_peer, staging],
        do: assert({:ok, _} = Monitoring.inventory(publication, at()))

    original = assignment(production)
    {:ok, proposal} = ConfigurationRules.seed(original.id)
    proposal = Map.merge(proposal, %{"environment" => "production", "params" => %{"limit" => 60}})
    assert {:ok, rule_plan} = ConfigurationRules.preview(proposal)

    assert {:ok, %{"rule" => rule}} =
             ConfigurationRules.apply(rule_plan["review_token"], proposal)

    row = assignment(production)
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 92})
    saved = assignment(production)
    accepted = snapshot()
    candidate = next_inventory(production, [revised_check(check), sibling])
    assert {:ok, direct} = SchemaMigrationPreview.preview(candidate)

    report =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(@path, Jason.encode!(candidate))
      |> json_response(200)

    assert report == direct
    assert report["candidate"]["publication_status"] == "candidate"
    assert report["accepted"]["inventory_revision"] == 1
    assert report["candidate"]["inventory_revision"] == 2
    assert [check_change, rule_change] = report["rows"]
    assert check_change["accepted"]["assignment_id"] == saved.id
    assert check_change["accepted"]["revision"] == saved.revision
    assert check_change["accepted"]["desired_generation"] == saved.desired_generation
    assert check_change["candidate"]["assignment_id"] == nil
    assert check_change["candidate"]["installation_id"] == production["installation_id"]
    assert check_change["defaults_changed_fields"] == ["ceiling", "limit"]
    assert check_change["saved_default_findings"]["invalid_fields"] == ["limit"]
    assert check_change["instance_exception"]["findings"]["invalid_fields"] == ["limit"]
    assert check_change["blockers"] == ["removed_or_reinterpreted_field:limit"]

    assert [%{"field" => "ceiling"}, %{"field" => "limit", "unit_after" => "seconds"}] =
             check_change["fields"]

    assert rule_change["rule_id"] == rule["id"]
    assert rule_change["candidate_schema_changed"]
    assert rule_change["scope_before"] == "full"
    assert rule_change["scope_after"] == "full"
    assert rule_change["rule_value_findings"]["missing_fields"] == ["ceiling"]
    assert rule_change["rule_value_findings"]["invalid_fields"] == ["limit"]
    assert rule_change["other_matching_assignments"] == 2
    assert rule_change["other_publisher_count"] == 1
    assert rule_change["other_publisher_sample"] == [matching_peer["installation_id"]]
    assert snapshot() == accepted

    assert {:ok, _} = Monitoring.save_assignment(saved.id, saved.revision, %{"limit" => 39})
    assert {:ok, later} = SchemaMigrationPreview.preview(candidate)
    assert later["candidate"]["digest"] == report["candidate"]["digest"]
    refute later["review_digest"] == report["review_digest"]
  end

  test "membership changes, read pages and exact inventory replay have distinct diagnostics" do
    original = inventory("production")
    assert {:ok, _} = Monitoring.inventory(original, at())
    assert {:ok, accepted} = SchemaMigrationPreview.preview(original)
    assert accepted["candidate"]["publication_status"] == "accepted_replay"
    assert accepted["rows"] == []

    different = put_in(original, ["checks", Access.at(0), "params", "limit"], 20)
    assert {:ok, conflict} = SchemaMigrationPreview.preview(different)
    assert conflict["candidate"]["publication_status"] == "inventory_conflict"
    refute conflict["candidate"]["digest"] == accepted["candidate"]["digest"]

    additions = for index <- 1..20, do: %{hd(original["checks"]) | "key" => "added-#{index}"}
    candidate = next_inventory(original, additions)
    assert {:ok, first} = SchemaMigrationPreview.preview(candidate)
    assert first["check_count"] == 21
    assert first["total"] == 21
    assert Enum.all?(first["rows"], &(&1["change"] == "added"))
    assert {:ok, second} = SchemaMigrationPreview.preview(candidate, 2)
    assert [%{"check_key" => "volume", "change" => "withdrawn"}] = second["rows"]
    assert second["review_digest"] == first["review_digest"]

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(@path <> "?page=2", Jason.encode!(candidate))
           |> json_response(200) == second

    assert {:ok, none} = SchemaMigrationPreview.preview(candidate, 3)
    assert none["rows"] == []

    assert {:error, :not_found} =
             SchemaMigrationPreview.preview(
               Map.put(candidate, "installation_id", Ecto.UUID.generate())
             )
  end

  defp snapshot do
    assert {:ok, git} = ConfigurationRepository.read_state()

    Map.new([Assignment, Configuration, ConfigurationRule, SourceInventory], fn module ->
      {module, Repo.all(from row in module, order_by: row.id)}
    end)
    |> Map.put(:repository, git)
  end

  defp assignment(p) do
    Repo.get_by!(Assignment,
      runner_id: p["installation_id"],
      source_id: p["source_id"],
      source_key: "volume"
    )
  end

  defp next_inventory(p, checks) do
    %{
      p
      | "inventory_revision" => 2,
        "source_revision" => String.duplicate("f", 64),
        "checks" => checks
    }
  end

  defp inventory(environment) do
    control(%{"installation_id" => Ecto.UUID.generate(), "session_id" => Ecto.UUID.generate()})
    |> Map.merge(%{
      "runner_label" => "Schema preview test observer",
      "source_id" => "schema-preview",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [
        %{
          "key" => "volume",
          "label" => "Volume backlog",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => environment,
          "params_owner" => "ui",
          "parameter_contract" => "volume.items.v1",
          "params" => %{"limit" => 80},
          "parameter_schema" => %{
            "fields" => %{"limit" => %{"type" => "integer", "unit" => "items", "maximum" => 100}}
          },
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "pending",
              "label" => "Pending items",
              "target" => %{"kind" => "volume", "key" => "orders", "label" => "Orders volume"}
            }
          ]
        }
      ]
    })
  end

  defp revised_check(check) do
    %{
      check
      | "definition_revision" => String.duplicate("c", 64),
        "params" => %{"limit" => 10, "ceiling" => 35},
        "parameter_schema" => %{
          "fields" => %{
            "limit" => %{"type" => "integer", "unit" => "seconds", "maximum" => 45},
            "ceiling" => %{"type" => "integer", "unit" => "seconds"}
          },
          "comparisons" => [%{"left" => "limit", "op" => "lt", "right" => "ceiling"}]
        }
    }
  end
end
