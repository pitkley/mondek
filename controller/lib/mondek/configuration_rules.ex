# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationRules do
  @moduledoc "Durable, reviewed whole-set parameter policies independent of observers."
  import Ecto.Query
  import Kernel, except: [apply: 2]

  alias Mondek.{
    Assignment,
    ConfigurationRule,
    ConfigurationRuleDiagnostic,
    Monitoring,
    Parameters,
    Repo,
    Runner,
    SourceInventory
  }

  @limit 512
  @page_size 25
  @max_age 900
  @fields ~w(id revision name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params)

  def lock_source!(nil), do: :ok

  def lock_source!(source) do
    <<key::signed-big-64, _::binary>> =
      :crypto.hash(:sha256, "mondek/configuration/" <> source)

    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  def list(page \\ 1) do
    rules = Repo.all(from(r in ConfigurationRule, order_by: [asc: r.name, asc: r.id]))

    page_result(rules, page, "rules")
    |> Map.update!("rules", &Enum.map(&1, fn rule -> public_rule(rule, true) end))
    |> Map.put("diagnostics", diagnostics())
  end

  @doc "Discover source-declared compatible parameter groups without changing their scope."
  def groups(search \\ "", requested_page \\ 1) do
    search = if is_binary(search), do: search |> String.trim() |> String.slice(0, 200), else: ""
    page = discovery_page(requested_page)

    # Admission stores the same normalized schema fingerprint used by previews.
    # Search is aggregated after grouping so one matching label never hides the
    # other checks a shared rule would affect. Only one page leaves PostgreSQL.
    sql = """
    WITH eligible AS (
      SELECT * FROM assignments
      WHERE retired_at IS NULL AND params_owner = 'ui'
        AND source_id IS NOT NULL AND parameter_contract IS NOT NULL
        AND parameter_schema->'fields' <> '{}'::jsonb
    ), grouped AS (
      SELECT source_id, parameter_contract, parameter_schema_fingerprint AS schema_fingerprint,
        (array_agg(parameter_schema ORDER BY label, id))[1] AS parameter_schema,
        (array_agg(id ORDER BY label, id))[1] AS check_id,
        min(label) AS label, count(DISTINCT label) AS label_count,
        count(*) AS check_count, sum(cardinality(outputs)) AS result_count,
        coalesce((array_agg(DISTINCT environment ORDER BY environment)
          FILTER (WHERE environment IS NOT NULL))[1:5], ARRAY[]::text[]) AS environments,
        count(DISTINCT environment) AS environment_count
      FROM eligible
      GROUP BY source_id, parameter_contract, parameter_schema_fingerprint
      HAVING bool_or(strpos(lower(label), lower($1)) > 0
        OR strpos(lower(source_id), lower($1)) > 0
        OR strpos(lower(parameter_contract), lower($1)) > 0
        OR EXISTS (SELECT 1 FROM jsonb_each(parameter_schema->'fields') f
          WHERE strpos(lower(coalesce(f.value->>'label', f.key)), lower($1)) > 0))
    ), totals AS (
      SELECT count(*) AS total,
        greatest(1, (count(*) + $3 - 1) / $3) AS pages FROM grouped
    )
    SELECT totals.total, least($2, totals.pages) AS page, totals.pages,
      coalesce((SELECT jsonb_agg(to_jsonb(selected)) FROM (
        SELECT * FROM grouped
        ORDER BY label, source_id, parameter_contract, parameter_schema::text
        LIMIT $3 OFFSET ((least($2, totals.pages) - 1) * $3)
      ) selected), '[]'::jsonb) AS groups
    FROM totals
    """

    [[total, page, pages, groups]] = Repo.query!(sql, [search, page, @page_size]).rows

    groups =
      Enum.map(groups, fn group ->
        fields =
          group["parameter_schema"]["fields"]
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {key, field} -> %{"key" => key, "label" => field["label"] || key} end)

        group
        |> Map.put("fields", fields)
        |> Map.put("schema_fingerprint", Parameters.schema_fingerprint(group["parameter_schema"]))
      end)

    %{
      "groups" => groups,
      "total" => total,
      "page" => page,
      "pages" => pages,
      "page_size" => @page_size
    }
  end

  @doc "Bounded named scope suggestions; IDs remain authoritative and future scopes are allowed."
  def scope_choices(source, contract) when is_binary(source) and is_binary(contract) do
    environments =
      Repo.query!(
        """
        SELECT environment, min(coalesce(environment_label, environment)) AS label
        FROM assignments WHERE source_id = $1 AND parameter_contract = $2
          AND retired_at IS NULL AND environment IS NOT NULL
        GROUP BY environment ORDER BY label, environment LIMIT 101
        """,
        [source, contract]
      ).rows

    targets =
      Repo.query!(
        """
        SELECT output->'target'->>'kind' AS kind, output->'target'->>'key' AS key,
          min(output->'target'->>'label') AS label
        FROM assignments CROSS JOIN LATERAL unnest(outputs) output
        WHERE source_id = $1 AND parameter_contract = $2 AND retired_at IS NULL
        GROUP BY output->'target'->>'kind', output->'target'->>'key'
        ORDER BY label, kind, key LIMIT 101
        """,
        [source, contract]
      ).rows

    %{
      "environments" =>
        environments
        |> Enum.take(100)
        |> Enum.map(fn [id, label] -> %{"id" => id, "label" => label} end),
      "targets" =>
        targets
        |> Enum.take(100)
        |> Enum.map(fn [kind, key, label] ->
          %{"kind" => kind, "key" => key, "label" => label}
        end),
      "environments_truncated" => length(environments) > 100,
      "targets_truncated" => length(targets) > 100
    }
  end

  defp discovery_page(value) when is_integer(value), do: min(max(value, 1), 2_147_483_647)

  defp discovery_page(value) when is_binary(value) do
    case Integer.parse(String.slice(value, 0, 20)) do
      {page, ""} -> discovery_page(page)
      _ -> 1
    end
  end

  defp discovery_page(_), do: 1

  def get(id) do
    case find_rule(id) do
      nil ->
        {:error, :not_found}

      rule ->
        rows = matching_rows(rule)
        all = rules_for(rule.source_id)
        {:ok, public_rule(rule, true) |> Map.merge(summary(rows, all, 1))}
    end
  end

  def seed(id) do
    case if(Mondek.Protocol.assignment_id?(id), do: Repo.get(Assignment, id)) do
      %Assignment{params_owner: "ui", parameter_contract: contract, retired_at: nil} = row
      when is_binary(contract) ->
        targets = Enum.uniq_by(row.outputs, &Map.take(&1["target"], ~w(key kind)))
        target = if length(targets) == 1, do: hd(targets)["target"], else: %{}

        {:ok,
         %{
           "revision" => 0,
           "name" => if(byte_size(row.label) <= 193, do: row.label <> " policy", else: row.label),
           "source_id" => row.source_id,
           "parameter_contract" => contract,
           "environment" => row.environment,
           "target_kind" => target["kind"],
           "target_key" => target["key"],
           "priority" => 0,
           "enabled" => true,
           "parameter_schema" => row.parameter_schema,
           "params" => row.params
         }}

      nil ->
        {:error, :not_found}

      _ ->
        {:error,
         {:invalid,
          "Create a rule from an active check with explicitly delegated parameters and a shared parameter contract."}}
    end
  end

  def schema_candidates(rule_id, search \\ "") do
    case find_rule(rule_id) do
      nil ->
        []

      rule ->
        query =
          from(a in Assignment,
            left_join: r in Runner,
            on: r.id == a.runner_id,
            where:
              a.source_id == ^rule.source_id and a.parameter_contract == ^rule.parameter_contract and
                a.params_owner == "ui" and is_nil(a.retired_at),
            order_by: [a.label, a.id],
            limit: 50,
            select: %{
              id: a.id,
              label: a.label,
              environment: a.environment,
              runner_id: a.runner_id,
              runner_label: r.label
            }
          )

        query =
          if is_binary(search) and search != "",
            do:
              from([a, r] in query,
                where: ilike(a.label, ^("%" <> String.slice(search, 0, 200) <> "%"))
              ),
            else: query

        Repo.all(query)
        |> Enum.map(fn row ->
          Map.new(row, fn {key, value} -> {Atom.to_string(key), value} end)
        end)
    end
  end

  def preview(proposal, page \\ 1) do
    Repo.transaction(fn ->
      proposal = validate_proposal!(proposal)
      lock_catalog!(proposal)
      lock_source!(proposal["source_id"])
      validate_revision!(proposal)
      validate_source_schema!(proposal)
      {candidate, all} = proposed_rules(proposal)
      rows = affected_rows(candidate, false, true)
      result = summary(rows, all, page)

      shadowed =
        Enum.count(rows, fn row ->
          case resolve(row, all) do
            {:ok, _, %{"kind" => "rule", "rule_id" => id}} ->
              not is_map(row.instance_exception) and id != candidate.id

            _ ->
              false
          end
        end)

      result = put_in(result, ["counts", "shadowed"], shadowed)
      ensure_bounds!(rows, all)

      token =
        if result["counts"]["conflicts"] == 0,
          do:
            sign("rule", %{
              "proposal" => fingerprint(proposal),
              "state" => state_fingerprint(proposal["source_id"], rows)
            })

      result
      |> Map.put("proposal", proposal)
      |> Map.put("scope_counts", scope_counts(candidate))
      |> Map.put("review_token", token)
      |> Map.put(
        "fingerprint",
        fingerprint(%{
          "proposal" => proposal,
          "state" => state_fingerprint(proposal["source_id"], rows)
        })
      )
    end)
  end

  def apply(token, proposal) do
    with {:ok, reviewed} <- verify("rule", token) do
      result =
        Mondek.ConfigurationRepository.transaction("ui", fn ->
          proposal = validate_proposal!(proposal)
          if fingerprint(proposal) != reviewed["proposal"], do: Repo.rollback(:review_changed)
          lock_catalog!(proposal)
          lock_source!(proposal["source_id"])
          validate_revision!(proposal)
          validate_source_schema!(proposal)
          {candidate, all} = proposed_rules(proposal)
          rows = affected_rows(candidate, false, true)
          lock_runners!(rows)
          rows = affected_rows(candidate, true, true)

          if state_fingerprint(proposal["source_id"], rows) != reviewed["state"],
            do: Repo.rollback(:stale)

          verify_again!("rule", token)

          if summary(rows, all, 1)["counts"]["conflicts"] > 0,
            do:
              Repo.rollback(
                {:conflict, "Resolve every matching configuration conflict before saving."}
              )

          at = Monitoring.now()

          rule =
            if proposal["id"],
              do:
                Monitoring.change(
                  Repo.get!(ConfigurationRule, proposal["id"]),
                  Map.from_struct(candidate)
                  |> Map.drop([:__meta__, :id])
                  |> Map.put(:saved_at, at)
                ),
              else: Repo.insert!(%{candidate | id: Ecto.UUID.generate(), saved_at: at})

          all = Enum.map(all, fn item -> if item.id == candidate.id, do: rule, else: item end)

          receipts =
            Enum.map(rows, fn row ->
              {:ok, params, origin} = resolve(row, all)
              saved = Monitoring.set_effective_configuration!(row, params, origin, at)

              %{
                "id" => row.id,
                "revision" => saved.revision,
                "target_generation" => saved.desired_generation,
                "changed" => saved.revision != row.revision
              }
            end)

          for runner <- rows |> Enum.map(& &1.runner_id) |> Enum.uniq(),
              do: Monitoring.ensure_control_bound!(runner)

          %{
            "rule" => public_rule(rule),
            "changed_count" => Enum.count(receipts, & &1["changed"]),
            "receipts" => receipts
          }
        end)

      if match?({:ok, _}, result), do: Monitoring.notify()
      if match?({:ok, _}, result), do: Monitoring.notify_control()
      result
    end
  end

  @doc "Review one complete instance override, including its current policy context."
  def preview_instance(id, revision, params) do
    Repo.transaction(fn ->
      row = lock_instance!(id, revision)
      validate_instance_params!(row, params)

      %{
        "id" => id,
        "revision" => revision,
        "current_params" => row.params,
        "proposed_params" => params,
        "review_token" =>
          sign("instance", %{
            "id" => id,
            "revision" => revision,
            "params" => params,
            "state" => state_fingerprint(row.source_id, [row])
          })
      }
    end)
  end

  def apply_instance(token) do
    with {:ok, reviewed} <- verify("instance", token) do
      Monitoring.save_assignment(reviewed["id"], reviewed["revision"], reviewed["params"], token)
    end
  end

  @doc false
  def validate_instance_review!(row, params, token) do
    case verify("instance", token) do
      {:ok, reviewed} ->
        if reviewed["id"] != row.id or reviewed["revision"] != row.revision or
             not Parameters.same_json?(reviewed["params"], params) or
             reviewed["state"] != state_fingerprint(row.source_id, [row]),
           do: Repo.rollback(:stale)

      _ ->
        Repo.rollback(:review_required)
    end
  end

  defp validate_instance_params!(row, params) do
    validation = Parameters.validate(row.parameter_schema, params)

    case validation do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid, reason})
    end
  end

  def preview_reset(id, revision) do
    Repo.transaction(fn ->
      row = lock_instance!(id, revision)
      all = rules_for(row.source_id)

      case resolve(%{row | instance_exception: nil}, all) do
        {:ok, params, origin} ->
          ensure_bounds!([%{row | instance_exception: nil}], all)

          %{
            "id" => row.id,
            "revision" => row.revision,
            "current_params" => row.params,
            "proposed_params" => params,
            "origin" => origin,
            "review_token" =>
              sign("reset", %{
                "id" => id,
                "revision" => revision,
                "state" => state_fingerprint(row.source_id, [row])
              })
          }

        {:error, reason, _} ->
          Repo.rollback({:conflict, reason})
      end
    end)
  end

  def reset_exception(token) do
    with {:ok, reviewed} <- verify("reset", token) do
      result =
        Mondek.ConfigurationRepository.transaction("ui", fn ->
          row = lock_instance!(reviewed["id"], reviewed["revision"])

          if state_fingerprint(row.source_id, [row]) != reviewed["state"],
            do: Repo.rollback(:stale)

          verify_again!("reset", token)

          case resolve(%{row | instance_exception: nil}, rules_for(row.source_id)) do
            {:ok, params, origin} ->
              saved =
                Monitoring.set_effective_configuration!(row, params, origin, Monitoring.now(), %{
                  instance_exception: nil
                })

              Monitoring.ensure_control_bound!(saved.runner_id)
              Monitoring.public(saved)

            {:error, reason, _} ->
              Repo.rollback({:conflict, reason})
          end
        end)

      if match?({:ok, _}, result), do: Monitoring.notify()

      if match?({:ok, _}, result),
        do: Monitoring.notify_control(elem(result, 1)["runner_id"])

      result
    end
  end

  def rules_for(source),
    do: Repo.all(from(r in ConfigurationRule, where: r.source_id == ^source, order_by: r.id))

  def resolve(%Assignment{instance_exception: params} = row, _rules) when is_map(params),
    do: validated_values(row, params, %{"kind" => "exception"})

  def resolve(row, rules) do
    candidates = Enum.filter(rules, &(&1.enabled and match_rule(&1, row) != :none))

    case Enum.sort_by(candidates, & &1.priority, :desc) do
      [] ->
        validated_values(row, row.source_defaults, %{"kind" => "source"})

      [winner | rest] ->
        tied = Enum.take_while(rest, &(&1.priority == winner.priority))

        cond do
          tied != [] ->
            {:error,
             "Multiple matching rules have priority #{winner.priority}. Give the intended winner a distinct priority.",
             Enum.map([winner | tied], & &1.id)}

          match_rule(winner, row) == :partial ->
            {:error,
             "This execution shares parameters across several targets. Split it into separate checks to configure this target independently.",
             [winner.id]}

          row.params_owner != "ui" ->
            {:error, "The matching check has not delegated its parameters to the operator.",
             [winner.id]}

          not Parameters.same_json?(
            Parameters.normalized_schema(winner.parameter_schema),
            Parameters.normalized_schema(row.parameter_schema)
          ) ->
            {:error,
             "Rule #{winner.name} captured a different parameter schema. Review the changed fields, units, labels, bounds and comparisons, then explicitly refresh the rule schema.",
             [winner.id]}

          true ->
            {:ok, winner.params,
             %{
               "kind" => "rule",
               "rule_id" => winner.id,
               "rule_revision" => winner.revision,
               "rule_name" => winner.name
             }}
            |> managed_origin(winner)
        end
    end
  end

  defp managed_origin({:ok, params, origin}, %{managed_project: nil}),
    do: {:ok, params, origin}

  defp managed_origin({:ok, params, origin}, rule),
    do:
      {:ok, params,
       Map.merge(origin, %{
         "managed_project" => rule.managed_project,
         "managed_key" => rule.managed_key
       })}

  defp validated_values(row, params, origin) do
    case Parameters.validate(row.parameter_schema, params) do
      :ok ->
        {:ok, params, origin}

      {:error, reason} ->
        {:error,
         "The saved #{origin["kind"]} values are incompatible with this check: " <> reason, []}
    end
  end

  def resolve_inventory!(row, inventory, check, rules) do
    case resolve(row, rules) do
      {:ok, params, origin} ->
        {params, origin}

      {:error, reason, ids} ->
        diagnostic = %{
          source_id: inventory["source_id"],
          runner_id: inventory["installation_id"],
          source_key: check["key"],
          source_revision: inventory["source_revision"],
          inventory_revision: inventory["inventory_revision"],
          rule_ids: ids,
          message: reason
        }

        Repo.rollback({:rule_conflict, diagnostic})
    end
  end

  def record_rejection(diagnostic, at) do
    Repo.transaction(fn ->
      lock_source!(diagnostic.source_id)

      accepted =
        Repo.get_by(SourceInventory,
          source_id: diagnostic.source_id,
          runner_id: diagnostic.runner_id
        )

      previous =
        Repo.get_by(ConfigurationRuleDiagnostic,
          source_id: diagnostic.source_id,
          runner_id: diagnostic.runner_id,
          source_key: diagnostic.source_key
        )

      if (is_nil(accepted) or accepted.revision < diagnostic.inventory_revision) and
           (is_nil(previous) or previous.inventory_revision <= diagnostic.inventory_revision) do
        Repo.insert!(struct(ConfigurationRuleDiagnostic, Map.put(diagnostic, :recorded_at, at)),
          on_conflict:
            {:replace, [:source_revision, :inventory_revision, :rule_ids, :message, :recorded_at]},
          conflict_target: [:source_id, :runner_id, :source_key]
        )

        # Keep the newest bounded issues per source, including attempts with no accepted assignment.
        keep =
          Repo.all(
            from(d in ConfigurationRuleDiagnostic,
              where: d.source_id == ^diagnostic.source_id,
              order_by: [desc: d.recorded_at, desc: d.id],
              limit: @limit,
              select: d.id
            )
          )

        Repo.delete_all(
          from(d in ConfigurationRuleDiagnostic,
            where: d.source_id == ^diagnostic.source_id and d.id not in ^keep
          )
        )
      end
    end)

    :ok
  end

  def ensure_inventory_capacity!(_inventory, []), do: :ok

  def ensure_inventory_capacity!(inventory, rules) do
    rules = Enum.filter(rules, & &1.enabled)
    if rules != [], do: check_inventory_capacity!(inventory, rules)
    :ok
  end

  defp check_inventory_capacity!(inventory, rules) do
    source = inventory["source_id"]
    rows = Repo.all(from(a in Assignment, where: a.source_id == ^source and is_nil(a.retired_at)))

    for rule <- rules do
      matching = Enum.filter(rows, &(match_rule(rule, &1) != :none))

      if length(matching) > @limit do
        subject =
          Enum.find(matching, &(&1.runner_id == inventory["installation_id"])) || hd(matching)

        diagnostic = %{
          source_id: source,
          runner_id: inventory["installation_id"],
          source_key: subject.source_key,
          source_revision: inventory["source_revision"],
          inventory_revision: inventory["inventory_revision"],
          rule_ids: [rule.id],
          message:
            "Rule #{rule.name} exceeds the supported 512 current checks. Narrow its scope or split it into distinct rules before adding more matching checks."
        }

        Repo.rollback({:rule_conflict, diagnostic})
      end
    end

    :ok
  end

  def clear_diagnostics!(source, runner, revision),
    do:
      Repo.delete_all(
        from(d in ConfigurationRuleDiagnostic,
          where:
            d.source_id == ^source and d.runner_id == ^runner and
              d.inventory_revision <= ^revision
        )
      )

  defp diagnostics(source \\ nil) do
    query =
      from(d in ConfigurationRuleDiagnostic,
        order_by: [desc: d.recorded_at, desc: d.id],
        limit: @limit
      )

    query = if source, do: from(d in query, where: d.source_id == ^source), else: query
    Repo.all(query) |> Enum.map(&Monitoring.public/1)
  end

  @doc false
  def match_rule(rule, row) do
    cond do
      rule.source_id != row.source_id or rule.parameter_contract != row.parameter_contract ->
        :none

      rule.environment && rule.environment != row.environment ->
        :none

      is_nil(rule.target_key) ->
        :full

      true ->
        matches =
          Enum.count(row.outputs, fn output ->
            output["target"]["kind"] == rule.target_kind and
              output["target"]["key"] == rule.target_key
          end)

        cond do
          matches == 0 -> :none
          matches == length(row.outputs) -> :full
          true -> :partial
        end
    end
  end

  defp matching_rows(rule) do
    Repo.all(
      from(a in Assignment,
        where:
          a.source_id == ^rule.source_id and a.parameter_contract == ^rule.parameter_contract and
            is_nil(a.retired_at),
        order_by: a.id
      )
    )
    |> Enum.filter(&(match_rule(rule, &1) != :none))
  end

  defp affected_rows(candidate, locked, bounded) do
    old = if candidate.id, do: Repo.get(ConfigurationRule, candidate.id)

    query =
      from(a in Assignment,
        where:
          a.source_id == ^candidate.source_id and
            a.parameter_contract == ^candidate.parameter_contract and is_nil(a.retired_at),
        order_by: a.id
      )

    rows =
      Repo.all(if locked, do: lock(query, "FOR UPDATE"), else: query)
      |> Enum.filter(
        &((candidate.enabled and match_rule(candidate, &1) != :none) or
            (not is_nil(old) and old.enabled and match_rule(old, &1) != :none))
      )

    if bounded and length(rows) > @limit,
      do:
        Repo.rollback(
          {:invalid, "More than 512 checks match. Narrow the rule scope before reviewing it."}
        )

    rows
  end

  # Scope counts describe the declaration, independently of enablement and the
  # affected old/new union in counts.matched. They are explanatory only: neither
  # excluded inventory nor these totals alter the reviewed state/token semantics.
  defp scope_counts(candidate) do
    previous = if candidate.id, do: Repo.get(ConfigurationRule, candidate.id)

    query =
      from(a in Assignment,
        where:
          a.source_id == ^candidate.source_id and
            a.parameter_contract == ^candidate.parameter_contract and is_nil(a.retired_at),
        select: struct(a, [:source_id, :parameter_contract, :environment, :outputs])
      )

    initial = %{
      "source_contract_total" => 0,
      "proposed_full" => 0,
      "proposed_partial" => 0,
      "excluded" => 0,
      "leaving_previous_scope" => 0,
      "released_from_rule" => 0,
      "proposed_enabled" => candidate.enabled
    }

    # A disabled broad rule can describe more checks than the mutation bound.
    # Stream only scope fields rather than returning or retaining that inventory.
    query
    |> Repo.stream(max_rows: 100)
    |> Enum.reduce(initial, fn row, counts ->
      matched = match_rule(candidate, row)
      previous_match = previous && previous.enabled && match_rule(previous, row) != :none

      key =
        case matched do
          :full -> "proposed_full"
          :partial -> "proposed_partial"
          :none -> "excluded"
        end

      counts =
        counts |> Map.update!("source_contract_total", &(&1 + 1)) |> Map.update!(key, &(&1 + 1))

      counts =
        if previous_match && matched == :none,
          do: Map.update!(counts, "leaving_previous_scope", &(&1 + 1)),
          else: counts

      if previous_match && (not candidate.enabled || matched == :none),
        do: Map.update!(counts, "released_from_rule", &(&1 + 1)),
        else: counts
    end)
  end

  defp summary(rows, all, page) do
    entries =
      Enum.map(rows, fn row ->
        base = %{
          "id" => row.id,
          "label" => row.label,
          "runner_id" => row.runner_id,
          "environment" => row.environment,
          "outputs" => row.outputs,
          "current_params" => row.params,
          "parameter_schema" => row.parameter_schema,
          "revision" => row.revision,
          "instance_exception" => is_map(row.instance_exception)
        }

        case resolve(row, all) do
          {:ok, params, origin} ->
            Map.merge(base, %{
              "proposed_params" => params,
              "origin" => origin,
              "changed" =>
                not Parameters.same_json?(params, row.params) or
                  not Parameters.same_json?(origin, row.configuration_origin),
              "error" => nil
            })

          {:error, reason, ids} ->
            Map.merge(base, %{
              "proposed_params" => nil,
              "origin" => nil,
              "changed" => false,
              "error" => reason,
              "rule_ids" => ids
            })
        end
      end)

    page_result(entries, page, "rows")
    |> Map.put("counts", %{
      "matched" => length(entries),
      "changed" => Enum.count(entries, & &1["changed"]),
      "exceptions" => Enum.count(entries, & &1["instance_exception"]),
      "conflicts" => Enum.count(entries, & &1["error"]),
      "results" => Enum.sum(Enum.map(rows, &length(&1.outputs)))
    })
  end

  def public_rule(rule, inspect? \\ false) do
    public =
      Monitoring.public(rule)
      |> Map.take(@fields ++ ["saved_at", "managed_project", "managed_key"])

    if inspect? do
      rows = matching_rows(rule)
      counts = summary(rows, rules_for(rule.source_id), 1)["counts"]

      public
      |> Map.put("match_count", length(rows))
      |> Map.put("conflict_count", counts["conflicts"])
      |> Map.put(
        "diagnostics",
        Enum.filter(diagnostics(rule.source_id), &(rule.id in &1["rule_ids"]))
      )
    else
      public
    end
  end

  @doc false
  def repository_candidate!(attributes, existing) do
    proposal =
      attributes
      |> Map.put("id", existing && existing.id)
      |> Map.put("revision", if(existing, do: existing.revision, else: 0))
      |> validate_proposal!()

    validate_revision!(proposal)
    validate_source_schema!(proposal)
    {candidate, _} = proposed_rules(proposal)
    %{candidate | id: if(existing, do: existing.id, else: Ecto.UUID.generate())}
  end

  defp validate_proposal!(proposal) when is_map(proposal) do
    p =
      Map.take(proposal, @fields)
      |> Map.put_new("revision", 0)
      |> Map.put_new("environment", nil)
      |> Map.put_new("target_kind", nil)
      |> Map.put_new("target_key", nil)

    valid =
      Parameters.text?(p["name"], 200) and Parameters.text?(p["source_id"], 200) and
        Parameters.text?(p["parameter_contract"], 128) and is_integer(p["revision"]) and
        p["revision"] in 0..2_147_483_646 and
        is_integer(p["priority"]) and p["priority"] in -10000..10000 and is_boolean(p["enabled"]) and
        (is_nil(p["id"]) or match?({:ok, _}, Ecto.UUID.cast(p["id"]))) and
        (is_nil(p["environment"]) or Parameters.text?(p["environment"], 128)) and
        ((is_nil(p["target_kind"]) and is_nil(p["target_key"])) or
           (Parameters.text?(p["target_kind"], 64) and Parameters.text?(p["target_key"], 200)))

    if not valid,
      do:
        Repo.rollback(
          {:invalid,
           "Supply a name, source, parameter contract, valid scope, priority and reviewed rule revision."}
        )

    case Parameters.validate(p["parameter_schema"], p["params"]) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid, reason})
    end

    if map_size(p["parameter_schema"]["fields"]) == 0,
      do: Repo.rollback({:invalid, "Rules require a nonempty delegated parameter schema."})

    p
    |> Map.update!("parameter_schema", &Parameters.normalized_schema/1)
    |> Map.update!("params", &Parameters.normalized_json/1)
  end

  defp validate_proposal!(_),
    do: Repo.rollback({:invalid, "Supply a complete configuration rule."})

  defp validate_revision!(proposal) do
    if proposal["id"] do
      current = find_rule(proposal["id"])
      if is_nil(current), do: Repo.rollback(:not_found)

      if current.revision != proposal["revision"], do: Repo.rollback(:stale)

      if current.source_id != proposal["source_id"] or
           current.parameter_contract != proposal["parameter_contract"],
         do:
           Repo.rollback(
             {:invalid,
              "A rule's source and parameter contract cannot change. Create another rule for different meaning."}
           )
    else
      if proposal["revision"] != 0, do: Repo.rollback(:stale)

      if Repo.aggregate(ConfigurationRule, :count) >= @limit,
        do: Repo.rollback({:invalid, "At most 512 durable rules are supported."})
    end
  end

  defp lock_catalog!(%{"id" => id}) when is_binary(id), do: :ok
  defp lock_catalog!(_), do: Repo.query!("SELECT pg_advisory_xact_lock(774008)")

  defp validate_source_schema!(proposal) do
    current = if proposal["id"], do: find_rule(proposal["id"])

    captured =
      not is_nil(current) and
        Parameters.same_json?(
          Parameters.normalized_schema(current.parameter_schema),
          proposal["parameter_schema"]
        )

    source = proposal["source_id"]
    contract = proposal["parameter_contract"]

    schemas =
      Repo.all(
        from(a in Assignment,
          where:
            a.source_id == ^source and a.parameter_contract == ^contract and
              a.params_owner == "ui" and is_nil(a.retired_at),
          select: a.parameter_schema
        )
      )

    if not captured and
         not Enum.any?(
           schemas,
           &Parameters.same_json?(Parameters.normalized_schema(&1), proposal["parameter_schema"])
         ),
       do:
         Repo.rollback(
           {:invalid,
            "Use the schema declared by an existing delegated check in this source and contract, or keep the rule's captured schema."}
         )
  end

  defp proposed_rules(proposal) do
    attributes = Map.new(proposal, fn {key, value} -> {String.to_existing_atom(key), value} end)

    existing = if proposal["id"], do: find_rule(proposal["id"])

    candidate =
      struct(
        existing || %ConfigurationRule{},
        Map.merge(attributes, %{
          id: proposal["id"] || "00000000-0000-0000-0000-000000000000",
          revision: proposal["revision"] + 1
        })
      )

    all = rules_for(candidate.source_id) |> Enum.reject(&(&1.id == candidate.id))
    {candidate, [candidate | all]}
  end

  defp state_fingerprint(source, rows) do
    fingerprint(%{
      "rules" => Enum.map(if(source, do: rules_for(source), else: []), &public_rule/1),
      "rows" =>
        Enum.map(
          rows,
          &(Monitoring.public(&1)
            |> Map.take(
              ~w(id revision source_id source_key parameter_contract parameter_schema params source_defaults instance_exception configuration_origin discovery outputs environment retired_at runner_id)
            ))
        )
    })
  end

  @doc false
  def ensure_bounds!(rows, rules) do
    replacements =
      Map.new(rows, fn row ->
        candidate =
          case resolve(row, rules) do
            {:ok, params, _} ->
              %{row | params: params, desired_generation: row.desired_generation + 1}

            _ ->
              row
          end

        {row.id, candidate}
      end)

    for runner <- rows |> Enum.map(& &1.runner_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        do: Monitoring.ensure_control_bound!(runner, replacements)
  end

  defp lock_runners!(rows) do
    ids = rows |> Enum.map(& &1.runner_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    Repo.all(from(r in Runner, where: r.id in ^ids, order_by: r.id, lock: "FOR NO KEY UPDATE"))
  end

  defp lock_instance!(id, revision) do
    row = if Mondek.Protocol.assignment_id?(id), do: Repo.get(Assignment, id)
    if is_nil(row), do: Repo.rollback(:not_found)
    lock_source!(row.source_id)
    lock_runners!([row])
    row = Monitoring.lock_assignment(id)
    if row.revision != revision, do: Repo.rollback(:stale)
    if row.retired_at, do: Repo.rollback(:retired)

    if row.params_owner != "ui",
      do: Repo.rollback(:source_owned)

    row
  end

  defp find_rule(id) do
    if match?({:ok, _}, Ecto.UUID.cast(id)), do: Repo.get(ConfigurationRule, id)
  end

  defp page_result(rows, requested, key) do
    page =
      case requested do
        n when is_integer(n) and n > 0 ->
          n

        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} when n > 0 -> n
            _ -> 1
          end

        _ ->
          1
      end

    page = min(page, max(1, div(length(rows) + @page_size - 1, @page_size)))

    %{
      key => Enum.slice(rows, (page - 1) * @page_size, @page_size),
      "page" => page,
      "page_size" => @page_size,
      "total" => length(rows)
    }
  end

  defp fingerprint(value),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Parameters.normalized_json(value), [:deterministic])
      )
      |> Base.encode16(case: :lower)

  defp sign(purpose, data),
    do: Phoenix.Token.sign(MondekWeb.Endpoint, "configuration-rules/" <> purpose, data)

  defp verify(purpose, token) when is_binary(token) and byte_size(token) <= 131_072 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "configuration-rules/" <> purpose, token,
           max_age: @max_age
         ) do
      {:ok, data} -> {:ok, data}
      {:error, :expired} -> {:error, :review_expired}
      _ -> {:error, :invalid_review}
    end
  end

  defp verify(_, _), do: {:error, :invalid_review}

  defp verify_again!(purpose, token) do
    case verify(purpose, token) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
