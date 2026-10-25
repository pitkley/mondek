# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationPolicyTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint

  alias Mondek.{
    ConfigurationPolicy,
    ConfigurationRules,
    ConfigurationRule,
    Configuration,
    ConfigurationPolicyReceipt,
    ConfigurationPolicyProject
  }

  test "managed apply and exact no-op preserve definitions, rules and generations" do
    {p, row} = publish()
    manifest = manifest()
    assert {:ok, plan} = ConfigurationPolicy.plan(manifest)
    assert plan["counts"]["create"] == 1

    assert [%{"source_defaults" => %{"limit" => 80}, "proposed_params" => %{"limit" => 60}}] =
             plan["rows"]

    assert {:ok, applied} = ConfigurationPolicy.apply(plan["review_token"], manifest)
    assert applied["changed_count"] == 1
    current = Repo.get!(Assignment, row.id)
    assert current.params == %{"limit" => 60}
    assert current.source_defaults == %{"limit" => 80}
    assert current.configuration_origin["managed_project"] == "personal"
    assert current.configuration_origin["managed_key"] == "volumes"
    rule = Repo.get_by!(ConfigurationRule, managed_project: "personal", managed_key: "volumes")
    assert {:ok, next} = ConfigurationPolicy.plan(manifest)
    assert next["counts"]["noop"] == 1
    assert next["counts"]["changed"] == 0
    assert {:ok, noop} = ConfigurationPolicy.apply(next["review_token"], next["manifest"])
    assert noop["changed_count"] == 0
    assert Repo.get!(Assignment, row.id) == current
    assert Repo.get!(ConfigurationRule, rule.id) == rule
    assert {:ok, exported} = ConfigurationPolicy.export("personal")
    assert exported == next["manifest"]
    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 2), at())
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 60}
  end

  test "lost-response replay is durable, exact and historical after later changes" do
    {_p, row} = publish()
    first = apply_manifest(manifest())
    assert Repo.aggregate(ConfigurationPolicyReceipt, :count) == 1

    assert {:ok, replay} =
             ConfigurationPolicy.apply(first.plan["review_token"], first.plan["manifest"])

    assert replay["replayed"]
    refute replay["superseded"]
    assert replay["receipts"] == first.response["receipts"]
    assert Repo.aggregate(ConfigurationPolicyReceipt, :count) == 1
    second = apply_manifest(put_in(manifest(), ["rules", Access.at(0), "params", "limit"], 40))

    assert {:ok, historic} =
             ConfigurationPolicy.apply(first.plan["review_token"], first.plan["manifest"])

    assert historic["replayed"] and historic["superseded"]
    assert historic["applied_project_revision"] == 1
    assert historic["current_project_revision"] == 2
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 40}
    assert Repo.aggregate(ConfigurationPolicyReceipt, :count) == 2

    assert {:error, :review_changed} =
             ConfigurationPolicy.apply(first.plan["review_token"], second.plan["manifest"])
  end

  test "expired unapplied plans fail while durable receipts remain replayable" do
    publish()
    %{plan: plan} = apply_manifest(manifest())

    {:ok, payload} =
      Phoenix.Token.verify(MondekWeb.Endpoint, "configuration-policy", plan["review_token"],
        max_age: 900
      )

    expired =
      Phoenix.Token.sign(MondekWeb.Endpoint, "configuration-policy", payload,
        signed_at: System.system_time(:second) - 1000
      )

    assert {:error, :review_expired} = ConfigurationPolicy.apply(expired, plan["manifest"])
    receipt = Repo.one!(ConfigurationPolicyReceipt)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(expired, [:deterministic]))
      |> Base.encode16(case: :lower)

    Repo.insert!(%{
      receipt
      | id: digest,
        __meta__: Ecto.put_meta(receipt, state: :built).__meta__
    })

    assert {:ok, %{"replayed" => true}} = ConfigurationPolicy.apply(expired, plan["manifest"])
  end

  test "policy replaces its whole set atomically without transient priority ties" do
    {_p, row} = publish()
    apply_manifest(manifest())
    replace = put_in(manifest(), ["rules", Access.at(0), "key"], "replacement")
    replace = put_in(replace, ["rules", Access.at(0), "params", "limit"], 40)
    before = Repo.get!(Assignment, row.id)
    %{plan: plan, response: response} = apply_manifest(replace)
    assert plan["counts"]["create"] == 1 and plan["counts"]["remove"] == 1
    assert response["changed_count"] == 1
    assert Repo.get!(Assignment, row.id).desired_generation == before.desired_generation + 1
    assert Repo.aggregate(ConfigurationRule, :count) == 1
  end

  test "removal is reviewed, restores defaults and preserves unmanaged rules, exceptions and history" do
    {_p, row} = publish()
    unmanaged = unmanaged_rule(row, 95, -1)
    %{response: first} = apply_manifest(manifest())
    saved = Repo.get!(Assignment, row.id)
    assert {:ok, _} = Monitoring.save_assignment(saved.id, saved.revision, %{"limit" => 22})
    before = Repo.get!(Assignment, row.id)

    %{plan: plan, response: removed} =
      apply_manifest(%{"version" => 1, "project" => "personal", "rules" => []})

    assert plan["counts"]["remove"] == 1
    assert plan["counts"]["exceptions"] == 1

    assert [%{"masked_params" => %{"limit" => 95}, "masked_origin" => %{"kind" => "rule"}}] =
             plan["rows"]

    assert removed["changed_count"] == 0
    assert Repo.get!(Assignment, row.id) == before
    assert Repo.get!(ConfigurationRule, unmanaged["id"])
    assert Repo.aggregate(ConfigurationRule, :count) == 1

    assert Repo.get_by!(Configuration,
             assignment_id: row.id,
             generation: hd(first["receipts"])["target_generation"]
           ).params == %{"limit" => 60}

    assert hd(removed["changes"])["before"]["params"] == %{"limit" => 60}
    assert {:ok, reset} = ConfigurationRules.preview_reset(row.id, before.revision)
    assert {:ok, _} = ConfigurationRules.reset_exception(reset["review_token"])
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 95}
  end

  test "a managed rule can be edited through the UI while preserving ownership and replay history" do
    publish()
    %{plan: policy_plan, response: result} = apply_manifest(manifest())
    rule = hd(result["changes"])["after"]
    original = Repo.get!(ConfigurationRule, rule["id"])
    proposal = Map.put(rule, "priority", 5)
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], proposal)
    saved = Repo.get!(ConfigurationRule, rule["id"])
    assert saved.managed_project == "personal"
    assert saved.managed_key == "volumes"
    assert saved.repository_key == original.repository_key
    assert saved.priority == 5
    assert Repo.get!(ConfigurationPolicyProject, "personal").revision == 2

    assert {:ok, replay} =
             ConfigurationPolicy.apply(policy_plan["review_token"], policy_plan["manifest"])

    assert replay["superseded"]
    assert replay["current_project_revision"] == 2
  end

  test "adoption is explicit, preserves rule identity and is idempotent" do
    {_p, row} = publish()
    unmanaged = unmanaged_rule(row, 60, 0)
    assert {:ok, conflict} = ConfigurationPolicy.plan(manifest())
    assert conflict["counts"]["conflicts"] == 1
    assert is_nil(conflict["review_token"])
    adopted = put_in(manifest(), ["rules", Access.at(0), "adopt_rule_id"], unmanaged["id"])
    %{plan: plan} = apply_manifest(adopted)
    assert plan["counts"]["adopt"] == 1
    assert hd(plan["changes"])["rule_id"] == unmanaged["id"]
    assert Repo.aggregate(ConfigurationRule, :count) == 1
    assert {:ok, noop} = ConfigurationPolicy.plan(adopted)
    assert noop["counts"]["noop"] == 1
    assert {:ok, _} = ConfigurationPolicy.apply(noop["review_token"], adopted)
    other = Map.put(adopted, "project", "someone-else")
    assert {:error, {:invalid, message}} = ConfigurationPolicy.plan(other)
    assert message =~ "already managed"
  end

  test "review rejects changed manifests, membership, source defaults and exceptions" do
    {p, row} = publish()
    assert {:ok, initial} = ConfigurationPolicy.plan(manifest())
    changed = put_in(manifest(), ["rules", Access.at(0), "params", "limit"], 20)
    assert {:error, :review_changed} = ConfigurationPolicy.apply(initial["review_token"], changed)

    p =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "params", "limit"], 90)

    assert {:ok, _} = Monitoring.inventory(p, at())
    assert {:error, :stale} = ConfigurationPolicy.apply(initial["review_token"], manifest())
    assert {:ok, after_defaults} = ConfigurationPolicy.plan(manifest())
    current = Repo.get!(Assignment, row.id)
    assert {:ok, _} = Monitoring.save_assignment(row.id, current.revision, %{"limit" => 30})

    assert {:error, :stale} =
             ConfigurationPolicy.apply(after_defaults["review_token"], manifest())

    assert {:ok, after_exception} = ConfigurationPolicy.plan(manifest())
    publish()

    assert {:error, :stale} =
             ConfigurationPolicy.apply(after_exception["review_token"], manifest())

    assert Repo.aggregate(ConfigurationRule, :count) == 0
  end

  test "heartbeat and measurement progress do not invalidate a policy review" do
    {_p, row} = publish()
    assert {:ok, plan} = ConfigurationPolicy.plan(manifest())

    Repo.update_all(from(a in Assignment, where: a.id == ^row.id),
      set: [last_sequence: 4, observed_generation: 1]
    )

    Repo.update_all(from(r in Mondek.Runner, where: r.id == ^row.runner_id),
      set: [last_seen_at: DateTime.utc_now()]
    )

    assert {:ok, _} = ConfigurationPolicy.apply(plan["review_token"], manifest())
  end

  test "concurrent competing plans serialize and only one changes the reviewed state" do
    {_p, row} = publish()
    left = manifest()
    right = put_in(left, ["rules", Access.at(0), "params", "limit"], 40)
    assert {:ok, first} = ConfigurationPolicy.plan(left)
    assert {:ok, second} = ConfigurationPolicy.plan(right)

    results =
      [{first, left}, {second, right}]
      |> Task.async_stream(
        fn {plan, doc} -> ConfigurationPolicy.apply(plan["review_token"], doc) end,
        ordered: false,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale} in results
    assert Repo.aggregate(ConfigurationPolicyReceipt, :count) == 1
    assert Repo.get!(Assignment, row.id).desired_generation == row.desired_generation + 1
  end

  test "concurrent identical applies return one durable receipt" do
    {_p, row} = publish()
    assert {:ok, plan} = ConfigurationPolicy.plan(manifest())

    results =
      1..3
      |> Task.async_stream(
        fn _ -> ConfigurationPolicy.apply(plan["review_token"], manifest()) end,
        ordered: false,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert Enum.count(results, &(not &1["replayed"])) == 1
    assert Repo.aggregate(ConfigurationPolicyReceipt, :count) == 1
    assert Repo.get!(Assignment, row.id).desired_generation == row.desired_generation + 1
  end

  test "a dormant rule retains its schema, can change values and configures a new observer" do
    {p, row} = publish()
    apply_manifest(manifest())
    assert {:ok, _} = Monitoring.inventory(%{p | "inventory_revision" => 2, "checks" => []}, at())
    updated = put_in(manifest(), ["rules", Access.at(0), "params", "limit"], 45)
    %{plan: plan} = apply_manifest(updated)
    assert plan["counts"]["matched"] == 0
    {_p, next} = publish()
    assert next.params == %{"limit" => 45}
    assert next.id != row.id
    assert Repo.get!(Assignment, row.id).retired_at
  end

  test "authoritative schema allows a future target but rejects ambiguity and invented schemas" do
    {p, row} = publish()

    future =
      put_in(manifest(), ["rules", Access.at(0), "target_kind"], "volume")
      |> put_in(["rules", Access.at(0), "target_key"], "future-volume")

    assert {:ok, %{"counts" => %{"matched" => 0}}} = ConfigurationPolicy.plan(future)

    differing =
      p
      |> Map.put("installation_id", Ecto.UUID.generate())
      |> Map.put("session_id", Ecto.UUID.generate())
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "unit"], "bytes")

    assert {:ok, _} = Monitoring.inventory(differing, at())
    assert {:error, {:invalid, error}} = ConfigurationPolicy.plan(manifest())
    assert error =~ "ambiguous"

    assert {:error, {:invalid, _}} =
             ConfigurationPolicy.plan(
               put_in(
                 manifest(),
                 ["rules", Access.at(0), "parameter_schema"],
                 row.parameter_schema
               )
             )
  end

  test "policy remains authoritative when an old runner republishes source defaults" do
    {p, row} = publish()
    apply_manifest(manifest())
    before = Repo.get!(Assignment, row.id)
    assert {:ok, _} = Monitoring.inventory(Map.put(p, "inventory_revision", 2), at())
    after_inventory = Repo.get!(Assignment, row.id)
    assert after_inventory.params == %{"limit" => 60}
    assert after_inventory.source_defaults == %{"limit" => 80}
    assert after_inventory.configuration_origin == before.configuration_origin
    assert after_inventory.desired_generation == before.desired_generation
  end

  test "disjoint environments resolve their own schema and dormant rules retain it" do
    {p, row} = publish()

    staging =
      p
      |> Map.put("installation_id", Ecto.UUID.generate())
      |> Map.put("session_id", Ecto.UUID.generate())
      |> put_in(["checks", Access.at(0), "environment"], "staging")
      |> put_in(
        ["checks", Access.at(0), "parameter_schema", "fields", "limit", "label"],
        "Staging limit"
      )

    assert {:ok, _} = Monitoring.inventory(staging, at())
    scoped = put_in(manifest(), ["rules", Access.at(0), "environment"], "production")
    %{plan: plan} = apply_manifest(scoped)
    assert plan["counts"]["matched"] == 1
    assert hd(plan["rows"])["id"] == row.id
    assert {:ok, noop} = ConfigurationPolicy.plan(scoped)
    assert noop["counts"]["noop"] == 1
    assert {:ok, _} = Monitoring.inventory(%{p | "inventory_revision" => 2, "checks" => []}, at())
    assert {:ok, dormant} = ConfigurationPolicy.plan(scoped)
    assert dormant["counts"]["noop"] == 1
    assert dormant["counts"]["matched"] == 0

    assert hd(dormant["changes"])["after"]["parameter_schema"] ==
             hd(plan["changes"])["after"]["parameter_schema"]

    assert {:ok, _} = ConfigurationPolicy.apply(dormant["review_token"], scoped)
  end

  test "target selectors disambiguate schemas and partial executions remain conflicts" do
    {p, row} = publish()

    other =
      p
      |> Map.put("installation_id", Ecto.UUID.generate())
      |> Map.put("session_id", Ecto.UUID.generate())
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "archive")
      |> put_in(["checks", Access.at(0), "parameter_schema", "fields", "limit", "maximum"], 90)

    assert {:ok, _} = Monitoring.inventory(other, at())

    scoped =
      put_in(manifest(), ["rules", Access.at(0), "target_kind"], "volume")
      |> put_in(["rules", Access.at(0), "target_key"], "orders")

    assert {:ok, selected} = ConfigurationPolicy.plan(scoped)
    assert selected["counts"]["matched"] == 1
    assert hd(selected["rows"])["id"] == row.id
    future = put_in(scoped, ["rules", Access.at(0), "target_key"], "future")
    assert {:error, {:invalid, reason}} = ConfigurationPolicy.plan(future)
    assert reason =~ "ambiguous"

    extra =
      hd(hd(p["checks"])["outputs"])
      |> Map.put("key", "archive")
      |> put_in(["target", "key"], "archive")

    shared =
      p
      |> Map.put("inventory_revision", 2)
      |> update_in(["checks", Access.at(0), "outputs"], &(&1 ++ [extra]))

    assert {:ok, _} = Monitoring.inventory(shared, at())
    assert {:ok, partial} = ConfigurationPolicy.plan(scoped)
    assert partial["counts"]["conflicts"] == 1
    assert is_nil(partial["review_token"])
    assert hd(partial["rows"])["error"] =~ "several targets"
  end

  test "a narrow policy reads bounded scope even within a much larger source" do
    {_p, row} = publish()

    records =
      for n <- 1..600 do
        row
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Map.merge(%{
          id: "unrelated-#{n}",
          source_key: "archive-#{n}",
          outputs: [
            %{
              "key" => "capacity",
              "label" => "Archive",
              "target" => %{"kind" => "volume", "key" => "archive", "label" => "Archive"}
            }
          ]
        })
      end

    Repo.insert_all(Assignment, records)

    scoped =
      put_in(manifest(), ["rules", Access.at(0), "target_kind"], "volume")
      |> put_in(["rules", Access.at(0), "target_key"], "orders")

    assert {:ok, plan} = ConfigurationPolicy.plan(scoped)
    assert plan["counts"]["matched"] == 1

    Repo.update_all(from(a in Assignment, where: a.id == "unrelated-1"),
      set: [source_defaults: %{"limit" => 90}]
    )

    assert {:ok, applied} = ConfigurationPolicy.apply(plan["review_token"], scoped)
    assert applied["changed_count"] == 1
  end

  test "strict manifest validation refuses typos, duplicates, wrong types and oversized lists" do
    publish()
    rule = hd(manifest()["rules"])

    invalids = [
      Map.put(manifest(), "ignored", true),
      Map.put(manifest(), "version", 1.0),
      Map.put(manifest(), "rules", nil),
      Map.put(manifest(), "rules", List.duplicate(rule, 65)),
      Map.put(manifest(), "project", "../project"),
      Map.put(manifest(), "rules", [rule, rule]),
      put_in(manifest(), ["rules", Access.at(0), "environemnt"], "prod"),
      put_in(manifest(), ["rules", Access.at(0), "priority"], "10"),
      put_in(manifest(), ["rules", Access.at(0), "enabled"], "false"),
      put_in(manifest(), ["rules", Access.at(0), "target_kind"], "volume"),
      put_in(manifest(), ["rules", Access.at(0), "params", "limit"], 101),
      put_in(manifest(), ["rules", Access.at(0), "adopt_rule_id"], nil),
      put_in(manifest(), ["rules", Access.at(0), "adopt_rule_id"], "warehouse worker")
    ]

    for invalid <- invalids,
        do: assert({:error, {:invalid, _}} = ConfigurationPolicy.plan(invalid))

    assert Repo.aggregate(ConfigurationRule, :count) == 0
    assert Repo.aggregate(ConfigurationPolicyProject, :count) == 0
  end

  test "empty policy and value inspection work without publishing controller rules" do
    {p, row} = publish()
    empty = %{"version" => 1, "project" => "source-only", "rules" => []}
    %{response: response} = apply_manifest(empty)
    assert response["changed_count"] == 0
    assert Repo.aggregate(ConfigurationRule, :count) == 0
    assert {:ok, values} = ConfigurationPolicy.values(p["source_id"])
    assert values["total"] == 1 and values["page"] == 1

    assert [%{"source_defaults" => %{"limit" => 80}, "current_origin" => %{"kind" => "source"}}] =
             values["rows"]

    assert ConfigurationPolicy.value_details(row.id)["masked_params"] == %{"limit" => 80}
    assert ConfigurationPolicy.value_details("missing") == nil
    assert {:error, {:invalid, _}} = ConfigurationPolicy.values(nil)
  end

  test "exceptions display both saved values and the policy they mask" do
    {_p, row} = publish()
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 15})
    %{plan: plan, response: response} = apply_manifest(manifest())
    assert plan["counts"]["exceptions"] == 1
    assert response["changed_count"] == 0
    detail = ConfigurationPolicy.value_details(row.id)
    assert detail["masked_by_exception"]
    assert detail["current_params"] == %{"limit" => 15}
    assert detail["masked_params"] == %{"limit" => 60}
    assert detail["masked_origin"]["managed_project"] == "personal"
    assert detail["source_defaults"] == %{"limit" => 80}
  end

  test "differently cased adoption UUIDs still identify one resource" do
    {_p, row} = publish()
    unmanaged = unmanaged_rule(row, 60, 0)
    rule = Map.put(hd(manifest()["rules"]), "adopt_rule_id", unmanaged["id"])

    duplicate =
      rule
      |> Map.put("key", "duplicate")
      |> Map.put("adopt_rule_id", String.upcase(unmanaged["id"]))

    assert {:error, {:invalid, reason}} =
             ConfigurationPolicy.plan(Map.put(manifest(), "rules", [rule, duplicate]))

    assert reason =~ "only be adopted once"
    assert Repo.get!(ConfigurationRule, unmanaged["id"]).managed_project == nil
  end

  test "operation limit covers the union of scopes and inspection is paged" do
    {_p, row} = publish()

    records =
      for n <- 1..512 do
        row
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Map.merge(%{
          id: "policy-bound-#{n}",
          source_key: "volume-#{n}",
          environment: if(n > 256, do: "staging", else: "production")
        })
      end

    Repo.insert_all(Assignment, records)
    a = hd(manifest()["rules"]) |> Map.put("environment", "production")
    b = a |> Map.put("key", "staging") |> Map.put("environment", "staging")

    assert {:error, {:invalid, reason}} =
             ConfigurationPolicy.plan(Map.put(manifest(), "rules", [a, b]))

    assert reason =~ "More than 512"
    assert Repo.aggregate(ConfigurationRule, :count) == 0
    assert {:ok, values} = ConfigurationPolicy.values("policy-tests", 2)
    assert values["total"] == 513 and values["page"] == 2
    assert length(values["rows"]) == 25
  end

  test "HTTP plan, reviewed apply, export and inspection expose managed provenance" do
    {_p, row} = publish()
    plan = request(:post, "/configuration/policy/plan", %{"manifest" => manifest()}, 200)
    assert plan["counts"]["create"] == 1

    response =
      request(
        :post,
        "/configuration/policy/apply",
        %{"manifest" => plan["manifest"], "review_token" => plan["review_token"]},
        200
      )

    assert response["changed_count"] == 1

    assert request(:get, "/configuration/policy/export?project=personal", nil, 200) ==
             plan["manifest"]

    inspected = request(:get, "/configuration/policy/values?source_id=policy-tests", nil, 200)
    assert hd(inspected["rows"])["current_origin"]["managed_project"] == "personal"
    assert hd(inspected["rows"])["id"] == row.id
    rule = hd(response["changes"])["after"]

    preview = request(:post, "/configuration/rules/preview", %{"proposal" => rule}, 200)
    assert is_binary(preview["review_token"])

    assert request(
             :post,
             "/configuration/policy/apply",
             %{"manifest" => manifest(), "review_token" => "invalid"},
             422
           )["code"] == "invalid_review"

    assert request(
             :post,
             "/configuration/policy/plan",
             %{"manifest" => Map.put(manifest(), "typo", true)},
             422
           )["error"] =~ "Unknown"
  end

  defp request(method, path, body, status) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    conn = dispatch(conn, @endpoint, method, "/api/v1" <> path, if(body, do: Jason.encode!(body)))
    json_response(conn, status)
  end

  defp repository_head do
    {:ok, state} = Mondek.ConfigurationRepository.state()
    state.head
  end

  test "stale documents need an explicit baseline and stale plans cannot undo a UI edit" do
    publish()
    %{plan: original} = apply_manifest(manifest())
    before = repository_head()
    rule = Repo.get_by!(ConfigurationRule, managed_project: "personal", managed_key: "volumes")
    {:ok, seed} = ConfigurationRules.get(rule.id)
    proposal = Map.put(seed, "params", %{"limit" => 30})
    {:ok, preview} = ConfigurationRules.preview(proposal)
    {:ok, _} = ConfigurationRules.apply(preview["review_token"], proposal)

    assert {:error, {:invalid, reason}} = ConfigurationPolicy.plan(manifest())
    assert reason =~ "require --base"
    assert {:error, {:invalid, reason}} = ConfigurationPolicy.plan(manifest(), before)
    assert reason =~ "Fetch and reconcile"
    {:ok, reconciled} = ConfigurationPolicy.export("personal")
    assert {:ok, _} = ConfigurationPolicy.plan(reconciled)
    assert {:ok, _} = ConfigurationPolicy.plan(manifest(), repository_head())

    assert {:ok, replay} =
             ConfigurationPolicy.apply(original["review_token"], original["manifest"])

    assert replay["replayed"]
    assert Repo.get!(ConfigurationRule, rule.id).params == %{"limit" => 30}
  end

  test "unapplied legacy tokens require a new review instead of bypassing repository concurrency" do
    publish()
    {:ok, plan} = ConfigurationPolicy.plan(manifest())

    {:ok, payload} =
      Phoenix.Token.verify(MondekWeb.Endpoint, "configuration-policy", plan["review_token"],
        max_age: 900
      )

    legacy =
      Phoenix.Token.sign(
        MondekWeb.Endpoint,
        "configuration-policy",
        Map.delete(payload, "repository_head")
      )

    assert {:error, {:invalid, message}} = ConfigurationPolicy.apply(legacy, manifest())
    assert message =~ "predates configuration history"
    assert Repo.aggregate(ConfigurationRule, :count) == 0
  end

  test "API requires a baseline for changing existing projects" do
    publish()
    apply_manifest(manifest())
    modified = put_in(manifest(), ["rules", Access.at(0), "params", "limit"], 22)
    result = request(:post, "/configuration/policy/plan", %{"manifest" => modified}, 422)
    assert inspect(result) =~ "require --base"

    revision = request(:get, "/configuration/revision", nil, 200)
    assert revision["head"] == repository_head()
    assert Map.keys(revision) |> Enum.sort() == ["head", "installation_id"]

    result =
      request(
        :post,
        "/configuration/policy/plan",
        %{"manifest" => modified, "base_head" => revision["head"]},
        200
      )

    assert result["review_token"]
  end

  defp apply_manifest(manifest) do
    assert {:ok, plan} = ConfigurationPolicy.plan(manifest, repository_head())
    assert is_binary(plan["review_token"])
    assert {:ok, response} = ConfigurationPolicy.apply(plan["review_token"], plan["manifest"])
    %{plan: plan, response: response}
  end

  defp unmanaged_rule(row, value, priority) do
    assert {:ok, seed} = ConfigurationRules.seed(row.id)
    proposal = Map.merge(seed, %{"params" => %{"limit" => value}, "priority" => priority})
    assert {:ok, plan} = ConfigurationRules.preview(proposal)
    assert {:ok, result} = ConfigurationRules.apply(plan["review_token"], proposal)
    result["rule"]
  end

  defp manifest do
    %{
      "version" => 1,
      "project" => "personal",
      "rules" => [
        %{
          "key" => "volumes",
          "name" => "Volume limits",
          "source_id" => "policy-tests",
          "parameter_contract" => "volume.capacity.v1",
          "params" => %{"limit" => 60}
        }
      ]
    }
  end

  defp publish do
    p =
      control(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "prepared" => %{}
      })
      |> Map.merge(%{
        "runner_label" => "Policy observer",
        "source_id" => "policy-tests",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => [
          %{
            "key" => "volume",
            "label" => "Volume",
            "definition_revision" => String.duplicate("b", 64),
            "environment" => "production",
            "params_owner" => "ui",
            "parameter_contract" => "volume.capacity.v1",
            "params" => %{"limit" => 80},
            "parameter_schema" => %{
              "fields" => %{
                "limit" => %{"type" => "integer", "unit" => "%", "minimum" => 0, "maximum" => 100}
              }
            },
            "interval_seconds" => 3,
            "timeout_seconds" => 2,
            "freshness_seconds" => 12,
            "outputs" => [
              %{
                "key" => "capacity",
                "label" => "Capacity",
                "target" => %{"kind" => "volume", "key" => "orders", "label" => "Orders"}
              }
            ]
          }
        ]
      })

    assert {:ok, _} = Monitoring.inventory(p, at())
    {p, Repo.get_by!(Assignment, runner_id: p["installation_id"], source_id: p["source_id"])}
  end
end
