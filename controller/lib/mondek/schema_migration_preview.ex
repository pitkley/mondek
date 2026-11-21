# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.SchemaMigrationPreview do
  @moduledoc "Read-only diagnostics for an exact proposed publisher inventory."
  import Ecto.Query

  alias Mondek.{
    Assignment,
    ConfigurationRule,
    ConfigurationRules,
    Inventory,
    Investigation,
    Parameters,
    Repo,
    SourceInventory
  }

  @page_size 20
  @publication_limit 512
  @peer_limit 4096
  @rule_limit 512
  @scope_limit 4096
  @assignment_fields ~w(id runner_id source_id source_key revision desired_generation
    parameter_contract parameter_schema params_owner source_defaults instance_exception
    configuration_exception_key configuration_origin definition_revision outputs environment)a
  @peer_fields ~w(id runner_id source_id source_key revision desired_generation
    parameter_contract parameter_schema_fingerprint params_owner definition_revision outputs environment)a

  def preview(inventory, requested_page \\ 1) do
    with :ok <- Inventory.validate(inventory) do
      case Investigation.read(fn -> project(inventory, requested_page) end) do
        {:ok, {:error, _} = error} -> error
        result -> result
      end
    end
  end

  defp project(inventory, page) do
    source = inventory["source_id"]
    runner = inventory["installation_id"]

    case Repo.get_by(SourceInventory, source_id: source, runner_id: runner) do
      nil -> nil
      accepted -> project_accepted(inventory, accepted, page)
    end
  end

  defp project_accepted(inventory, accepted, page) do
    own =
      Repo.all(
        from a in Assignment,
          where:
            a.source_id == ^accepted.source_id and a.runner_id == ^accepted.runner_id and
              is_nil(a.retired_at),
          order_by: a.id,
          limit: @publication_limit + 1,
          select: struct(a, ^@assignment_fields)
      )

    if length(own) > @publication_limit do
      invalid("This publication has more active assignments than a schema preview can review.")
    else
      changes = changed_checks(own, inventory)
      contracts = potential_contracts(changes)

      rules =
        Repo.all(
          from r in ConfigurationRule,
            where: r.source_id == ^accepted.source_id and r.parameter_contract in ^contracts,
            order_by: r.id,
            limit: @rule_limit + 1
        )

      case scope_impact(changes, own, peers(accepted, rules), rules) do
        {:error, _} = error ->
          error

        {check_rows, rule_rows, reviewed_peers} ->
          rows = check_rows ++ rule_rows

          candidate = %{
            "inventory_revision" => inventory["inventory_revision"],
            "source_revision" => inventory["source_revision"],
            "digest" => digest(Parameters.normalized_json(inventory)),
            "publication_status" => publication_status(accepted, inventory)
          }

          current = %{
            "publication_id" => accepted.id,
            "inventory_revision" => accepted.revision,
            "source_revision" => accepted.source_revision,
            "lifecycle_revision" => accepted.lifecycle_revision
          }

          page = if is_integer(page) and page > 0, do: page, else: 1
          total = length(rows)

          %{
            "source_id" => accepted.source_id,
            "installation_id" => accepted.runner_id,
            "accepted" => current,
            "candidate" => candidate,
            "review_digest" =>
              digest({current, candidate, Enum.map(own, &revision/1), rows, reviewed_peers}),
            "check_count" => length(check_rows),
            "rule_match_count" => length(rule_rows),
            "page" => page,
            "page_size" => @page_size,
            "total" => total,
            "rows" => Enum.slice(rows, (page - 1) * @page_size, @page_size)
          }
      end
    end
  end

  defp peers(_accepted, []), do: []

  defp peers(accepted, rules) do
    contracts = Enum.map(rules, & &1.parameter_contract) |> Enum.uniq()

    Repo.all(
      from a in Assignment,
        where:
          a.source_id == ^accepted.source_id and a.runner_id != ^accepted.runner_id and
            a.parameter_contract in ^contracts and is_nil(a.retired_at),
        order_by: a.id,
        limit: @peer_limit + 1,
        select: struct(a, ^@peer_fields)
    )
  end

  defp changed_checks(own, inventory) do
    current = Map.new(own, &{&1.source_key, &1})
    candidate = Map.new(inventory["checks"], &{&1["key"], candidate(&1, inventory)})

    (Map.keys(current) ++ Map.keys(candidate))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, current[&1], candidate[&1]})
    |> Enum.filter(fn {_, before, after_update} ->
      (delegated?(before) or delegated?(after_update)) and
        signature(before) != signature(after_update)
    end)
  end

  defp candidate(check, inventory) do
    %Assignment{
      revision: nil,
      desired_generation: nil,
      source_id: inventory["source_id"],
      runner_id: inventory["installation_id"],
      source_key: check["key"],
      definition_revision: check["definition_revision"],
      params_owner: check["params_owner"],
      parameter_contract: check["parameter_contract"],
      parameter_schema: Parameters.normalized_schema(check["parameter_schema"]),
      source_defaults: Parameters.normalized_json(check["params"]),
      environment: check["environment"],
      outputs: check["outputs"]
    }
  end

  defp delegated?(%Assignment{params_owner: "ui"}), do: true
  defp delegated?(_), do: false

  defp signature(nil), do: nil

  defp signature(row) do
    %{
      owner: row.params_owner,
      contract: row.parameter_contract,
      schema: Parameters.normalized_schema(row.parameter_schema),
      defaults: Parameters.normalized_json(row.source_defaults),
      environment: row.environment,
      targets:
        row.outputs
        |> Enum.map(&Map.take(&1["target"], ~w(kind key)))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp potential_contracts(changes) do
    changes
    |> Enum.flat_map(fn {_, before, after_update} ->
      Enum.flat_map([before, after_update], fn
        %{parameter_contract: contract} when is_binary(contract) -> [contract]
        _ -> []
      end)
    end)
    |> Enum.uniq()
  end

  defp scope_impact(changes, own, peers, rules) do
    scoped = Enum.group_by(rules, & &1.parameter_contract)
    peer_groups = Enum.group_by(own ++ peers, & &1.parameter_contract)

    pair_count =
      Enum.sum(
        for {_, before, after_update} <- changes,
            do: length(rules_for(scoped, before, after_update))
      )

    peer_count =
      Enum.sum(for rule <- rules, do: length(Map.get(peer_groups, rule.parameter_contract, [])))

    if length(rules) > @rule_limit or length(peers) > @peer_limit or
         pair_count + peer_count > @scope_limit do
      invalid("This source has more matching rule scopes than a schema preview can review.")
    else
      candidates =
        for {key, before, after_update} <- changes,
            rule <- rules_for(scoped, before, after_update),
            before_scope = scope(rule, before),
            after_scope = scope(rule, after_update),
            before_scope != :none or after_scope != :none,
            do: {key, before, after_update, rule, before_scope, after_scope}

      peer_matches =
        Map.new(candidates |> Enum.map(&elem(&1, 3)) |> Enum.uniq_by(& &1.id), fn rule ->
          rows =
            Enum.filter(
              Map.get(peer_groups, rule.parameter_contract, []),
              &(scope(rule, &1) != :none)
            )

          {rule.id, rows}
        end)

      rule_rows = Enum.map(candidates, &rule_row(&1, peer_matches))
      check_rows = Enum.map(changes, &check_row(&1, scoped))

      revisions =
        Map.new(peer_matches, fn {id, rows} ->
          {id,
           Enum.map(
             rows,
             &Map.take(
               &1,
               [
                 :id,
                 :runner_id,
                 :revision,
                 :desired_generation,
                 :definition_revision,
                 :parameter_schema_fingerprint
               ]
             )
           )}
        end)

      {check_rows, rule_rows, revisions}
    end
  end

  defp rules_for(scoped, before, after_update) do
    [before && before.parameter_contract, after_update && after_update.parameter_contract]
    |> Enum.uniq()
    |> Enum.flat_map(&Map.get(scoped, &1, []))
    |> Enum.sort_by(& &1.id)
  end

  defp scope(_rule, nil), do: :none
  defp scope(rule, row), do: ConfigurationRules.match_rule(rule, row)

  defp check_row({key, before, after_update}, scoped) do
    old_schema = schema(before)
    new_schema = schema(after_update)
    fields = field_changes(old_schema["fields"], new_schema["fields"])
    defaults = changed_keys(defaults(before), defaults(after_update))
    exception = before && before.instance_exception

    %{
      "kind" => "check",
      "check_key" => key,
      "change" => change_kind(before, after_update),
      "accepted" => revision(before),
      "candidate" => revision(after_update),
      "fields" => fields,
      "comparisons_changed" => old_schema["comparisons"] != new_schema["comparisons"],
      "defaults_changed_fields" => defaults,
      "saved_default_findings" =>
        if(before && after_update, do: Parameters.value_findings(new_schema, defaults(before))),
      "instance_exception" => exception_findings(exception, after_update),
      "blockers" => blockers(before, after_update, fields),
      "rule_resolution" => resolution(before, after_update, scoped)
    }
  end

  defp rule_row({key, before, after_update, rule, before_scope, after_scope}, peers) do
    shared = Enum.reject(Map.fetch!(peers, rule.id), &(before && &1.id == before.id))
    runner = (before || after_update).runner_id

    publishers =
      shared
      |> Enum.map(& &1.runner_id)
      |> Enum.reject(&(&1 == runner))
      |> Enum.uniq()
      |> Enum.sort()

    captured = Parameters.schema_fingerprint(rule.parameter_schema)

    candidate_schema =
      after_update && Parameters.schema_fingerprint(after_update.parameter_schema)

    remains_in_scope? = after_scope != :none

    %{
      "kind" => "rule",
      "check_key" => key,
      "assignment_id" => before && before.id,
      "rule_id" => rule.id,
      "rule_revision" => rule.revision,
      "rule_name" => rule.name,
      "enabled" => rule.enabled,
      "priority" => rule.priority,
      "scope_before" => to_string(before_scope),
      "scope_after" => to_string(after_scope),
      "captured_schema_fingerprint" => captured,
      "candidate_schema_changed" => remains_in_scope? and captured != candidate_schema,
      "rule_value_findings" =>
        if(remains_in_scope?, do: Parameters.value_findings(schema(after_update), rule.params)),
      "other_matching_assignments" => length(shared),
      "other_publisher_count" => length(publishers),
      "other_publisher_sample" => Enum.take(publishers, 8)
    }
  end

  defp revision(nil), do: nil

  defp revision(row) do
    %{
      "assignment_id" => row.id,
      "installation_id" => row.runner_id,
      "revision" => row.revision,
      "desired_generation" => row.desired_generation,
      "definition_revision" => row.definition_revision,
      "schema_fingerprint" => Parameters.schema_fingerprint(row.parameter_schema),
      "params_owner" => row.params_owner,
      "parameter_contract" => row.parameter_contract,
      "environment" => row.environment
    }
  end

  defp change_kind(nil, _), do: "added"
  defp change_kind(_, nil), do: "withdrawn"
  defp change_kind(_, _), do: "updated"

  defp schema(nil), do: %{"fields" => %{}, "comparisons" => []}
  defp schema(row), do: Parameters.normalized_schema(row.parameter_schema)
  defp defaults(nil), do: %{}
  defp defaults(row), do: row.source_defaults

  defp changed_keys(before, after_update) do
    (Map.keys(before) ++ Map.keys(after_update))
    |> Enum.uniq()
    |> Enum.filter(fn field ->
      case {Map.fetch(before, field), Map.fetch(after_update, field)} do
        {{:ok, old}, {:ok, new}} -> not Parameters.same_json?(old, new)
        _ -> true
      end
    end)
    |> Enum.sort()
  end

  defp field_changes(before, after_update) do
    Enum.map(changed_keys(before, after_update), fn field ->
      old = before[field]
      new = after_update[field]

      %{
        "field" => field,
        "change" => change_kind(old, new),
        "attributes" => if(old && new, do: changed_keys(old, new), else: []),
        "type_before" => old && old["type"],
        "type_after" => new && new["type"],
        "unit_before" => old && old["unit"],
        "unit_after" => new && new["unit"]
      }
    end)
  end

  defp exception_findings(nil, _), do: nil

  defp exception_findings(exception, candidate) do
    %{
      "saved_fields" => Enum.sort(Map.keys(exception)),
      "findings" =>
        if(candidate,
          do:
            Parameters.value_findings(
              schema(candidate),
              Map.merge(defaults(candidate), exception)
            )
        )
    }
  end

  defp blockers(%{params_owner: "ui"}, %{} = candidate, fields) do
    owner = if candidate.params_owner != "ui", do: ["delegated_ownership_reclaim"], else: []

    incompatible =
      for field <- fields,
          field["change"] == "withdrawn" or
            Enum.any?(field["attributes"], &(&1 in ["type", "unit"])),
          do: "removed_or_reinterpreted_field:" <> field["field"]

    owner ++ incompatible
  end

  defp blockers(_, _, _), do: []

  defp resolution(_, nil, _), do: nil

  defp resolution(before, updated, scoped) do
    exception = before && before.instance_exception
    complete = if exception, do: Map.merge(defaults(updated), exception)
    row = %{updated | instance_exception: complete}

    case ConfigurationRules.resolve(row, rules_for(scoped, nil, updated)) do
      {:ok, _, origin} -> %{"origin" => origin}
      {:error, reason, ids} -> %{"diagnostic" => reason, "rule_ids" => ids}
    end
  end

  defp publication_status(%{retired_at: retired_at}, _) when not is_nil(retired_at),
    do: "publisher_retired"

  defp publication_status(%{resume_after_revision: revision} = accepted, inventory)
       when not is_nil(revision) do
    if inventory["inventory_revision"] > revision and
         inventory["restoration_revision"] == accepted.lifecycle_revision,
       do: revision_status(accepted, inventory),
       else: "publication_refresh_required"
  end

  defp publication_status(accepted, inventory), do: revision_status(accepted, inventory)

  defp revision_status(accepted, inventory) do
    case inventory["inventory_revision"] do
      revision when revision < accepted.revision ->
        "stale_inventory"

      revision when revision == accepted.revision ->
        if Parameters.same_json?(
             Inventory.semantic_payload(accepted.payload),
             Inventory.semantic_payload(inventory)
           ),
           do: "accepted_replay",
           else: "inventory_conflict"

      _ ->
        "candidate"
    end
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp invalid(message), do: {:error, {:invalid, message}}
end
