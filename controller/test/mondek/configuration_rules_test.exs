# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationRulesTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    ConfigurationRules,
    ConfigurationRule,
    ConfigurationRuleDiagnostic,
    Configuration,
    SourceInventory,
    ResultStream
  }

  test "instance review is non-mutating and rejects intervening values or policy changes" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)

    assert {:ok, preview} =
             ConfigurationRules.preview_instance(row.id, row.revision, %{"limit" => 42})

    assert Repo.get!(Assignment, row.id).params == %{"limit" => 80}

    assert {:error, :stale} =
             Monitoring.save_assignment(
               row.id,
               row.revision,
               %{"limit" => 41},
               preview["review_token"]
             )

    create_rule(row, %{"limit" => 70})
    assert {:error, :stale} = ConfigurationRules.apply_instance(preview["review_token"])
    current = Repo.get!(Assignment, row.id)

    assert {:ok, fresh} =
             ConfigurationRules.preview_instance(current.id, current.revision, %{"limit" => 42})

    assert {:ok, saved} = ConfigurationRules.apply_instance(fresh["review_token"])
    assert saved["params"] == %{"limit" => 42}
    assert saved["instance_exception"] == %{"limit" => 42}
    assert {:error, :stale} = ConfigurationRules.apply_instance(fresh["review_token"])
    assert {:error, _} = ConfigurationRules.apply_instance("not-a-review")
  end

  test "a rule survives zero matches and configures the same subject on a different observer" do
    first = inventory()
    assert {:ok, _} = Monitoring.inventory(first, at())
    row = assignment(first)
    assert row.source_defaults == %{"limit" => 80}
    assert row.instance_exception == nil
    rule = create_rule(row, %{"limit" => 65})
    current = Repo.get!(Assignment, row.id)
    assert current.params == %{"limit" => 65}
    assert current.configuration_origin["rule_id"] == rule["id"]

    generation =
      Repo.get_by!(Configuration, assignment_id: row.id, generation: current.desired_generation)

    assert generation.definition["configuration_origin"]["rule_revision"] == 1

    assert {:ok, _} =
             Monitoring.inventory(%{first | "inventory_revision" => 2, "checks" => []}, at())

    assert {:ok, dormant} = ConfigurationRules.get(rule["id"])
    assert dormant["match_count"] == 0
    second = inventory(Ecto.UUID.generate())
    assert {:ok, _} = Monitoring.inventory(second, at())
    moved = assignment(second)
    assert moved.id != row.id
    assert moved.params == %{"limit" => 65}
    assert moved.configuration_origin["rule_id"] == rule["id"]
    assert Repo.get!(Assignment, row.id).retired_at
    assert Repo.aggregate(ResultStream, :count, :id) == 5
  end

  test "highest priority wins, ties conflict, an exception wins and clearing it resolves rules" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    low = create_rule(row, %{"limit" => 60})
    assert {:ok, seed} = ConfigurationRules.seed(row.id)

    high_proposal =
      seed |> Map.merge(%{"name" => "Higher", "priority" => 10, "params" => %{"limit" => 40}})

    assert {:ok, preview} = ConfigurationRules.preview(high_proposal)
    assert preview["counts"]["changed"] == 1
    assert {:ok, high} = ConfigurationRules.apply(preview["review_token"], high_proposal)
    row = Repo.get!(Assignment, row.id)
    assert row.params == %{"limit" => 40}

    assert {:ok, conflict} = ConfigurationRules.preview(%{high_proposal | "name" => "Tie"})
    assert conflict["counts"]["conflicts"] == 1
    assert conflict["review_token"] == nil
    assert Repo.aggregate(ConfigurationRule, :count) == 2

    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 25})
    row = Repo.get!(Assignment, row.id)
    assert row.configuration_origin == %{"kind" => "exception"}
    assert row.instance_exception == %{"limit" => 25}
    assert {:ok, reset} = ConfigurationRules.preview_reset(row.id, row.revision)
    assert reset["proposed_params"] == %{"limit" => 40}
    assert {:ok, reset_row} = ConfigurationRules.reset_exception(reset["review_token"])
    assert reset_row["instance_exception"] == nil

    high = high["rule"] |> Map.put("enabled", false)
    assert {:ok, preview} = ConfigurationRules.preview(high)
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], high)
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 60}
    low = Map.put(low, "enabled", false)
    assert {:ok, preview} = ConfigurationRules.preview(low)
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], low)
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 80}
  end

  test "a new disabled rule can be reviewed and saved without changing matching checks" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    assert {:ok, seed} = ConfigurationRules.seed(row.id)
    proposal = Map.merge(seed, %{"enabled" => false, "params" => %{"limit" => 45}})
    assert {:ok, review} = ConfigurationRules.preview(proposal)
    assert review["counts"]["matched"] == 0
    assert is_binary(review["review_token"])
    assert {:ok, applied} = ConfigurationRules.apply(review["review_token"], proposal)
    assert applied["changed_count"] == 0
    assert applied["rule"]["enabled"] == false
    assert Repo.get!(Assignment, row.id) == row
  end

  test "a new enabled rule with no current matches configures a future target" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    assert {:ok, seed} = ConfigurationRules.seed(row.id)
    proposal = Map.merge(seed, %{"target_key" => "volume:future", "params" => %{"limit" => 45}})
    assert {:ok, review} = ConfigurationRules.preview(proposal)
    assert review["counts"]["matched"] == 0
    assert is_binary(review["review_token"])
    assert {:ok, applied} = ConfigurationRules.apply(review["review_token"], proposal)
    assert applied["changed_count"] == 0
    assert Repo.get!(Assignment, row.id) == row

    future =
      inventory(Ecto.UUID.generate())
      |> put_in(
        ["checks", Access.at(0), "outputs", Access.at(0), "target", "key"],
        "volume:future"
      )

    assert {:ok, _} = Monitoring.inventory(future, at())
    assert assignment(future).params == %{"limit" => 45}
    assert assignment(future).configuration_origin["rule_id"] == applied["rule"]["id"]
  end

  test "review binds new membership and exact proposal rather than a live selector" do
    first = inventory()
    assert {:ok, _} = Monitoring.inventory(first, at())
    row = assignment(first)
    assert {:ok, proposal} = ConfigurationRules.seed(row.id)
    proposal = Map.put(proposal, "params", %{"limit" => 60})
    assert {:ok, preview} = ConfigurationRules.preview(proposal)

    assert {:error, :review_changed} =
             ConfigurationRules.apply(preview["review_token"], Map.put(proposal, "priority", 10))

    assert {:ok, _} = Monitoring.inventory(inventory(Ecto.UUID.generate()), at())
    assert {:error, :stale} = ConfigurationRules.apply(preview["review_token"], proposal)
    assert Repo.aggregate(ConfigurationRule, :count) == 0
  end

  test "a rejected incompatible incoming schema retains runtime and records durable diagnostics" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    rule = create_rule(row, %{"limit" => 60})
    before = Repo.get!(Assignment, row.id)

    changed =
      put_in(p, ["checks", Access.at(0), "parameter_schema", "fields", "limit", "unit"], "bytes")
      |> Map.put("inventory_revision", 2)

    assert {:error, {:invalid, reason}} = Monitoring.inventory(changed, at())
    assert reason =~ "different parameter schema"
    assert Repo.get!(Assignment, row.id) == before

    assert Repo.get_by!(SourceInventory,
             runner_id: p["installation_id"],
             source_id: p["source_id"]
           ).revision == 1

    assert {:ok, inspected} = ConfigurationRules.get(rule["id"])
    assert [%{"rule_ids" => [id]}] = inspected["diagnostics"]
    assert id == rule["id"]
    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 3), at())
    assert Repo.aggregate(ConfigurationRuleDiagnostic, :count) == 0
  end

  test "an incompatible new observer is visible even without an accepted assignment" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    rule = create_rule(assignment(p), %{"limit" => 60})

    second =
      inventory(Ecto.UUID.generate())
      |> put_in(
        ["checks", Access.at(0), "parameter_schema", "fields", "limit", "label"],
        "Changed semantics"
      )

    assert {:error, {:invalid, _}} = Monitoring.inventory(second, at())
    assert assignment(second) == nil
    assert {:ok, inspected} = ConfigurationRules.get(rule["id"])
    assert length(inspected["diagnostics"]) == 1
    assert hd(inspected["diagnostics"])["runner_id"] == second["installation_id"]
  end

  test "a target-specific rule cannot change sibling subjects in a shared execution" do
    p = inventory()
    output = hd(hd(p["checks"])["outputs"])

    other = %{
      output
      | "key" => "other",
        "target" => %{"key" => "volume:other", "kind" => "volume", "label" => "Other"}
    }

    p = put_in(p, ["checks", Access.at(0), "outputs"], [output, other])
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert {:ok, proposal} = ConfigurationRules.seed(assignment(p).id)
    proposal = Map.merge(proposal, %{"target_kind" => "volume", "target_key" => "volume:orders"})
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    assert preview["counts"]["conflicts"] == 1
    assert hd(preview["rows"])["error"] =~ "several targets"
    broad = Map.merge(proposal, %{"target_kind" => nil, "target_key" => nil})
    assert {:ok, preview} = ConfigurationRules.preview(broad)
    assert preview["counts"]["conflicts"] == 0
  end

  test "schema delegation cannot be invented and dormant captured schemas remain editable" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    assert {:ok, proposal} = ConfigurationRules.seed(row.id)
    forged = put_in(proposal, ["parameter_schema", "fields", "limit", "unit"], "seconds")
    assert {:error, {:invalid, _}} = ConfigurationRules.preview(forged)
    rule = create_rule(row, %{"limit" => 60})
    assert {:ok, _} = Monitoring.inventory(%{p | "inventory_revision" => 2, "checks" => []}, at())
    changed = Map.put(rule, "params", %{"limit" => 55})
    assert {:ok, preview} = ConfigurationRules.preview(changed)
    assert preview["counts"]["matched"] == 0
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], changed)
  end

  test "source namespace lock serializes a new inventory against reviewed save" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert {:ok, proposal} = ConfigurationRules.seed(assignment(p).id)
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    parent = self()

    task =
      Task.async(fn ->
        Mondek.ConfigurationRepository.transaction("inventory", fn ->
          ConfigurationRules.lock_source!(p["source_id"])
          send(parent, :locked)

          receive do
            :continue -> :ok
          end

          Monitoring.inventory(inventory(Ecto.UUID.generate()), at())
        end)
      end)

    assert_receive :locked
    saving = Task.async(fn -> ConfigurationRules.apply(preview["review_token"], proposal) end)
    refute Task.yield(saving, 20)
    send(task.pid, :continue)
    assert {:ok, {:ok, _}} = Task.await(task)
    assert {:error, :stale} = Task.await(saving)
  end

  test "source defaults remain current while a preserved exception masks them" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 60})

    revised =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "params", "limit"], 65)
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "maximum"], 70)

    assert {:ok, _} = Monitoring.inventory(revised, at())
    row = Repo.get!(Assignment, row.id)
    assert row.params == %{"limit" => 60}
    assert row.source_defaults == %{"limit" => 65}
    assert {:ok, reset} = ConfigurationRules.preview_reset(row.id, row.revision)
    assert reset["proposed_params"] == %{"limit" => 65}
    assert {:ok, _} = ConfigurationRules.reset_exception(reset["review_token"])
  end

  test "late rejected inventories cannot overwrite newer diagnostic reasons" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    rule = create_rule(assignment(p), %{"limit" => 60})

    diagnostic = %{
      source_id: p["source_id"],
      runner_id: p["installation_id"],
      source_key: "volume",
      source_revision: p["source_revision"],
      inventory_revision: 3,
      rule_ids: [rule["id"]],
      message: "Newest rejection"
    }

    assert :ok = ConfigurationRules.record_rejection(diagnostic, at())

    assert :ok =
             ConfigurationRules.record_rejection(
               %{diagnostic | inventory_revision: 2, message: "Delayed obsolete rejection"},
               DateTime.add(at(), 1)
             )

    assert Repo.one!(ConfigurationRuleDiagnostic).message == "Newest rejection"
    assert Repo.one!(ConfigurationRuleDiagnostic).inventory_revision == 3
  end

  @tag timeout: 120_000
  test "enabled rule admission stays bounded and disabled oversized scopes remain editable" do
    p = inventory()
    check = hd(p["checks"])
    p = Map.put(p, "checks", Enum.map(1..512, &Map.put(check, "key", "volume-#{&1}")))
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = Repo.one!(from a in Assignment, where: a.source_id == ^p["source_id"], limit: 1)
    rule = create_rule(row, %{"limit" => 60})
    additional = inventory(Ecto.UUID.generate())
    assert {:error, {:invalid, reason}} = Monitoring.inventory(additional, at())
    assert reason =~ "512 current checks"
    assert assignment(additional) == nil
    assert {:ok, detail} = ConfigurationRules.get(rule["id"])
    assert detail["match_count"] == 512
    disabled = Map.put(rule, "enabled", false)
    assert {:ok, preview} = ConfigurationRules.preview(disabled)
    assert {:ok, saved} = ConfigurationRules.apply(preview["review_token"], disabled)
    assert {:ok, _} = Monitoring.inventory(additional, at())
    assert {:ok, detail} = ConfigurationRules.get(rule["id"])
    assert detail["match_count"] == 513
    assert hd(ConfigurationRules.list()["rules"])["match_count"] == 513
    narrowed = saved["rule"] |> Map.put("target_key", "volume:future") |> Map.put("enabled", true)
    assert {:ok, preview} = ConfigurationRules.preview(narrowed)
    assert preview["counts"]["matched"] == 0
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], narrowed)
  end

  test "provenance-only rule changes preserve measured recovery meaning" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = assignment(p)
    activate(p, row)
    assert disposition(ingest_for(p, row, "CRIT", 1)) == "current"
    rule = create_rule(row, row.params)
    renamed = Map.put(rule, "name", "Renamed only")
    assert {:ok, preview} = ConfigurationRules.preview(renamed)
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], renamed)
    row = Repo.get!(Assignment, row.id)
    activate(p, row)
    assert disposition(ingest_for(p, row, "OK", 2)) == "current"
    assert Repo.get_by!(Incident, assignment_id: row.id).closure_reason == "measured_recovery"
  end

  defp activate(p, row) do
    assert {:ok, _} =
             Monitoring.control(
               control(%{
                 "installation_id" => p["installation_id"],
                 "session_id" => p["session_id"],
                 "prepared" => %{row.id => row.desired_generation}
               }),
               at()
             )
  end

  defp ingest_for(p, row, health, sequence) do
    observation =
      measurement(health, sequence, %{
        "assignment_id" => row.id,
        "installation_id" => p["installation_id"],
        "session_id" => p["session_id"],
        "generation" => row.desired_generation,
        "results" => [
          %{
            "key" => "pending",
            "health" => health,
            "summary" => "Measured pending items",
            "source_at" => "2009-09-15T08:00:00.010000Z"
          }
        ]
      })

    Monitoring.ingest(
      envelope([observation], %{
        "installation_id" => p["installation_id"],
        "session_id" => p["session_id"]
      }),
      at()
    )
  end

  defp create_rule(row, params) do
    assert {:ok, proposal} = ConfigurationRules.seed(row.id)
    proposal = Map.put(proposal, "params", params)
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    assert preview["review_token"]
    assert {:ok, result} = ConfigurationRules.apply(preview["review_token"], proposal)
    result["rule"]
  end

  defp assignment(p),
    do:
      Repo.one(
        from a in Assignment,
          where:
            a.runner_id == ^p["installation_id"] and a.source_id == ^p["source_id"] and
              is_nil(a.retired_at)
      )

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
