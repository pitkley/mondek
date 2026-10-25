# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Inventory do
  @moduledoc "Atomic reconciliation of a runner's complete, exported source membership."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Monitoring,
    Parameters,
    Assignment,
    Configuration,
    SourceInventory,
    ResultStream
  }

  def reconcile(p, at) do
    with :ok <- validate(p) do
      result =
        Mondek.ConfigurationRepository.transaction("inventory", fn ->
          Mondek.ConfigurationRules.lock_source!(p["source_id"])
          rules = Mondek.ConfigurationRules.rules_for(p["source_id"])
          runner = Monitoring.register_runner(p, at)

          source =
            Repo.one(
              from s in SourceInventory,
                where: s.runner_id == ^runner.id and s.source_id == ^p["source_id"],
                lock: "FOR UPDATE"
            )

          semantic =
            p
            |> Map.take(~w(source_id source_revision checks complete coverage catalog_selections))
            |> Parameters.normalized_json()

          reply =
            cond do
              source && source.retired_at ->
                Repo.rollback(:publisher_retired)

              source && source.resume_after_revision &&
                  (p["inventory_revision"] <= source.resume_after_revision or
                     p["restoration_revision"] != source.lifecycle_revision) ->
                Repo.rollback(:publication_refresh_required)

              source && source.revision > p["inventory_revision"] ->
                Repo.rollback(:stale_inventory)

              source && source.revision == p["inventory_revision"] &&
                  not Parameters.same_json?(source.payload, semantic) ->
                Repo.rollback(:inventory_conflict)

              source && source.revision == p["inventory_revision"] ->
                response(runner.id, p["source_id"], source.revision)

              true ->
                # The runner row serializes all its sources and their joint capacity.
                existing =
                  Repo.all(
                    from a in Assignment,
                      where:
                        a.runner_id == ^runner.id and a.source_id == ^p["source_id"] and
                          is_nil(a.retired_at),
                      order_by: a.id,
                      lock: "FOR UPDATE"
                  )

                Mondek.DiscoveryConfiguration.validate_retention!(p, existing)
                incoming = Map.new(p["checks"], &{&1["key"], &1})

                # Reconcile the complete inventory under all affected condition
                # locks before retiring any contribution. A multi-output edit is
                # one lifecycle change, independent of check declaration order.
                incoming_conditions =
                  for check <- p["checks"],
                      output <- check["outputs"],
                      output["condition"],
                      do: Map.put(output["condition"], "environment", check["environment"])

                Monitoring.lock_condition_streams!(
                  Enum.map(existing, & &1.id),
                  incoming_conditions
                )

                group_ids =
                  Repo.all(
                    from i in Mondek.Incident,
                      where:
                        i.assignment_id in ^Enum.map(existing, & &1.id) and i.status == "open" and
                          not is_nil(i.condition_incident_id),
                      select: i.condition_incident_id,
                      distinct: true
                  )

                for a <- existing, not Map.has_key?(incoming, a.source_key) do
                  Monitoring.retire_source_assignment!(
                    a,
                    "Source removed this check from its complete inventory.",
                    at,
                    reduce: false
                  )
                end

                by_key = Map.new(existing, &{&1.source_key, &1})

                for check <- p["checks"] do
                  reconcile_check(Map.get(by_key, check["key"]), check, p, runner, at, rules)
                end

                Mondek.Conditions.reduce!(group_ids, at)

                if Repo.aggregate(
                     from(a in Assignment,
                       where: a.runner_id == ^runner.id and is_nil(a.retired_at)
                     ),
                     :count
                   ) > 512,
                   do:
                     Repo.rollback(
                       {:invalid,
                        "A runner can provide at most 512 active checks across its sources."}
                     )

                Monitoring.ensure_control_bound!(runner.id)
                Mondek.ConfigurationRules.ensure_inventory_capacity!(p, rules)

                attrs = %{
                  revision: p["inventory_revision"],
                  source_revision: p["source_revision"],
                  payload: semantic,
                  received_at: at,
                  coverage_confirmed: false,
                  resume_after_revision: nil
                }

                source =
                  if source,
                    do: Monitoring.change(source, attrs),
                    else:
                      Repo.insert!(
                        struct(
                          SourceInventory,
                          Map.merge(attrs, %{runner_id: runner.id, source_id: p["source_id"]})
                        )
                      )

                Mondek.DiscoveryConfiguration.reconcile!(p, at)
                Mondek.Coverage.reconcile!(source, p)

                Mondek.ConfigurationRules.clear_diagnostics!(
                  p["source_id"],
                  runner.id,
                  p["inventory_revision"]
                )

                response(runner.id, p["source_id"], p["inventory_revision"])
            end

          # Dispatch serializes against membership and contact changes after
          # all assignment/condition locks, before this transaction commits.
          Mondek.MonitoringLoss.lock!()
          reply
        end)

      Monitoring.notify()
      if match?({:ok, _}, result), do: Monitoring.notify_control(p["installation_id"])

      case result do
        {:error, {:rule_conflict, diagnostic}} ->
          Mondek.ConfigurationRules.record_rejection(diagnostic, at)
          {:error, {:invalid, diagnostic.message}}

        other ->
          other
      end
    end
  end

  defp response(runner_id, source_id, revision) do
    count =
      Repo.aggregate(
        from(a in Assignment,
          where: a.runner_id == ^runner_id and a.source_id == ^source_id and is_nil(a.retired_at)
        ),
        :count
      )

    %{
      "version" => 1,
      "source_id" => source_id,
      "inventory_revision" => revision,
      "accepted_checks" => count
    }
  end

  defp reconcile_check(old, check, p, runner, at, rules) do
    preserved = old

    if old && old.params_owner == "ui" && check["params_owner"] != "ui",
      do: Repo.rollback({:invalid, "A source cannot reclaim UI-owned parameters."})

    # Diagnose a durable rule incompatibility before generic preserved-value
    # validation so a rejected new schema remains visible outside this rollback.
    preliminary =
      struct(preserved || %Assignment{}, %{
        source_id: p["source_id"],
        parameter_contract: check["parameter_contract"],
        parameter_schema: check["parameter_schema"],
        params_owner: check["params_owner"],
        environment: check["environment"],
        outputs: check["outputs"],
        source_defaults: check["params"]
      })

    if rules != [] and is_nil(preliminary.instance_exception),
      do: Mondek.ConfigurationRules.resolve_inventory!(preliminary, p, check, rules)

    params = preserved_params!(preserved, check)

    case Parameters.validate(check["parameter_schema"], params) do
      :ok ->
        :ok

      {:error, reason} ->
        guidance =
          if old && old.params_owner == "ui",
            do:
              " Saved operator values were preserved. Choose source defaults and constraints that accept them, adjust values under the accepted schema, or declare a new check identity.",
            else: ""

        Repo.rollback({:invalid, reason <> guidance})
    end

    params = Parameters.normalized_json(params)

    attrs = %{
      kind: "python",
      discovery: check["discovery"] || %{},
      label: check["label"],
      runner_id: runner.id,
      source_id: p["source_id"],
      source_key: check["key"],
      source_revision: p["source_revision"],
      definition_revision: check["definition_revision"],
      environment: check["environment"],
      environment_label: check["environment_label"] || check["environment"],
      params_owner: check["params_owner"],
      parameter_contract: check["parameter_contract"],
      parameter_schema_fingerprint:
        if(check["parameter_contract"],
          do: Parameters.schema_fingerprint(check["parameter_schema"])
        ),
      parameter_schema: Parameters.normalized_json(check["parameter_schema"]),
      params: params,
      source_defaults: source_defaults(old, check),
      instance_exception: if(preserved && is_map(preserved.instance_exception), do: params),
      outputs: Parameters.normalized_json(check["outputs"]),
      expected_keys: Enum.map(check["outputs"], & &1["key"]),
      interval_seconds: check["interval_seconds"] * 1.0,
      timeout_seconds: check["timeout_seconds"] * 1.0,
      freshness_seconds: check["freshness_seconds"] * 1.0
    }

    candidate = struct(old || %Assignment{}, attrs)

    case Parameters.validate(candidate.parameter_schema, candidate.source_defaults) do
      :ok ->
        :ok

      {:error, reason} ->
        Repo.rollback(
          {:invalid, "Saved source defaults must remain valid for rule fallback. " <> reason}
        )
    end

    {effective, origin} =
      Mondek.ConfigurationRules.resolve_inventory!(candidate, p, check, rules)

    effective = Parameters.normalized_json(effective)
    attrs = Map.merge(attrs, %{params: effective, configuration_origin: origin})
    params = effective

    assignment =
      if old do
        changed? =
          Enum.any?(attrs, fn {key, value} ->
            not Parameters.same_json?(Map.get(old, key), value)
          end)

        if changed?,
          do:
            Monitoring.change(
              old,
              Map.merge(attrs, %{
                revision: old.revision + 1,
                desired_generation: old.desired_generation + 1
              })
            ),
          else: old
      else
        Repo.insert!(struct(Assignment, Map.put(attrs, :id, Ecto.UUID.generate())))
      end

    if is_nil(old) or assignment.desired_generation != old.desired_generation do
      Repo.insert!(%Configuration{
        assignment_id: assignment.id,
        generation: assignment.desired_generation,
        params: params,
        definition: definition(assignment),
        saved_at: at
      })
    end

    active_streams =
      if old,
        do:
          Repo.all(
            from s in ResultStream,
              where: s.assignment_id == ^assignment.id and is_nil(s.retired_at),
              order_by: s.id,
              lock: "FOR UPDATE"
          ),
        else: []

    outputs = Map.new(assignment.outputs, &{&1["key"], &1})

    for stream <- active_streams do
      output = outputs[stream.result_key]

      condition_changed? =
        not is_nil(output) and
          condition_identity(stream.condition) != condition_identity(output["condition"])

      if is_nil(output) or condition_changed? or
           (Map.take(stream.target, ~w(key kind)) != Map.take(output["target"], ~w(key kind)) or
              stream.environment != assignment.environment) do
        Monitoring.retire_source_stream!(
          stream,
          assignment,
          if(condition_changed?,
            do:
              "Source changed this result's condition relationship; prior evidence and controls remain with the old stream.",
            else: "Source removed or rebound this result target or monitored environment."
          ),
          at,
          if(condition_changed?, do: "condition_changed", else: "source_removed"),
          reduce: false
        )
      end
    end

    for output <- assignment.outputs do
      # Newly inserted assignments cannot already have result streams.
      stream =
        if old,
          do:
            Repo.one(
              from s in ResultStream,
                where:
                  s.assignment_id == ^assignment.id and s.result_key == ^output["key"] and
                    is_nil(s.retired_at)
            )

      if stream,
        do:
          Monitoring.change(stream, %{
            label: output["label"],
            target: output["target"],
            condition: output["condition"],
            check_group: output["group"],
            environment: assignment.environment,
            environment_label: assignment.environment_label
          }),
        else:
          Repo.insert!(%ResultStream{
            assignment_id: assignment.id,
            admission_generation: assignment.desired_generation,
            result_key: output["key"],
            label: output["label"],
            target: output["target"],
            condition: output["condition"],
            check_group: output["group"],
            environment: assignment.environment,
            environment_label: assignment.environment_label
          })
    end
  end

  defp preserved_params!(%Assignment{params_owner: "ui"} = old, check) do
    fields = check["parameter_schema"]["fields"]
    previous_fields = old.parameter_schema["fields"] || %{}
    saved = old.instance_exception || %{}

    removed? = Enum.any?(Map.keys(saved), &(not Map.has_key?(fields, &1)))

    reinterpreted? =
      Enum.any?(previous_fields, fn {key, previous} ->
        Map.take(previous, ~w(type unit)) != Map.take(fields[key] || %{}, ~w(type unit))
      end)

    if removed? or reinterpreted?,
      do:
        Repo.rollback(
          {:invalid,
           "A source update cannot remove saved operator parameters or change their types or units. Keep the accepted fields compatible, or declare a new check identity."}
        )

    # Source defaults initialize only new fields. Existing operator values remain
    # authoritative, including values that now fail a changed bound/comparison.
    # The complete merged set is validated before any new configuration is saved.
    Map.merge(check["params"], saved)
  end

  defp preserved_params!(_old, check), do: check["params"]

  defp source_defaults(_, check), do: Parameters.normalized_json(check["params"])

  def definition(a),
    do:
      Map.take(
        Monitoring.public(a),
        ~w(source_revision definition_revision parameter_contract parameter_schema outputs environment environment_label configuration_origin)
      )
      |> then(fn definition ->
        if a.parameter_contract,
          do: definition,
          else: Map.delete(definition, "parameter_contract")
      end)

  def validate(p) when is_map(p) do
    bounded = Mondek.Protocol.json_text?(p) and byte_size(Jason.encode!(p)) <= 4_194_304

    valid =
      bounded and
        Mondek.Protocol.control(Map.take(p, ~w(version installation_id session_id boot))) ==
          :ok and
        Parameters.text?(p["runner_label"], 200) and Parameters.text?(p["source_id"], 200) and
        digest?(p["source_revision"]) and
        is_integer(p["inventory_revision"]) and
        p["inventory_revision"] in 1..9_223_372_036_854_775_806 and p["complete"] == true and
        (not Map.has_key?(p, "restoration_revision") or
           (is_integer(p["restoration_revision"]) and
              p["restoration_revision"] in 1..9_223_372_036_854_775_806)) and
        is_list(p["checks"]) and length(p["checks"]) <= 512 and Enum.all?(p["checks"], &check?/1) and
        unique?(p["checks"], "key") and
        Mondek.DiscoveryConfiguration.validate_inventory(p) and
        Mondek.Coverage.validate(p) == :ok

    cond do
      bounded and per_output_environment?(p) ->
        {:error,
         {:invalid,
          "Outputs cannot declare environment or environment_label. Set the scheduled check's monitored environment and use separate environment bindings for different scopes."}}

      valid ->
        :ok

      true ->
        {:error, {:invalid, "Malformed complete source inventory or parameter schema."}}
    end
  end

  def validate(_), do: {:error, {:invalid, "Supply a complete source inventory."}}

  defp per_output_environment?(inventory) do
    declared =
      case inventory["coverage"] do
        %{"candidates" => candidates} when is_list(candidates) -> candidates
        _ -> []
      end

    checks = if is_list(inventory["checks"]), do: inventory["checks"], else: []

    Enum.any?(checks ++ declared, fn
      %{"outputs" => outputs} when is_list(outputs) ->
        Enum.any?(outputs, &Mondek.Protocol.per_output_environment?/1)

      _ ->
        false
    end)
  end

  defp check?(c) when is_map(c) do
    Parameters.text?(c["key"], 200) and Parameters.text?(c["label"], 200) and
      digest?(c["definition_revision"]) and
      (is_nil(c["environment"]) or Parameters.text?(c["environment"], 128)) and
      (is_nil(c["environment_label"]) or
         (not is_nil(c["environment"]) and Parameters.text?(c["environment_label"], 200))) and
      c["params_owner"] in ["source", "ui"] and
      contract?(c["parameter_contract"], c["params_owner"], c["parameter_schema"]) and
      Parameters.validate(c["parameter_schema"], c["params"]) == :ok and
      bounded?(c["interval_seconds"], 86400) and
      bounded?(c["timeout_seconds"], 300) and bounded?(c["freshness_seconds"], 172_800) and
      is_list(c["outputs"]) and length(c["outputs"]) in 1..16 and
      Enum.all?(c["outputs"], &output?/1) and unique?(c["outputs"], "key") and
      not Map.has_key?(c, "adopt_assignment_id")
  end

  defp check?(_), do: false

  defp contract?(nil, _, _), do: true

  defp contract?(value, "ui", %{"fields" => fields}) when is_map(fields),
    do:
      map_size(fields) > 0 and is_binary(value) and
        Regex.match?(~r/\A[A-Za-z0-9_.:\/@-]{1,128}\z/, value)

  defp contract?(_, _, _), do: false

  defp output?(
         %{
           "key" => key,
           "label" => label,
           "target" => %{"key" => target, "kind" => kind, "label" => target_label}
         } = output
       ),
       do:
         Parameters.text?(key, 200) and Parameters.text?(label, 200) and
           Parameters.text?(target, 200) and Parameters.text?(kind, 64) and
           Parameters.text?(target_label, 200) and
           Mondek.Protocol.condition?(output["condition"]) and
           (not Map.has_key?(output, "group") or Mondek.Protocol.check_group?(output["group"]))

  defp output?(_), do: false
  defp condition_identity(nil), do: nil
  defp condition_identity(value), do: Map.take(value, ~w(namespace key))
  defp bounded?(value, maximum), do: is_number(value) and value >= 0.1 and value <= maximum
  defp digest?(v), do: is_binary(v) and Regex.match?(~r/^[a-f0-9]{64}$/, v)
  defp unique?(items, key), do: length(items) == length(Enum.uniq_by(items, & &1[key]))
end
