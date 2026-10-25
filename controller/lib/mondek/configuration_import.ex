# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationImport do
  @moduledoc "Validate and apply a complete Git tree under caller-held repository serialization."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Assignment,
    ConfigurationRule,
    ConfigurationRules,
    Monitoring,
    Parameters,
    Runner
  }

  @rule_fields ~w(key name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params managed_project managed_key)
  @exception_fields ~w(key installation_specific scope parameter_contract parameter_schema params environment outputs)

  def apply!(files) do
    if map_size(files) > 4097 or
         Enum.reduce(files, 0, fn {_, body}, n -> n + byte_size(body) end) > 4_194_304,
       do: invalid!("Configuration exceeds 4096 resources or 4 MiB")

    documents =
      Map.new(files, fn {path, body} ->
        value =
          case Jason.decode(body) do
            {:ok, value} when is_map(value) -> value
            _ -> invalid!("#{path}: expected a JSON object")
          end

        {path, value}
      end)

    if documents["mondek.json"] != %{"version" => 1},
      do: invalid!("mondek.json must contain version 1")

    Enum.each(documents, fn {path, _} ->
      if path != "mondek.json" and
           not Regex.match?(~r/\A(rules|exceptions)\/[A-Za-z0-9_.-]{1,200}\.json\z/, path),
         do: invalid!("Unsupported configuration file: #{String.slice(path, 0, 220)}")
    end)

    old_rules = Repo.all(ConfigurationRule)
    rule_docs = scoped(documents, "rules/")
    if length(rule_docs) > 512, do: invalid!("At most 512 rules are supported")

    sources =
      (Enum.map(old_rules, & &1.source_id) ++
         Enum.map(rule_docs, fn {_, value} -> value["source_id"] end))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Exception-only sources also participate in the same lock order.
    exception_docs = scoped(documents, "exceptions/")
    exceptions = Repo.all(from a in Assignment, where: not is_nil(a.instance_exception))

    Enum.each(exception_docs, fn {path, value} ->
      exact!(value, @exception_fields, path)
      exact!(value["scope"], ~w(assignment_id runner_installation_id source_id check_key), path)
    end)

    sources =
      (sources ++
         Enum.map(exceptions, & &1.source_id) ++
         Enum.map(exception_docs, fn {_, value} -> get_in(value, ["scope", "source_id"]) end))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    Repo.query!("SELECT pg_advisory_xact_lock(774008)")
    Enum.each(sources, &ConfigurationRules.lock_source!/1)
    # Bound atomic work before acquiring the runner and assignment locks.
    rows =
      Repo.all(
        from a in Assignment,
          where: a.source_id in ^sources,
          order_by: a.id
      )

    desired_rules =
      Enum.map(rule_docs, fn {path, value} ->
        exact!(value, @rule_fields, path)
        if not identifier?(value["key"]), do: invalid!("Rule key must be a valid identifier")
        if path != "rules/#{value["key"]}.json", do: invalid!("Rule key must match its filename")
        existing = Enum.find(old_rules, &(&1.repository_key == value["key"]))
        project = value["managed_project"]
        key = value["managed_key"]

        if not ((is_nil(project) and is_nil(key)) or
                  (identifier?(project) and identifier?(key))),
           do: invalid!("Project and managed key must both be valid identifiers or null")

        if existing && existing.managed_project &&
             {project, key} != {existing.managed_project, existing.managed_key},
           do: invalid!("An existing project's rule ownership cannot change implicitly")

        candidate = ConfigurationRules.repository_candidate!(value, existing)
        # Whitespace-only pushes do not advance rule revisions.
        attrs = Map.drop(value, ["key"])

        same =
          existing &&
            Enum.all?(attrs, fn {key, value} ->
              Parameters.same_json?(Map.get(existing, String.to_existing_atom(key)), value)
            end)

        %{
          candidate
          | repository_key: value["key"],
            managed_project: project,
            managed_key: key,
            revision: if(same, do: existing.revision, else: candidate.revision)
        }
      end)

    ownership =
      desired_rules
      |> Enum.reject(&is_nil(&1.managed_project))
      |> Enum.map(&{&1.managed_project, &1.managed_key})

    if length(ownership) != length(Enum.uniq(ownership)),
      do: invalid!("Duplicate project rule key")

    desired_exceptions =
      Map.new(exception_docs, fn {path, value} ->
        exact!(value, @exception_fields, path)

        if not identifier?(value["key"]), do: invalid!("Exception key must be a valid identifier")

        if path != "exceptions/#{value["key"]}.json" or value["installation_specific"] != true,
          do: invalid!("Exception key/scope must remain explicit")

        scope = value["scope"]
        exact!(scope, ~w(assignment_id runner_installation_id source_id check_key), path)
        row = Enum.find(rows, &(&1.id == scope["assignment_id"]))

        if is_nil(row),
          do:
            invalid!(
              "#{path}: instance is absent; publish its runner and explicitly map the assignment/runner identity before restoration"
            )

        if {row.runner_id, row.source_id, row.source_key, row.parameter_contract, row.environment} !=
             {scope["runner_installation_id"], scope["source_id"], scope["check_key"],
              value["parameter_contract"], value["environment"]},
           do:
             invalid!("#{path}: instance identity changed; explicit restore mapping is required")

        if row.params_owner != "ui" or
             not Parameters.same_json?(row.parameter_schema, value["parameter_schema"]) or
             not Parameters.same_json?(
               Enum.map(row.outputs, fn output ->
                 %{"key" => output["key"], "target" => Map.take(output["target"], ~w(kind key))}
               end),
               value["outputs"]
             ),
           do:
             invalid!(
               "#{path}: declaration differs; review instance scope/schema before restoration"
             )

        case Parameters.validate(row.parameter_schema, value["params"]) do
          :ok -> :ok
          {:error, reason} -> invalid!(reason)
        end

        existing_key_owner =
          Repo.one(
            from a in Assignment,
              where:
                a.id != ^row.id and
                  (a.configuration_exception_key == ^value["key"] or a.id == ^value["key"]),
              limit: 1
          )

        if existing_key_owner && existing_key_owner.id != row.id,
          do:
            invalid!(
              "#{path}: exception key already belongs to another instance; use a new key for a different scope"
            )

        {row.id, %{params: value["params"], key: value["key"]}}
      end)

    if map_size(desired_exceptions) != length(exception_docs),
      do: invalid!("Multiple exceptions cannot configure the same instance")

    changed_rules =
      Enum.filter(old_rules ++ desired_rules, fn rule ->
        before = Enum.find(old_rules, &(&1.repository_key == rule.repository_key))
        after_rule = Enum.find(desired_rules, &(&1.repository_key == rule.repository_key))

        is_nil(before) or is_nil(after_rule) or
          Enum.any?(@rule_fields -- ["key"], fn field ->
            key = String.to_existing_atom(field)
            not Parameters.same_json?(Map.get(before, key), Map.get(after_rule, key))
          end)
      end)

    affected =
      Enum.filter(rows, fn row ->
        desired = desired_exceptions[row.id]
        desired_params = desired && desired.params

        exception_changed =
          not Parameters.same_json?(row.instance_exception, desired_params) or
            (desired && row.configuration_exception_key != desired.key)

        row.source_id &&
          (exception_changed ||
             (is_nil(row.retired_at) &&
                Enum.any?(changed_rules, &(ConfigurationRules.match_rule(&1, row) != :none))))
      end)

    if length(affected) > 512,
      do:
        invalid!(
          "This repository apply affects more than 512 checks; split the change into smaller commits"
        )

    runner_ids =
      affected |> Enum.map(& &1.runner_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    Repo.all(
      from r in Runner, where: r.id in ^runner_ids, order_by: r.id, lock: "FOR NO KEY UPDATE"
    )

    ids = Enum.map(affected, & &1.id)

    affected =
      Repo.all(from a in Assignment, where: a.id in ^ids, order_by: a.id, lock: "FOR UPDATE")

    replaced =
      Enum.map(affected, fn row ->
        case desired_exceptions[row.id] do
          nil ->
            %{row | instance_exception: nil}

          desired ->
            %{row | instance_exception: desired.params, configuration_exception_key: desired.key}
        end
      end)

    Enum.each(replaced, fn row ->
      if row.source_id && is_nil(row.retired_at) do
        case ConfigurationRules.resolve(row, desired_rules) do
          {:ok, _, _} -> :ok
          {:error, reason, _} -> invalid!(reason)
        end
      end
    end)

    ConfigurationRules.ensure_bounds!(
      Enum.filter(replaced, &is_nil(&1.retired_at)),
      desired_rules
    )

    at = Monitoring.now()
    wanted = Enum.map(desired_rules, & &1.id)
    Repo.delete_all(from r in ConfigurationRule, where: r.id not in ^wanted)

    for rule <- desired_rules do
      case Repo.get(ConfigurationRule, rule.id) do
        nil ->
          Repo.insert!(%{rule | saved_at: at})

        existing ->
          Monitoring.change(
            existing,
            Map.from_struct(rule) |> Map.drop([:__meta__, :id]) |> Map.put(:saved_at, at)
          )
      end
    end

    for row <- replaced do
      original = Enum.find(rows, &(&1.id == row.id))

      if row.source_id do
        if row.retired_at do
          Monitoring.change(original, %{
            instance_exception: row.instance_exception,
            configuration_exception_key: row.configuration_exception_key
          })
        else
          {:ok, params, origin} = ConfigurationRules.resolve(row, desired_rules)

          Monitoring.set_effective_configuration!(original, params, origin, at, %{
            instance_exception: row.instance_exception,
            configuration_exception_key: row.configuration_exception_key
          })
        end
      end
    end

    for runner <- runner_ids, do: Monitoring.ensure_control_bound!(runner)
    :ok
  end

  defp scoped(documents, prefix),
    do: Enum.filter(documents, fn {path, _} -> String.starts_with?(path, prefix) end)

  defp exact!(value, fields, path) do
    if not is_map(value) or Enum.sort(Map.keys(value)) != Enum.sort(fields),
      do: invalid!("#{path}: unsupported or missing fields")
  end

  defp identifier?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, value)

  defp invalid!(reason), do: Repo.rollback({:invalid, reason})
end
