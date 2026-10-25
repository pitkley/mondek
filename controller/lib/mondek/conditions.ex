# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Conditions do
  @moduledoc "Explicit shared condition episodes, independent contributions and durable notification facts."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Monitoring,
    Maintenance,
    Assignment,
    Incident,
    Observation,
    Occurrence,
    Attempt,
    Control,
    ConditionIncident,
    ConditionFact,
    OccurrenceEvidence
  }

  @terminal ~w(delivered superseded)

  @doc "The generation-specific exact identity. A missing environment is an identity, not a wildcard."
  def identity(definition, result_key) do
    output = Enum.find(Map.get(definition, "outputs", []), &(&1["key"] == result_key))

    if output && output["condition"],
      do: Map.put(output["condition"], "environment", definition["environment"]),
      else: nil
  end

  @doc "Stable bounded lock stripes: unrelated identities may serialize, but exact condition identity never changes."
  def lock_stripes(identities) do
    identities
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&identity_key/1)
    |> Enum.map(fn key -> :crypto.hash(:sha256, key) |> :binary.at(31) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Lock all affected stripes in ascending order before changing any contribution; at most 256 locks."
  # Caller owns the transaction and any affected assignments; acquire the entire
  # batch's stripe set first. See docs/TRANSACTIONS-AND-LOCKS.md.
  def lock_keys!(identities) do
    identities
    |> lock_stripes()
    |> Enum.each(fn stripe ->
      Repo.query!("SELECT pg_advisory_xact_lock(931741, $1)", [stripe])
    end)

    :ok
  end

  def lock_ids!(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    groups = Repo.all(from g in ConditionIncident, where: g.id in ^ids)
    lock_keys!(groups)
    groups
  end

  def lock!(id) do
    group = Repo.get!(ConditionIncident, id)
    lock_keys!([group])
    Repo.one!(from g in ConditionIncident, where: g.id == ^id, lock: "FOR UPDATE")
  end

  @doc "Apply one confirmed contribution. Reduce after every output of this observation; preserve report order."
  def observe!(assignment, stream, observation, definition, state, at) do
    declaration = identity(definition, stream.result_key)

    if is_nil(declaration),
      do: raise(ArgumentError, "A grouped result requires its accepted condition declaration")

    health = state["health"]

    current =
      Repo.one(
        from i in Incident,
          where: i.stream_id == ^stream.id and i.status == "open",
          lock: "FOR UPDATE"
      )

    cond do
      health in ["WARN", "CRIT"] and is_nil(current) ->
        group = open_group!(declaration, state, at)

        Repo.insert!(%Incident{
          condition_incident_id: group.id,
          assignment_id: assignment.id,
          result_key: stream.result_key,
          stream_id: stream.id,
          environment: definition["environment"],
          environment_label: definition["environment_label"],
          health: health,
          impacts: state["impacts"] || [],
          opened_at: at,
          opening_generation: observation.generation,
          opening_observation_id: observation.id,
          latest_observation_id: observation.id
        })

        group.id

      health in ["WARN", "CRIT"] and not is_nil(current.condition_incident_id) ->
        attrs = %{
          health: health,
          impacts: state["impacts"] || [],
          latest_observation_id: observation.id
        }

        attrs =
          if current.health != health or
               impact_keys(current.impacts) != impact_keys(attrs.impacts),
             do: Map.put(attrs, :attention_revision, current.attention_revision + 1),
             else: attrs

        attrs =
          if current.acknowledgement_mode &&
               (severity(health) > severity(current.acknowledgement_ceiling) or
                  Enum.any?(
                    impact_keys(attrs.impacts),
                    &(&1 not in current.acknowledgement_impacts)
                  )),
             do:
               Map.merge(
                 attrs,
                 Monitoring.end_acknowledgement_attrs!(
                   current,
                   "Acknowledgement ended automatically: contributor severity exceeded its acknowledged limit or a new material impact appeared.",
                   at
                 )
               ),
             else: attrs

        Monitoring.change(current, attrs)
        current.condition_incident_id

      health == "OK" and not is_nil(current) and not is_nil(current.condition_incident_id) ->
        reason =
          if Monitoring.same_recovery_contract?(
               assignment.id,
               current.opening_generation,
               observation.generation
             ), do: "measured_recovery", else: "configuration_changed"

        close_contribution!(current, reason, observation.id, at)
        current.condition_incident_id

      is_nil(current) ->
        nil

      true ->
        current.condition_incident_id
    end
  end

  @doc "Close grouped contributions for retired streams; returns IDs to reduce after the complete mutation batch."
  def retire_contributions!(stream_ids, reason, at) do
    Repo.all(
      from i in Incident,
        where:
          i.stream_id in ^stream_ids and i.status == "open" and
            not is_nil(i.condition_incident_id),
        order_by: [asc: i.id],
        lock: "FOR UPDATE"
    )
    |> Enum.map(fn incident ->
      close_contribution!(incident, reason, nil, at)
      incident.condition_incident_id
    end)
    |> Enum.uniq()
  end

  @doc "Reduce all outputs of one observation, or a complete inventory retirement; holds do not create facts."
  def reduce!(ids, at, observation \\ nil)

  def reduce!(ids, at, observation) when is_list(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&reduce_one!(&1, at, observation))
  end

  def reduce!(id, at, observation), do: reduce!([id], at, observation) |> List.first()

  defp reduce_one!(id, at, observation) do
    group = Repo.one!(from g in ConditionIncident, where: g.id == ^id, lock: "FOR UPDATE")

    members =
      Repo.all(
        from i in Incident,
          where: i.condition_incident_id == ^id and i.status == "open",
          order_by: [asc: i.opened_at, asc: i.id]
      )

    if group.status == "closed" do
      group
    else
      if members == [] do
        close_group!(group, at, observation)
      else
        health = members |> Enum.max_by(&severity(&1.health)) |> Map.fetch!(:health)

        impacts =
          members
          |> Enum.flat_map(& &1.impacts)
          |> Enum.uniq_by(& &1["key"])
          |> Enum.sort_by(& &1["key"])

        fingerprint =
          members
          |> Enum.map(&{&1.id, &1.health, impact_keys(&1.impacts)})
          |> Enum.sort()
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        changed? = group.support_fingerprint != fingerprint
        attention? = health != group.health or impact_keys(impacts) != impact_keys(group.impacts)

        invalid_ack? =
          group.acknowledgement_mode &&
            (severity(health) > severity(group.acknowledgement_ceiling) or
               Enum.any?(impact_keys(impacts), &(&1 not in group.acknowledgement_impacts)))

        attrs = %{
          health: health,
          impacts: impacts,
          support_fingerprint: fingerprint,
          attention_revision: group.attention_revision + if(attention?, do: 1, else: 0)
        }

        attrs =
          if invalid_ack?,
            do:
              Map.merge(
                attrs,
                end_ack!(
                  group,
                  "Acknowledgement ended automatically: severity exceeded its reviewed limit or a new material impact appeared. Maintenance does not extend acknowledgement coverage.",
                  at
                )
              ),
            else: attrs

        group = Monitoring.change(group, attrs)

        if changed? do
          reconcile_facts!(group, members, at)
          request_gate_wake!(group.id)
        end

        group
      end
    end
  end

  defp open_group!(declaration, state, at) do
    namespace = declaration["namespace"]
    key = declaration["key"]
    environment = declaration["environment"]

    Repo.one(
      from g in ConditionIncident,
        where:
          g.namespace == ^namespace and g.key == ^key and g.status == "open" and
            fragment("? IS NOT DISTINCT FROM ?", g.environment, type(^environment, :string)),
        lock: "FOR UPDATE"
    ) ||
      Repo.insert!(%ConditionIncident{
        namespace: namespace,
        key: key,
        environment: environment,
        label: declaration["label"],
        opened_at: at,
        health: state["health"],
        impacts: state["impacts"] || []
      })
  end

  defp close_contribution!(incident, reason, observation_id, at) do
    attrs =
      Monitoring.end_acknowledgement_attrs!(
        incident,
        "Acknowledgement ended with the contribution (#{reason}).",
        at
      )

    Monitoring.change(
      incident,
      Map.merge(attrs, %{
        status: "closed",
        closed_at: at,
        closure_reason: reason,
        closing_observation_id: observation_id,
        latest_observation_id: observation_id || incident.latest_observation_id,
        attention_revision: incident.attention_revision + 1
      })
    )
  end

  defp close_group!(group, at, observation) do
    closed =
      Repo.all(
        from i in Incident,
          where: i.condition_incident_id == ^group.id,
          order_by: [desc: i.closed_at, desc: i.id]
      )

    reasons =
      closed
      |> Enum.map(& &1.closure_reason)
      |> Enum.reject(&(&1 == "measured_recovery" or is_nil(&1)))
      |> Enum.uniq()
      |> Enum.sort()

    reason =
      case reasons do
        [] -> "measured_recovery"
        [only] -> only
        _ -> "mixed_resolution"
      end

    # Every report in one transport batch may have the same receipt time. Only
    # the exact observation triggering this reduction establishes closing evidence.
    closing_member =
      observation && Enum.find(closed, &(&1.closing_observation_id == observation.id))

    observation_id = closing_member && observation.id

    group =
      Monitoring.change(
        group,
        Map.merge(
          end_ack!(group, "Acknowledgement ended with the shared incident (#{reason}).", at),
          %{
            status: "closed",
            closed_at: at,
            closure_reason: reason,
            closure_reasons: reasons,
            closing_observation_id: observation_id,
            attention_revision: group.attention_revision + 1
          }
        )
      )

    Repo.all(
      from f in ConditionFact, where: f.condition_incident_id == ^group.id and is_nil(f.ended_at)
    )
    |> Enum.each(&end_fact!(&1, "condition_ended", at))

    attempted? =
      Repo.exists?(
        from t in Attempt,
          join: o in Occurrence,
          on: o.id == t.occurrence_id,
          where: o.condition_incident_id == ^group.id and o.kind != "resolved"
      )

    if attempted?, do: create_occurrence!(group, nil, closing_member, nil, at)
    request_gate_wake!(group.id)
    group
  end

  defp reconcile_facts!(group, members, at) do
    severity_facts =
      [{"severity", "WARN", "Warning severity"}] ++
        if(Enum.any?(members, &(&1.health == "CRIT")),
          do: [{"severity", "CRIT", "Critical severity"}],
          else: []
        )

    desired = severity_facts ++ Enum.map(group.impacts, &{"impact", &1["key"], &1["label"]})

    active =
      Repo.all(
        from f in ConditionFact,
          where: f.condition_incident_id == ^group.id and is_nil(f.ended_at)
      )

    keys = MapSet.new(desired, fn {kind, key, _} -> {kind, key} end)

    Enum.each(active, fn fact ->
      unless MapSet.member?(keys, {fact.kind, fact.key}),
        do: end_fact!(fact, "evidence_ended", at)
    end)

    active_by_key = Map.new(active, &{{&1.kind, &1.key}, &1})

    facts =
      Enum.map(desired, fn {kind, key, label} ->
        active_by_key[{kind, key}] ||
          create_fact!(group, kind, key, label, Enum.find(members, &supports?(&1, kind, key)), at)
      end)

    warn = Enum.find(facts, &(&1.kind == "severity" and &1.key == "WARN"))

    requested =
      Repo.all(
        from o in Occurrence,
          join: f in ConditionFact,
          on: f.id == o.condition_fact_id,
          where: f.condition_incident_id == ^group.id and is_nil(f.ended_at),
          select: o.condition_fact_id
      )
      |> MapSet.new()

    Enum.each(facts, fn fact ->
      # CRIT creates the WARN lifetime but only actual WARN evidence requests its own lower alert.
      member =
        if fact.kind == "severity" and fact.key == "WARN",
          do: Enum.find(members, &(&1.health == "WARN")),
          else: Enum.find(members, &supports?(&1, fact.kind, fact.key))

      if member && is_nil(fact.covered_by_occurrence_id) && not MapSet.member?(requested, fact.id) do
        covers = if fact.kind == "severity" and fact.key == "CRIT", do: warn.id, else: nil
        create_occurrence!(group, fact, member, covers, at)
      end
    end)
  end

  defp create_fact!(group, kind, key, label, member, at) do
    Repo.insert!(%ConditionFact{
      condition_incident_id: group.id,
      kind: kind,
      key: key,
      label: label,
      opened_at: at,
      opening_observation_id: member.latest_observation_id,
      opening_incident_id: member.id
    })
  end

  defp end_fact!(fact, reason, at) do
    Monitoring.change(fact, %{ended_at: at, end_reason: reason})

    Repo.update_all(
      from(o in Occurrence,
        where: o.condition_fact_id == ^fact.id and o.status not in ^@terminal
      ),
      set: [status: "superseded"]
    )
  end

  defp create_occurrence!(group, fact, member, covers, at) do
    id = Ecto.UUID.generate()
    observation_id = if fact, do: member.latest_observation_id, else: group.closing_observation_id
    observation = if observation_id, do: Repo.get!(Observation, observation_id)

    requested =
      if fact,
        do: %{"id" => fact.id, "kind" => fact.kind, "key" => fact.key, "label" => fact.label}

    result =
      if observation && member,
        do: Enum.find(observation.payload["results"] || [], &(&1["key"] == member.result_key))

    payload = %{
      "version" => 2,
      "occurrence_id" => id,
      "condition_incident_id" => group.id,
      "kind" => if(fact, do: "firing", else: "resolved"),
      "requested_fact" => requested,
      "condition" => %{"namespace" => group.namespace, "key" => group.key, "label" => group.label},
      "environment" => group.environment,
      "group_health_at_creation" => group.health,
      "attention_revision" => group.attention_revision,
      "created_at" => Monitoring.iso(at),
      "closure_reason" => group.closure_reason,
      "closure_reasons" => group.closure_reasons,
      "observation_id" => observation_id,
      "contribution_id" => member && member.id,
      "generation" => observation && observation.generation,
      "result_key" => member && member.result_key,
      "source_at" => result && result["source_at"],
      "covered_warn_fact_id" => covers
    }

    {payload, destination} =
      Mondek.NotificationDelivery.snapshot(
        payload,
        group.label,
        result && result["summary"],
        result && result["health"]
      )

    occurrence =
      Repo.insert!(%Occurrence{
        id: id,
        condition_incident_id: group.id,
        condition_fact_id: fact && fact.id,
        covered_warn_fact_id: covers,
        kind: payload["kind"],
        attention_revision: group.attention_revision,
        payload: payload,
        destination: destination,
        inserted_at: at
      })

    if observation do
      Repo.insert!(%OccurrenceEvidence{
        occurrence_id: id,
        observation_id: observation.id,
        incident_id: member.id,
        result_key: member.result_key,
        generation: observation.generation,
        role: if(fact, do: "fact", else: "closure")
      })
    end

    %{
      "occurrence_id" => id,
      "delivery_channel" =>
        if(String.starts_with?(destination, "mailto:"), do: "smtp", else: "webhook")
    }
    |> Mondek.NotificationWorker.new(
      max_attempts: Application.get_env(:mondek, :notification_max_attempts, 100)
    )
    |> Oban.insert!()

    occurrence
  end

  @doc "Eligibility proves only the immutable requested fact, using any currently uncovered supporting contribution."
  def delivery_eligibility(occurrence, group, at, context \\ nil) do
    cond do
      occurrence.status == "delivered" ->
        :delivered

      occurrence.status == "superseded" ->
        :superseded

      occurrence.kind == "resolved" ->
        :eligible

      group.status != "open" ->
        :superseded

      true ->
        fact = Repo.get!(ConditionFact, occurrence.condition_fact_id)

        cond do
          fact.ended_at || fact.covered_by_occurrence_id ->
            :superseded

          true ->
            context = context || delivery_context(group.id, at)
            base = fact_eligibility(fact, group, context, at)

            if base == :eligible and fact.kind == "severity" and fact.key == "WARN",
              do: defer_to_critical(group, context, at),
              else: base
        end
    end
  end

  def active_members(id) do
    Repo.all(
      from i in Incident,
        join: a in Assignment,
        on: a.id == i.assignment_id,
        where: i.condition_incident_id == ^id and i.status == "open",
        select: {i, struct(a, [:id, :source_id, :retired_at])}
    )
  end

  @doc false
  def delivery_context(id, at) do
    members = active_members(id)
    %{members: members, maintenance: Maintenance.active_for_many(members, at)}
  end

  @doc false
  def supporting_maintenance(occurrence, context) do
    case occurrence.payload["requested_fact"] do
      %{"kind" => kind, "key" => key} ->
        context.members
        |> Enum.filter(fn {incident, _} -> supports?(incident, kind, key) end)
        |> Enum.flat_map(fn {incident, _} -> Map.get(context.maintenance, incident.id, []) end)
        |> Enum.uniq_by(& &1.id)

      _ ->
        []
    end
  end

  defp fact_eligibility(fact, group, context, at) do
    if Monitoring.acknowledgement_active?(group, at) do
      {:gated, ["acknowledgement"], group.acknowledged_until}
    else
      supporting =
        Enum.filter(context.members, fn {i, a} ->
          is_nil(a.retired_at) && supports?(i, fact.kind, fact.key)
        end)

      coverage =
        Enum.map(supporting, fn {i, _a} ->
          windows = Map.get(context.maintenance, i.id, [])
          ack? = Monitoring.acknowledgement_active?(i, at)

          gates =
            if(ack?, do: ["individual_acknowledgement"], else: []) ++
              if(windows != [], do: ["maintenance"], else: [])

          until =
            cond do
              ack? and is_nil(i.acknowledged_until) ->
                nil

              true ->
                ([if(ack?, do: i.acknowledged_until)] ++ Enum.map(windows, & &1.ends_at))
                |> Enum.reject(&is_nil/1)
                |> Enum.max(DateTime, fn -> nil end)
            end

          {gates, until}
        end)

      cond do
        supporting == [] ->
          :superseded

        Enum.any?(coverage, fn {gates, _} -> gates == [] end) ->
          :eligible

        true ->
          dates = coverage |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

          {:gated, coverage |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq(),
           Enum.min(dates, DateTime, fn -> nil end)}
      end
    end
  end

  defp defer_to_critical(group, context, at) do
    higher =
      Repo.one(
        from o in Occurrence,
          join: f in ConditionFact,
          on: f.id == o.condition_fact_id,
          where:
            o.condition_incident_id == ^group.id and f.kind == "severity" and f.key == "CRIT" and
              is_nil(f.ended_at) and is_nil(f.covered_by_occurrence_id) and
              o.status in ["pending", "retrying", "delivering"],
          select: {o, f}
      )

    case higher do
      {occurrence, fact} ->
        budget? =
          Repo.exists?(
            from j in Oban.Job,
              where:
                j.worker == "Mondek.NotificationWorker" and
                  fragment("?->>'occurrence_id' = ?", j.args, ^occurrence.id) and
                  j.state in ["available", "scheduled", "retryable", "executing"] and
                  (j.attempt < j.max_attempts or j.state == "executing")
          )

        if budget? and fact_eligibility(fact, group, context, at) == :eligible,
          do: {:gated, ["higher_severity_delivery"], DateTime.add(at, 30)},
          else: :eligible

      nil ->
        :eligible
    end
  end

  @doc "Record accepted higher-severity coverage, including a late accepted attempt after supersession."
  def delivery_accepted!(occurrence, at) do
    if occurrence.covered_warn_fact_id do
      fact = Repo.get!(ConditionFact, occurrence.covered_warn_fact_id)

      if is_nil(fact.covered_by_occurrence_id) do
        Monitoring.change(fact, %{covered_by_occurrence_id: occurrence.id, covered_at: at})

        Repo.update_all(
          from(o in Occurrence,
            where: o.condition_fact_id == ^fact.id and o.status not in ^@terminal
          ),
          set: [status: "superseded"]
        )
      end
    end

    request_gate_wake!(occurrence.condition_incident_id)
    :ok
  end

  def request_gate_wake!(id) do
    Repo.update_all(from(o in Occurrence, where: o.condition_incident_id == ^id),
      inc: [gate_revision: 1]
    )

    :ok
  end

  def acknowledge(id, options, note, at \\ Monitoring.now()) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         :ok <- Monitoring.validate_acknowledgement_note(note),
         {:ok, mode, until, revisions} <- Monitoring.acknowledgement_options(options, at) do
      result =
        Repo.transaction(fn ->
          existing = Repo.get(ConditionIncident, id) || Repo.rollback(:not_found)
          lock_keys!([existing])

          group =
            Repo.one(from g in ConditionIncident, where: g.id == ^id, lock: "FOR UPDATE") ||
              Repo.rollback(:not_found)

          if revisions &&
               (revisions["revision"] != group.acknowledgement_revision or
                  revisions["attention_revision"] != group.attention_revision),
             do: Repo.rollback(:stale)

          if group.status != "open",
            do: Repo.rollback({:invalid, "Only an open incident can be acknowledged."})

          ended? = mode == "end"
          revision = group.acknowledgement_revision + 1

          if revision > 9_223_372_036_854_775_806,
            do: Repo.rollback({:invalid, "Acknowledgement revision range exhausted."})

          Repo.insert!(%Control{
            condition_incident_id: id,
            kind: if(ended?, do: "acknowledgement_ended", else: "acknowledgement"),
            acknowledgement_mode: if(ended?, do: "ended", else: mode),
            acknowledgement_revision: revision,
            acknowledgement_ceiling:
              if(ended?, do: group.acknowledgement_ceiling, else: group.health),
            acknowledgement_impacts:
              if(ended?, do: group.acknowledgement_impacts, else: impact_keys(group.impacts)),
            actor: "Local operator",
            reason: note,
            until: if(ended?, do: at, else: until),
            inserted_at: at
          })

          updated =
            Monitoring.change(group, %{
              acknowledgement_mode: if(ended?, do: nil, else: mode),
              acknowledgement_revision: revision,
              acknowledged_until: if(ended?, do: nil, else: until),
              acknowledged_by: "Local operator",
              acknowledgement_note: note,
              acknowledgement_ceiling: if(ended?, do: nil, else: group.health),
              acknowledgement_impacts: if(ended?, do: [], else: impact_keys(group.impacts))
            })

          request_gate_wake!(id)
          Monitoring.public(updated)
        end)

      Monitoring.notify()
      result
    else
      :error -> {:error, {:invalid, "Malformed shared incident ID."}}
      error -> error
    end
  end

  defp end_ack!(group, reason, at) do
    revision = group.acknowledgement_revision + 1

    if Monitoring.acknowledgement_active?(group, at) do
      Repo.insert!(%Control{
        condition_incident_id: group.id,
        kind: "acknowledgement_ended",
        acknowledgement_mode: "ended",
        acknowledgement_revision: revision,
        acknowledgement_ceiling: group.acknowledgement_ceiling,
        acknowledgement_impacts: group.acknowledgement_impacts,
        actor: "Mondek",
        reason: reason,
        until: at,
        inserted_at: at
      })
    end

    %{
      acknowledgement_mode: nil,
      acknowledged_until: nil,
      acknowledgement_ceiling: nil,
      acknowledgement_impacts: [],
      acknowledgement_revision: revision
    }
  end

  defp supports?(incident, "severity", key), do: severity(incident.health) >= severity(key)
  defp supports?(incident, "impact", key), do: Enum.any?(incident.impacts, &(&1["key"] == key))
  defp impact_keys(impacts), do: impacts |> Enum.map(& &1["key"]) |> Enum.uniq() |> Enum.sort()
  defp severity("CRIT"), do: 2
  defp severity("WARN"), do: 1
  defp severity(_), do: 0

  defp identity_key(%ConditionIncident{} = group),
    do: Jason.encode!([group.namespace, group.key, group.environment])

  defp identity_key(identity),
    do: Jason.encode!([identity["namespace"], identity["key"], identity["environment"]])
end
