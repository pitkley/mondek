# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationPolicy do
  @moduledoc "Explicit, reviewed reconciliation of one project's optional controller policy."
  import Ecto.Query
  import Kernel, except: [apply: 2]

  alias Mondek.{
    Assignment,
    ConfigurationRule,
    ConfigurationRules,
    ConfigurationPolicyProject,
    ConfigurationPolicyReceipt,
    Monitoring,
    Parameters,
    Repo,
    Runner
  }

  @rule_fields ~w(key name source_id parameter_contract params environment target_kind target_key priority enabled adopt_rule_id)
  @attributes ~w(name source_id parameter_contract params environment target_kind target_key priority enabled parameter_schema)
  @row_fields ~w(id revision source_id source_key parameter_contract parameter_schema params_owner params source_defaults instance_exception configuration_origin outputs environment retired_at runner_id definition_revision)
  @page_size 25
  @max_age 900

  def plan(manifest, base_head \\ nil) do
    Repo.transaction(fn ->
      Mondek.ConfigurationRepository.lock!()
      Mondek.ConfigurationRepository.initialize!()
      head = Mondek.ConfigurationRepository.head!()
      manifest = validate_manifest!(manifest)
      context = prepare!(manifest)
      result = review(context)
      changed = Enum.any?(context.changes, &(&1["action"] != "noop"))

      if not is_nil(base_head) and base_head != head,
        do:
          invalid!(
            "Configuration changed since --base. Fetch and reconcile UI/Git changes before planning again."
          )

      if changed and project_revision(manifest["project"]) > 0 and is_nil(base_head),
        do:
          invalid!(
            "Existing project changes require --base HEAD. Fetch and review current configuration history, reconcile your document, then supply that Git revision; prefer editing the configuration repository directly."
          )

      token =
        if result["counts"]["conflicts"] == 0 do
          sign(%{
            "manifest" => hash(manifest),
            "repository_head" => head,
            "state" => state_hash(context),
            "ids" => context.ids
          })
        end

      result |> Map.put("review_token", token) |> Map.put("repository_head", head)
    end)
  end

  def apply(token, manifest) do
    result =
      Mondek.ConfigurationRepository.transaction("policy", fn ->
        manifest = validate_manifest!(manifest)
        if not is_binary(token) or byte_size(token) > 131_072, do: Repo.rollback(:invalid_review)
        # The catalog lock also serializes competing project applies and rule creation.
        catalog_lock!()
        receipt = Repo.get(ConfigurationPolicyReceipt, hash(token))

        if receipt do
          if receipt.manifest_hash != hash(manifest) or receipt.project != manifest["project"],
            do: Repo.rollback(:review_changed)

          current = project_revision(receipt.project)

          receipt.response
          |> Map.merge(%{
            "replayed" => true,
            "superseded" => current != receipt.project_revision,
            "current_project_revision" => current
          })
        else
          reviewed = verify!(token)

          if not is_binary(reviewed["repository_head"]),
            do:
              invalid!(
                "This unapplied plan predates configuration history. Fetch current configuration and generate a new plan with --base HEAD."
              )

          if reviewed["repository_head"] != Mondek.ConfigurationRepository.head!(),
            do: Repo.rollback(:stale)

          if reviewed["manifest"] != hash(manifest), do: Repo.rollback(:review_changed)
          context = prepare!(manifest, reviewed["ids"])
          lock_runners!(context.rows)
          # Source locks prevent inventory, exception and rule changes during this read.
          ids = Enum.map(context.rows, & &1.id)
          Repo.all(from a in Assignment, where: a.id in ^ids, order_by: a.id, lock: "FOR UPDATE")
          if reviewed["state"] != state_hash(context), do: Repo.rollback(:stale)
          verify!(token)
          review = review(context)

          if review["counts"]["conflicts"] > 0,
            do:
              Repo.rollback(
                {:conflict, "Resolve the policy's configuration conflicts before applying."}
              )

          ConfigurationRules.ensure_bounds!(context.rows, context.final)
          persist!(context, review, token)
        end
      end)

    if match?({:ok, _}, result), do: Monitoring.notify()
    if match?({:ok, _}, result), do: Monitoring.notify_control()
    result
  end

  def export(project) do
    Repo.transaction(fn ->
      validate_identifier!(project, "project")

      rules =
        Repo.all(
          from r in ConfigurationRule,
            where: r.managed_project == ^project,
            order_by: r.managed_key
        )

      %{"version" => 1, "project" => project, "rules" => Enum.map(rules, &manifest_rule/1)}
    end)
  end

  def values(source, requested_page \\ 1) do
    Repo.transaction(fn ->
      if not Parameters.text?(source, 200),
        do: invalid!("Supply a source_id to inspect its effective values.")

      ConfigurationRules.lock_source!(source)
      query = from a in Assignment, where: a.source_id == ^source and is_nil(a.retired_at)
      total = Repo.aggregate(query, :count)
      page = min(page_number(requested_page), max(1, div(total + @page_size - 1, @page_size)))

      rows =
        Repo.all(
          from a in query,
            order_by: [a.label, a.id],
            offset: ^((page - 1) * @page_size),
            limit: @page_size
        )

      rules = ConfigurationRules.rules_for(source)

      exceptions =
        Repo.aggregate(from(a in query, where: not is_nil(a.instance_exception)), :count)

      source_owned = Repo.aggregate(from(a in query, where: a.params_owner == "source"), :count)

      %{
        "source_id" => source,
        "rows" => Enum.map(rows, &value_details(&1, rules)),
        "page" => page,
        "page_size" => @page_size,
        "total" => total,
        "counts" => %{
          "checks" => total,
          "exceptions" => exceptions,
          "source_owned" => source_owned
        }
      }
    end)
  end

  def value_details(id) when is_binary(id) do
    row = if Mondek.Protocol.assignment_id?(id), do: Repo.get(Assignment, id)
    if row, do: value_details(row)
  end

  def value_details(%Assignment{} = row),
    do:
      value_details(
        row,
        if(row.source_id, do: ConfigurationRules.rules_for(row.source_id), else: [])
      )

  def value_details(row, rules) do
    proposed = ConfigurationRules.resolve(row, rules)
    fallback = ConfigurationRules.resolve(%{row | instance_exception: nil}, rules)
    {params, origin, error} = resolution(proposed)
    {masked_params, masked_origin, masked_error} = resolution(fallback)

    %{
      "id" => row.id,
      "label" => row.label,
      "source_id" => row.source_id,
      "source_key" => row.source_key,
      "params_owner" => row.params_owner,
      "parameter_contract" => row.parameter_contract,
      "runner_id" => row.runner_id,
      "environment" => row.environment,
      "outputs" => row.outputs,
      "source_defaults" => row.source_defaults,
      "current_params" => row.params,
      "current_origin" => row.configuration_origin,
      "proposed_params" => params,
      "proposed_origin" => origin,
      "error" => error,
      "masked_by_exception" => is_map(row.instance_exception),
      "masked_params" => masked_params,
      "masked_origin" => masked_origin,
      "masked_error" => masked_error,
      "revision" => row.revision,
      "target_generation" => row.desired_generation,
      "observed_generation" => row.observed_generation,
      "changed" =>
        is_nil(error) and
          (not Parameters.same_json?(params, row.params) or
             not Parameters.same_json?(origin, row.configuration_origin))
    }
  end

  defp resolution({:ok, params, origin}), do: {params, origin, nil}
  defp resolution({:error, reason, _ids}), do: {nil, nil, reason}

  defp prepare!(manifest, reviewed_ids \\ %{}) do
    catalog_lock!()
    project = manifest["project"]

    own =
      Repo.all(from r in ConfigurationRule, where: r.managed_project == ^project, order_by: r.id)

    sources =
      (Enum.map(own, & &1.source_id) ++ Enum.map(manifest["rules"], & &1["source_id"]))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(sources, &ConfigurationRules.lock_source!/1)
    all = Repo.all(from r in ConfigurationRule, where: r.source_id in ^sources, order_by: r.id)

    proposals =
      Enum.map(manifest["rules"], fn item ->
        current = Enum.find(own, &(&1.managed_key == item["key"]))
        adopted = adopted_rule!(item, current, project)
        base = current || adopted

        if base &&
             (base.source_id != item["source_id"] or
                base.parameter_contract != item["parameter_contract"]),
           do:
             invalid!(
               "A managed key's source and parameter contract cannot change. Remove the old key and add a new one."
             )

        {item, current, adopted, base}
      end)

    scopes =
      own ++
        Enum.flat_map(proposals, fn {item, _current, _adopted, base} ->
          [scope(item)] ++ if(base, do: [base], else: [])
        end)

    source_rows = affected_rows!(scopes)

    {desired, changes, ids} =
      Enum.reduce(proposals, {[], [], %{}}, fn {item, current, adopted, base},
                                               {desired, changes, ids} ->
        schema = authoritative_schema!(item, base, source_rows)

        if map_size(schema["fields"]) == 0,
          do: invalid!("Rules require a nonempty delegated parameter schema.")

        case Parameters.validate(schema, item["params"]) do
          :ok -> :ok
          {:error, reason} -> invalid!("Rule #{item["key"]}: #{reason}")
        end

        attributes =
          item
          |> Map.put("parameter_schema", schema)
          |> Map.take(@attributes)
          |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

        id = if base, do: base.id, else: reviewed_ids[item["key"]] || Ecto.UUID.generate()

        candidate =
          struct(
            base || %ConfigurationRule{},
            Map.merge(
              attributes,
              %{
                id: id,
                managed_project: project,
                managed_key: item["key"],
                revision: if(base, do: base.revision, else: 1)
              }
            )
          )

        unchanged = base && same_rule?(base, candidate)

        action =
          cond do
            current && unchanged -> "noop"
            current -> "update"
            adopted -> "adopt"
            true -> "create"
          end

        candidate =
          cond do
            unchanged ->
              base

            base && base.revision >= 2_147_483_647 ->
              invalid!("Rule #{item["key"]} exhausted its revision range.")

            base ->
              %{candidate | revision: base.revision + 1}

            true ->
              candidate
          end

        change = %{
          "action" => action,
          "key" => item["key"],
          "rule_id" => id,
          "before" => if(base, do: ConfigurationRules.public_rule(base)),
          "after" => ConfigurationRules.public_rule(candidate)
        }

        {[candidate | desired], [change | changes], Map.put(ids, item["key"], id)}
      end)

    desired = Enum.reverse(desired)
    removed = Enum.reject(own, fn old -> Enum.any?(desired, &(&1.id == old.id)) end)

    changes =
      Enum.reverse(changes) ++
        Enum.map(removed, fn rule ->
          %{
            "action" => "remove",
            "key" => rule.managed_key,
            "rule_id" => rule.id,
            "before" => ConfigurationRules.public_rule(rule),
            "after" => nil
          }
        end)

    removed_ids = Enum.map(removed, & &1.id)
    replaced_ids = Enum.map(desired, & &1.id)
    final = Enum.reject(all, &(&1.id in removed_ids or &1.id in replaced_ids)) ++ desired

    if Repo.aggregate(ConfigurationRule, :count) - length(removed) +
         Enum.count(changes, &(&1["action"] == "create")) > 512,
       do: invalid!("At most 512 durable rules are supported.")

    %{
      manifest: manifest,
      sources: sources,
      all: all,
      source_rows: source_rows,
      own: own,
      desired: desired,
      final: final,
      changes: changes,
      ids: ids,
      rows: source_rows,
      project_revision: project_revision(project)
    }
  end

  defp adopted_rule!(%{"adopt_rule_id" => id} = item, current, project) when is_binary(id) do
    candidate = Repo.get(ConfigurationRule, id)

    cond do
      is_nil(candidate) ->
        invalid!("The explicitly adopted rule #{id} no longer exists.")

      current && current.id != id ->
        invalid!("The managed key #{item["key"]} already owns a different rule.")

      candidate.managed_project &&
          (candidate.managed_project != project or candidate.managed_key != item["key"]) ->
        invalid!("Rule #{id} is already managed by another project or key.")

      true ->
        candidate
    end
  end

  defp adopted_rule!(_, _, _), do: nil

  defp authoritative_schema!(item, base, rows) do
    selected_scope = scope(item)

    schemas =
      rows
      |> Enum.filter(
        &(ConfigurationRules.match_rule(selected_scope, &1) != :none and &1.params_owner == "ui")
      )
      |> Enum.map(&Parameters.normalized_schema(&1.parameter_schema))
      |> Enum.uniq()

    # Existing dormant rules keep their reviewed schema, even when other disjoint
    # scopes evolve. A new future scope can borrow only an unambiguous contract.
    schemas =
      if schemas == [] and is_nil(base),
        do: contract_schemas(item),
        else: schemas

    case schemas do
      [schema] ->
        schema

      [] when not is_nil(base) ->
        Parameters.normalized_schema(base.parameter_schema)

      [] ->
        invalid!(
          "Rule #{item["key"]} needs an accepted check with delegated parameters for this source and contract. Publish the check definitions first."
        )

      _ ->
        invalid!(
          "Rule #{item["key"]} has ambiguous active parameter schemas. Align the source declarations or use different parameter contracts before planning."
        )
    end
  end

  defp contract_schemas(item) do
    Repo.all(
      from a in Assignment,
        where:
          a.source_id == ^item["source_id"] and
            a.parameter_contract == ^item["parameter_contract"] and a.params_owner == "ui" and
            is_nil(a.retired_at),
        distinct: a.parameter_schema_fingerprint,
        order_by: a.parameter_schema_fingerprint,
        limit: 2,
        select: a.parameter_schema
    )
    |> Enum.map(&Parameters.normalized_schema/1)
  end

  defp scope(item) do
    attributes =
      item
      |> Map.take(~w(source_id parameter_contract environment target_kind target_key))
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    struct(ConfigurationRule, attributes)
  end

  defp affected_rows!(scopes) do
    predicate =
      scopes
      |> Enum.uniq_by(
        &{&1.source_id, &1.parameter_contract, &1.environment, &1.target_kind, &1.target_key}
      )
      |> Enum.reduce(dynamic(false), fn scope, union ->
        selector =
          dynamic(
            [a],
            a.source_id == ^scope.source_id and a.parameter_contract == ^scope.parameter_contract
          )

        selector =
          if scope.environment,
            do: dynamic([a], ^selector and a.environment == ^scope.environment),
            else: selector

        selector =
          if scope.target_key do
            dynamic(
              [a],
              ^selector and
                fragment(
                  "EXISTS (SELECT 1 FROM unnest(?) AS output WHERE output->'target'->>'kind'=? AND output->'target'->>'key'=?)",
                  a.outputs,
                  ^scope.target_kind,
                  ^scope.target_key
                )
            )
          else
            selector
          end

        dynamic([a], ^union or ^selector)
      end)

    rows =
      Repo.all(
        from a in Assignment,
          where: is_nil(a.retired_at),
          where: ^predicate,
          order_by: a.id,
          limit: 513
      )

    if length(rows) > 512,
      do:
        invalid!(
          "More than 512 checks are affected. Narrow this project's rule scopes before reviewing it."
        )

    rows
  end

  defp review(context) do
    rows = Enum.map(context.rows, &value_details(&1, context.final))

    counts = %{
      "matched" => length(rows),
      "changed" => Enum.count(rows, & &1["changed"]),
      "exceptions" => Enum.count(rows, & &1["masked_by_exception"]),
      "conflicts" => Enum.count(rows, &(not is_nil(&1["error"])))
    }

    counts =
      Enum.reduce(~w(create update remove adopt noop), counts, fn action, counts ->
        Map.put(counts, action, Enum.count(context.changes, &(&1["action"] == action)))
      end)

    ConfigurationRules.ensure_bounds!(context.rows, context.final)

    %{
      "version" => 1,
      "manifest" => context.manifest,
      "project" => context.manifest["project"],
      "project_revision" => context.project_revision,
      "changes" => context.changes,
      "counts" => counts,
      "rows" => rows
    }
  end

  defp persist!(context, review, token) do
    at = Monitoring.now()

    for change <- context.changes do
      case change["action"] do
        "noop" ->
          :ok

        "remove" ->
          Repo.delete!(Repo.get!(ConfigurationRule, change["rule_id"]))

        action ->
          candidate = Enum.find(context.desired, &(&1.id == change["rule_id"]))

          if action == "create" do
            Repo.insert!(%{candidate | saved_at: at})
          else
            Monitoring.change(
              Repo.get!(ConfigurationRule, candidate.id),
              Map.from_struct(candidate) |> Map.drop([:__meta__, :id]) |> Map.put(:saved_at, at)
            )
          end
      end
    end

    receipts =
      Enum.map(context.rows, fn row ->
        {:ok, params, origin} = ConfigurationRules.resolve(row, context.final)
        saved = Monitoring.set_effective_configuration!(row, params, origin, at)

        %{
          "id" => row.id,
          "revision" => saved.revision,
          "target_generation" => saved.desired_generation,
          "changed" => saved.revision != row.revision
        }
      end)

    for runner <- context.rows |> Enum.map(& &1.runner_id) |> Enum.uniq(),
        do: Monitoring.ensure_control_bound!(runner)

    project = context.manifest["project"]
    revision = context.project_revision + 1

    Repo.insert!(%ConfigurationPolicyProject{id: project, revision: revision},
      on_conflict: {:replace, [:revision]},
      conflict_target: [:id]
    )

    response = %{
      "project" => project,
      "manifest" => context.manifest,
      "changes" => review["changes"],
      "changed_count" => Enum.count(receipts, & &1["changed"]),
      "receipts" => receipts,
      "replayed" => false,
      "superseded" => false,
      "applied_project_revision" => revision,
      "current_project_revision" => revision
    }

    Repo.insert!(%ConfigurationPolicyReceipt{
      id: hash(token),
      project: project,
      project_revision: revision,
      manifest_hash: hash(context.manifest),
      response: response,
      applied_at: at
    })

    response
  end

  defp validate_manifest!(manifest) when is_map(manifest) do
    if Map.keys(manifest) -- ~w(version project rules) != [],
      do:
        invalid!("Unknown policy document fields. Only version, project and rules are supported.")

    if manifest["version"] !== 1, do: invalid!("Policy version must be the integer 1.")
    validate_identifier!(manifest["project"], "project")

    if not is_list(manifest["rules"]) or length(manifest["rules"]) > 64,
      do:
        invalid!(
          "Supply a rules list with at most 64 rules; an empty list explicitly removes this project's managed rules."
        )

    rules = Enum.map(manifest["rules"], &validate_rule!/1)
    keys = Enum.map(rules, & &1["key"])
    adopted = rules |> Enum.map(& &1["adopt_rule_id"]) |> Enum.reject(&is_nil/1)

    if length(Enum.uniq(keys)) != length(keys),
      do: invalid!("Each managed rule key must be unique within its project.")

    if length(Enum.uniq(adopted)) != length(adopted),
      do: invalid!("An existing rule may only be adopted once per policy document.")

    %{
      "version" => 1,
      "project" => manifest["project"],
      "rules" => Enum.sort_by(rules, & &1["key"])
    }
  end

  defp validate_manifest!(_),
    do: invalid!("Supply a policy document with version, project and rules.")

  defp validate_rule!(rule) when is_map(rule) do
    if Map.keys(rule) -- @rule_fields != [],
      do:
        invalid!(
          "Unknown rule fields. Schemas come from check code; selector names must be exact."
        )

    validate_identifier!(rule["key"], "rule key")

    rule =
      rule
      |> Map.put_new("priority", 0)
      |> Map.put_new("enabled", true)
      |> Map.put_new("environment", nil)
      |> Map.put_new("target_kind", nil)
      |> Map.put_new("target_key", nil)

    valid =
      Parameters.text?(rule["name"], 200) and Parameters.text?(rule["source_id"], 200) and
        Parameters.text?(rule["parameter_contract"], 128) and is_map(rule["params"]) and
        is_integer(rule["priority"]) and rule["priority"] in -10000..10000 and
        is_boolean(rule["enabled"]) and
        (is_nil(rule["environment"]) or Parameters.text?(rule["environment"], 128)) and
        ((is_nil(rule["target_kind"]) and is_nil(rule["target_key"])) or
           (Parameters.text?(rule["target_kind"], 64) and
              Parameters.text?(rule["target_key"], 200))) and
        (not Map.has_key?(rule, "adopt_rule_id") or canonical_uuid?(rule["adopt_rule_id"]))

    if not valid,
      do:
        invalid!(
          "Rule #{rule["key"]} requires a name, source, contract, complete parameters, valid selectors, priority and enabled flag."
        )

    rule = Map.update!(rule, "params", &Parameters.normalized_json/1)

    if Map.has_key?(rule, "adopt_rule_id"),
      do:
        Map.update!(rule, "adopt_rule_id", fn id ->
          {:ok, canonical} = Ecto.UUID.cast(id)
          canonical
        end),
      else: rule
  end

  defp validate_rule!(_), do: invalid!("Every policy rule must be an object.")

  # Ecto also casts arbitrary 16-byte raw binaries; the public document accepts
  # only the readable UUID form used by the CLI and exported API resources.
  defp canonical_uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and match?({:ok, _}, Ecto.UUID.cast(value))

  defp validate_identifier!(value, label) do
    if not is_binary(value) or not String.match?(value, ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/),
      do:
        invalid!(
          "The #{label} must be 1–128 letters, digits, dots, underscores or hyphens, starting with a letter or digit."
        )
  end

  defp manifest_rule(rule),
    do:
      ConfigurationRules.public_rule(rule)
      |> Map.take(@rule_fields -- ~w(key adopt_rule_id))
      |> Map.put("key", rule.managed_key)

  defp same_rule?(a, b),
    do:
      Parameters.same_json?(
        ConfigurationRules.public_rule(a) |> Map.drop(~w(id revision saved_at)),
        ConfigurationRules.public_rule(b) |> Map.drop(~w(id revision saved_at))
      )

  defp state_hash(context),
    do:
      hash(%{
        "project_revision" => context.project_revision,
        "rules" => Enum.map(context.all, &ConfigurationRules.public_rule/1),
        "schemas" => Map.new(context.desired, &{&1.managed_key, &1.parameter_schema}),
        "rows" => Enum.map(context.source_rows, &(Monitoring.public(&1) |> Map.take(@row_fields)))
      })

  defp project_revision(project) do
    case Repo.get(ConfigurationPolicyProject, project) do
      nil -> 0
      row -> row.revision
    end
  end

  defp catalog_lock!, do: Repo.query!("SELECT pg_advisory_xact_lock(774008)")

  defp lock_runners!(rows) do
    ids = rows |> Enum.map(& &1.runner_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    Repo.all(from r in Runner, where: r.id in ^ids, order_by: r.id, lock: "FOR NO KEY UPDATE")
  end

  defp page_number(value) when is_integer(value) and value > 0, do: value

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp page_number(_), do: 1
  defp invalid!(message), do: Repo.rollback({:invalid, message})

  defp hash(value),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Parameters.normalized_json(value), [:deterministic])
      )
      |> Base.encode16(case: :lower)

  defp sign(data), do: Phoenix.Token.sign(MondekWeb.Endpoint, "configuration-policy", data)

  defp verify!(token) do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "configuration-policy", token,
           max_age: @max_age
         ) do
      {:ok, data} -> data
      {:error, :expired} -> Repo.rollback(:review_expired)
      _ -> Repo.rollback(:invalid_review)
    end
  end
end
