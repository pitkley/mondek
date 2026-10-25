# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.PublisherLifecycle do
  @moduledoc "Reviewed lifecycle of one installation's source publication, with durable replay fences."
  import Ecto.Query
  import Kernel, except: [apply: 2, apply: 3]

  alias Mondek.{
    Repo,
    Monitoring,
    Parameters,
    SourceInventory,
    PublisherLifecycleEvent,
    PublisherLifecycleEvidence,
    Runner,
    Assignment,
    ResultStream,
    CoverageDeclaration,
    Configuration,
    Observation,
    Incident,
    ConditionIncident,
    Occurrence,
    Conditions,
    ConfigurationRules
  }

  @limit 25
  @max_age 900

  def get(id, page \\ 1, at \\ Monitoring.now()) do
    Repo.transaction(fn ->
      source = find!(id)
      state = state!(source, nil, false)

      %{
        "publisher" => publisher(source),
        "summary" => summary(state),
        "history" => history(source.id, page),
        "at" => Monitoring.iso(at)
      }
    end)
  end

  def successors(id, filters \\ %{}, _at \\ Monitoring.now()) do
    Repo.transaction(fn ->
      source = find!(id)
      filters = if is_map(filters), do: filters, else: %{}
      search = filters["search"]

      search =
        if is_binary(search) and byte_size(search) <= 200 and String.valid?(search) and
             not String.contains?(search, <<0>>), do: String.downcase(search), else: ""

      query =
        from p in SourceInventory,
          join: r in Runner,
          on: r.id == p.runner_id,
          where:
            p.source_id == ^source.source_id and p.runner_id != ^source.runner_id and
              is_nil(p.retired_at) and is_nil(p.resume_after_revision) and
              fragment(
                "position(? in lower(concat_ws(' ',?,?->>'id'))) > 0",
                ^search,
                r.label,
                p.coverage_context
              ),
          order_by: [asc: r.label, asc: p.id],
          select: p

      total = Repo.aggregate(query, :count)
      page = page(filters["page"], total)
      rows = Repo.all(from p in query, limit: @limit, offset: ^((page - 1) * @limit))
      paged(Enum.map(rows, &publisher/1), page, total)
    end)
  end

  def preview(proposal, page \\ 1, at \\ nil, review_token \\ nil) do
    Repo.transaction(fn ->
      p = proposal!(proposal)
      {source, successor} = lock_publishers!(p)
      state = state!(source, successor, true)
      at = at || Monitoring.now()
      review = review(p, state)
      if review_token, do: verify_review!(review_token, review)
      rows = impact_rows(state, at)
      blockers = blockers(p, state, rows)
      summary = impact_summary(state, rows, p["action"])
      page = page(page, length(rows))

      paged(Enum.slice(rows, (page - 1) * @limit, @limit), page, length(rows))
      |> Map.merge(%{
        "proposal" => p,
        "publisher" => publisher(source),
        "successor" => if(successor, do: publisher(successor)),
        "summary" => summary,
        "blockers" => blockers,
        "can_apply" => blockers == [],
        "review_token" =>
          review_token || Phoenix.Token.sign(MondekWeb.Endpoint, "publisher-lifecycle", review)
      })
    end)
  end

  def apply(token, proposal, at \\ nil) do
    result =
      Repo.transaction(fn ->
        p = proposal!(proposal)

        unless is_binary(token) and byte_size(token) in 1..10000,
          do: Repo.rollback(:invalid_review)

        {source, successor} = lock_publishers!(p)
        digest = fingerprint(token)

        case Repo.get_by(PublisherLifecycleEvent, review_digest: digest) do
          nil ->
            state = state!(source, successor, true)
            at = at || Monitoring.now()
            verify_review!(token, review(p, state))
            rows = impact_rows(state, at)

            case blockers(p, state, rows) do
              [] -> :ok
              messages -> Repo.rollback({:invalid, Enum.join(messages, " ")})
            end

            before = publisher(source)
            summary = impact_summary(state, rows, p["action"])

            changed =
              if p["action"] == "restore" do
                Monitoring.change(source, %{
                  lifecycle_revision: source.lifecycle_revision + 1,
                  retired_at: nil,
                  retirement_reason: nil,
                  replacement_id: nil,
                  resume_after_revision: source.revision
                })
              else
                for assignment <- state.assignments,
                    do:
                      Monitoring.retire_publisher_assignment!(
                        assignment,
                        p["reason"],
                        at,
                        p["action"]
                      )

                Conditions.reduce!(Enum.map(state.groups, & &1.id), at)

                Monitoring.change(source, %{
                  lifecycle_revision: source.lifecycle_revision + 1,
                  retired_at: at,
                  retirement_reason: p["reason"],
                  replacement_id: successor && successor.id,
                  resume_after_revision: nil
                })
              end

            snapshot = %{
              "before" => before,
              "after" => publisher(changed),
              "summary" => summary,
              "successor" => if(successor, do: publisher(successor)),
              "affected_assignment_ids" => Enum.map(state.assignments, & &1.id),
              "impact_items" => rows,
              "replacement_evidence" =>
                if(successor,
                  do:
                    Enum.map(
                      rows,
                      &Map.take(
                        &1,
                        ~w(scope_id assignment_id stream_id successor_assignment_id successor_stream_id successor_observation_id successor_generation successor_health)
                      )
                    ),
                  else: []
                )
            }

            event =
              Repo.insert!(%PublisherLifecycleEvent{
                publisher_id: source.id,
                lifecycle_revision: changed.lifecycle_revision,
                action: p["action"],
                reason: p["reason"],
                actor: "Local operator",
                successor_id: successor && successor.id,
                review_digest: digest,
                proposal: p,
                snapshot: snapshot,
                inserted_at: at
              })

            # Only the exact qualifying successor measurements survive ordinary
            # receipt retention. At most 8192 result witnesses per decision share
            # deduplicated observations; removing its history releases the refs.
            evidence =
              rows
              |> Enum.filter(&(&1["selected"] and &1["replacement_status"] == "ready"))
              |> Enum.map(& &1["successor_observation_id"])
              |> Enum.uniq()
              |> Enum.map(&%{event_id: event.id, observation_id: &1})

            Repo.insert_all(PublisherLifecycleEvidence, evidence)
            Mondek.MonitoringLoss.lock!()
            applied(changed, event, at)

          event ->
            if event.proposal != p, do: Repo.rollback(:review_changed)
            applied(source, event, at || Monitoring.now())
        end
      end)

    Monitoring.notify()

    if match?({:ok, _}, result),
      do: Monitoring.notify_control(get_in(elem(result, 1), ["publisher", "runner_id"]))

    result
  end

  defp applied(source, event, at) do
    %{
      "publisher" => publisher(source),
      "summary" => event.snapshot["summary"],
      "receipt" => event_public(event),
      "history" => history(source.id, 1),
      "at" => Monitoring.iso(at)
    }
  end

  def event(id, event_id, page \\ 1) do
    Repo.transaction(fn ->
      source = find!(id)
      event_id = positive_id(event_id) || Repo.rollback(:not_found)

      event =
        Repo.one(
          from e in PublisherLifecycleEvent,
            where: e.publisher_id == ^source.id and e.id == ^event_id,
            select: %PublisherLifecycleEvent{
              id: e.id,
              publisher_id: e.publisher_id,
              lifecycle_revision: e.lifecycle_revision,
              action: e.action,
              reason: e.reason,
              actor: e.actor,
              successor_id: e.successor_id,
              inserted_at: e.inserted_at,
              snapshot:
                fragment(
                  "? - 'affected_assignment_ids' - 'replacement_evidence' - 'impact_items'",
                  e.snapshot
                )
            }
        ) ||
          Repo.rollback(:not_found)

      %{rows: [[total]]} =
        Repo.query!(
          "SELECT jsonb_array_length(snapshot->'impact_items') FROM publisher_lifecycle_events WHERE id=$1",
          [event_id]
        )

      page = page(page, total)

      %{rows: rows} =
        Repo.query!(
          "SELECT item FROM publisher_lifecycle_events e, jsonb_array_elements(e.snapshot->'impact_items') WITH ORDINALITY AS entries(item,n) WHERE e.id=$1 ORDER BY n LIMIT 25 OFFSET $2",
          [event_id, (page - 1) * @limit]
        )

      event_public(event) |> Map.merge(paged(Enum.map(rows, &hd/1), page, total))
    end)
  end

  @doc "Read one original report explicitly retained by a saved replacement decision."
  def evidence(id, event_id, observation_id) do
    Repo.transaction(fn ->
      source = find!(id)
      event_id = positive_id(event_id) || Repo.rollback(:not_found)

      observation_id =
        case Ecto.UUID.cast(observation_id) do
          {:ok, uuid} -> uuid
          :error -> Repo.rollback(:not_found)
        end

      observation =
        Repo.one(
          from o in Observation,
            join: ref in PublisherLifecycleEvidence,
            on: ref.observation_id == o.id,
            join: e in PublisherLifecycleEvent,
            on: e.id == ref.event_id,
            where: e.publisher_id == ^source.id and e.id == ^event_id and o.id == ^observation_id,
            select: o
        ) || Repo.rollback(:not_found)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT item FROM publisher_lifecycle_events e,
            jsonb_array_elements(e.snapshot->'impact_items') AS item
          WHERE e.id=$1 AND item->>'successor_observation_id'=$2
            AND item->>'replacement_status'='ready' AND item->>'selected'='true'
          ORDER BY item->>'result_key',item->>'scope_id'
          """,
          [event_id, observation_id]
        )

      witnesses = Enum.map(rows, &hd/1)

      configuration =
        Repo.get_by(Configuration,
          assignment_id: observation.assignment_id,
          generation: observation.generation
        )

      %{
        "publisher_id" => source.id,
        "event_id" => event_id,
        "observation" => Monitoring.public(observation),
        "configuration" => if(configuration, do: Monitoring.public(configuration)),
        "referenced_result_keys" =>
          witnesses |> Enum.map(& &1["result_key"]) |> Enum.uniq() |> Enum.sort(),
        "witnesses" => witnesses
      }
    end)
  end

  # Source locks precede every runner, assignment and condition lock. Source IDs
  # are immutable publication identities; reading them before locking is safe.
  defp lock_publishers!(p) do
    original = find!(p["publisher_id"])
    successor = if p["action"] == "replace", do: find!(p["successor_id"])
    sources = Enum.reject([original, successor], &is_nil/1)

    sources
    |> Enum.map(& &1.source_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&ConfigurationRules.lock_source!/1)

    runner_ids = sources |> Enum.map(& &1.runner_id) |> Enum.uniq()

    Repo.all(
      from r in Runner, where: r.id in ^runner_ids, order_by: r.id, lock: "FOR NO KEY UPDATE"
    )

    ids = Enum.map(sources, & &1.id)

    locked =
      Repo.all(from s in SourceInventory, where: s.id in ^ids, order_by: s.id, lock: "FOR UPDATE")
      |> Map.new(&{&1.id, &1})

    {locked[original.id], if(successor, do: locked[successor.id])}
  end

  defp state!(source, successor, lock?) do
    publications = Enum.reject([source, successor], &is_nil/1)

    clauses =
      Enum.reduce(publications, dynamic(false), fn p, acc ->
        dynamic([a], ^acc or (a.runner_id == ^p.runner_id and a.source_id == ^p.source_id))
      end)

    query = from a in Assignment, where: ^clauses, where: is_nil(a.retired_at), order_by: a.id
    assignments = Repo.all(if(lock?, do: from(a in query, lock: "FOR UPDATE"), else: query))
    ids = Enum.map(assignments, & &1.id)
    if lock?, do: Monitoring.lock_condition_streams!(ids)

    streams =
      Repo.all(
        from s in ResultStream,
          where: s.assignment_id in ^ids and is_nil(s.retired_at),
          order_by: s.id,
          select: %{
            id: s.id,
            assignment_id: s.assignment_id,
            result_key: s.result_key,
            environment: s.environment,
            target: s.target,
            condition: s.condition,
            current:
              fragment(
                "jsonb_build_object('generation',?->'generation','confirmed_generation',?->'confirmed_generation','session_id',?->'session_id','source_at',?->'source_at','knowledge',?->'knowledge','health',?->'health','observation_id',?->'observation_id','confirmed_observation_id',?->'confirmed_observation_id')",
                s.current,
                s.current,
                s.current,
                s.current,
                s.current,
                s.current,
                s.current,
                s.current
              )
          }
      )

    publication_ids = Enum.map(publications, & &1.id)

    declarations =
      Repo.all(
        from d in CoverageDeclaration,
          where: d.source_inventory_id in ^publication_ids,
          order_by: [d.source_key, d.result_key, d.id]
      )

    incidents =
      Repo.all(
        from i in Incident,
          where: i.assignment_id in ^ids and i.status == "open",
          order_by: i.id,
          select: %{
            id: i.id,
            assignment_id: i.assignment_id,
            stream_id: i.stream_id,
            condition_incident_id: i.condition_incident_id,
            attention_revision: i.attention_revision,
            acknowledgement_revision: i.acknowledgement_revision
          }
      )

    group_ids =
      incidents |> Enum.map(& &1.condition_incident_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    groups =
      Repo.all(
        from g in ConditionIncident,
          where: g.id in ^group_ids,
          order_by: g.id,
          select: %{
            id: g.id,
            attention_revision: g.attention_revision,
            acknowledgement_revision: g.acknowledgement_revision,
            support_fingerprint: g.support_fingerprint
          }
      )

    configs =
      Repo.all(
        from c in Configuration,
          join: a in Assignment,
          on: c.assignment_id == a.id and c.generation == a.desired_generation,
          where: a.id in ^ids,
          select: {a.id, c}
      )
      |> Map.new()

    own =
      Enum.filter(
        assignments,
        &(&1.runner_id == source.runner_id and &1.source_id == source.source_id)
      )

    own_ids = MapSet.new(Enum.map(own, & &1.id))

    runners =
      Repo.all(from r in Runner, where: r.id in ^Enum.map(publications, & &1.runner_id))
      |> Map.new(&{&1.id, &1})

    %{
      source: source,
      successor: successor,
      assignments: own,
      all_assignments: assignments,
      declarations: Enum.filter(declarations, &(&1.source_inventory_id == source.id)),
      successor_declarations:
        Enum.filter(declarations, &(successor && &1.source_inventory_id == successor.id)),
      streams: Enum.filter(streams, &MapSet.member?(own_ids, &1.assignment_id)),
      all_streams: streams,
      incidents: Enum.filter(incidents, &MapSet.member?(own_ids, &1.assignment_id)),
      all_incidents: incidents,
      groups: groups,
      configs: configs,
      runners: runners
    }
  end

  defp review(p, state) do
    # New samples and delivery attempts do not invalidate a reviewed structural
    # change. Open episode/attention/acknowledgement identities do.
    %{
      "proposal" => fingerprint(p),
      "state" =>
        fingerprint(%{
          sources:
            Enum.map(
              Enum.reject([state.source, state.successor], &is_nil/1),
              &Map.take(
                &1,
                [
                  :id,
                  :revision,
                  :source_revision,
                  :lifecycle_revision,
                  :retired_at,
                  :resume_after_revision,
                  :coverage_revision,
                  :coverage_confirmed
                ]
              )
            ),
          assignments:
            Enum.map(state.all_assignments, &Map.take(&1, [:id, :revision, :desired_generation])),
          incidents: state.incidents,
          groups:
            state.groups
            |> Enum.filter(fn g ->
              Enum.any?(state.incidents, &(&1.condition_incident_id == g.id))
            end)
            |> Enum.map(&Map.drop(&1, [:support_fingerprint])),
          other_publications: publication_revision_digest(state.source.source_id)
        })
    }
  end

  defp publication_revision_digest(source_id) do
    %{rows: [[digest]]} =
      Repo.query!(
        "SELECT md5(coalesce(string_agg(concat_ws(':',id,revision,lifecycle_revision,coverage_revision,coverage_confirmed),',' ORDER BY id),'')) FROM source_inventories WHERE source_id=$1",
        [source_id]
      )

    digest
  end

  defp impact_rows(state, at) do
    assignments = Map.new(state.all_assignments, &{&1.id, &1})
    streams = Map.new(state.all_streams, &{{&1.assignment_id, &1.result_key}, &1})

    successors =
      Map.new(state.successor_declarations |> Enum.filter(& &1.scope_id), &{&1.scope_id, &1})

    scope_ids = state.declarations |> Enum.map(& &1.scope_id) |> Enum.reject(&is_nil/1)

    remaining =
      Repo.all(
        from d in CoverageDeclaration,
          join: p in SourceInventory,
          on: p.id == d.source_inventory_id,
          where:
            d.scope_id in ^scope_ids and p.id != ^state.source.id and is_nil(p.retired_at) and
              is_nil(p.resume_after_revision),
          group_by: d.scope_id,
          select:
            {d.scope_id, count(d.id), filter(count(d.id), d.selected and p.coverage_confirmed)}
      )
      |> Map.new(fn {id, declaring, selected} -> {id, {declaring, selected}} end)

    declared = MapSet.new(state.declarations, &{&1.assignment_id, &1.result_key})

    unknown =
      state.streams
      |> Enum.reject(&MapSet.member?(declared, {&1.assignment_id, &1.result_key}))
      |> Enum.map(fn s ->
        a = assignments[s.assignment_id]

        %CoverageDeclaration{
          source_id: a.source_id,
          source_key: a.source_key,
          result_key: s.result_key,
          check_label: a.label,
          result_label: s.result_key,
          environment: s.environment,
          target_kind: s.target["kind"],
          target_key: s.target["key"],
          target_label: s.target["label"],
          selected: true,
          scope_resolved: false,
          assignment_id: a.id
        }
      end)

    Enum.map(state.declarations ++ unknown, fn d ->
      other = if d.scope_id, do: successors[d.scope_id]
      a = assignments[d.assignment_id]
      s = streams[{d.assignment_id, d.result_key}]
      b = other && assignments[other.assignment_id]
      t = other && streams[{other.assignment_id, other.result_key}]
      {status, reason} = replacement_status(d, other, a, s, b, t, state, at)
      {declaring, selected} = remaining[d.scope_id] || {0, 0}

      %{
        "scope_id" => d.scope_id,
        "source_key" => d.source_key,
        "result_key" => d.result_key,
        "check_label" => d.check_label,
        "result_label" => d.result_label,
        "environment" => d.environment,
        "target" =>
          if(d.target_key,
            do: %{"kind" => d.target_kind, "key" => d.target_key, "label" => d.target_label}
          ),
        "assignment_id" => d.assignment_id,
        "stream_id" => s && s.id,
        "selected" => d.selected,
        "catalogue_unknown" => is_nil(d.id),
        "remaining_publishers" => declaring,
        "remaining_selected" => selected,
        "successor_assignment_id" => b && b.id,
        "successor_stream_id" => t && t.id,
        "successor_health" => t && t.current["health"],
        "successor_observation_id" => t && t.current["observation_id"],
        "successor_generation" => t && t.current["generation"],
        "successor_measurement_state" => if(t && b, do: measurement_state(t, b, state, at)),
        "replacement_status" => status,
        "replacement_reason" => reason
      }
    end)
  end

  defp replacement_status(d, other, a, s, b, t, state, at) do
    cond do
      not d.scope_resolved ->
        {"unresolved", "The declaration has no authoritative concrete scope."}

      not d.selected ->
        {"not_required",
         "This publication excludes the scope; remaining declarations stay independent."}

      is_nil(other) or not other.selected ->
        {"missing", "The successor does not select this exact scope."}

      is_nil(a) or is_nil(s) or is_nil(b) or is_nil(t) ->
        {"unadmitted", "Both exact results must be admitted before replacement."}

      not state.successor.coverage_confirmed ->
        {"unconfirmed", "The successor catalogue is unconfirmed."}

      not compatible?(a, s, b, t, state) ->
        {"incompatible", "Effective parameters, schema, contract, schedule or condition differ."}

      measurement_state(t, b, state, at) != "fresh" ->
        {"not_fresh",
         "The successor needs a fresh measurement of its current desired configuration and session."}

      true ->
        {"ready",
         "Fresh compatible successor evidence is available; result histories remain independent."}
    end
  end

  defp compatible?(a, s, b, t, state) do
    first = state.configs[a.id]
    second = state.configs[b.id]
    condition = fn c -> if c, do: Map.take(c, ~w(namespace key)), else: nil end

    first && second && condition.(s.condition) == condition.(t.condition) &&
      a.parameter_contract == b.parameter_contract && a.params_owner == b.params_owner &&
      Parameters.same_json?(
        Parameters.normalized_schema(a.parameter_schema),
        Parameters.normalized_schema(b.parameter_schema)
      ) &&
      Parameters.same_json?(first.params, second.params) &&
      {a.interval_seconds, a.timeout_seconds, a.freshness_seconds} ==
        {b.interval_seconds, b.timeout_seconds, b.freshness_seconds}
  end

  defp measurement_state(stream, a, state, at) do
    current = stream.current
    runner = state.runners[a.runner_id]
    source = state.successor
    config = state.configs[a.id]

    source_at =
      case DateTime.from_iso8601(current["source_at"] || "") do
        {:ok, date, _} -> date
        _ -> nil
      end

    cond do
      current["generation"] != a.desired_generation or
        current["confirmed_generation"] != a.desired_generation or
        is_nil(config) or config.definition["source_revision"] != source.source_revision or
        config.definition["source_revision"] != source.coverage_source_revision or
          not source.coverage_confirmed ->
        "pending"

      current["session_id"] != runner.session_id ->
        "pending"

      current["knowledge"] == "unavailable" ->
        "unavailable"

      is_nil(source_at) or
          DateTime.compare(
            source_at,
            DateTime.add(at, -round(a.freshness_seconds * 1_000_000), :microsecond)
          ) != :gt ->
        "stale"

      current["observation_id"] != current["confirmed_observation_id"] or
          current["health"] not in ~w(OK WARN CRIT) ->
        "unavailable"

      current["knowledge"] != "fresh" ->
        "stale"

      true ->
        "fresh"
    end
  end

  defp blockers(p, state, rows) do
    source = state.source
    successor = state.successor

    cond do
      p["action"] == "restore" ->
        cond do
          is_nil(source.retired_at) ->
            ["Only a retired publication can be restored."]

          source.revision >= 9_223_372_036_854_775_806 ->
            [
              "This publication reached the inventory revision limit. Deploy a new installation identity instead of restoring it."
            ]

          source.lifecycle_revision >= 9_223_372_036_854_775_806 ->
            [
              "This publication reached the lifecycle revision limit. Deploy a new installation identity instead of restoring it."
            ]

          waiting_restorations(source.runner_id) >= 512 ->
            [
              "This runner already has 512 restoration requests awaiting discovery. Complete a request or retire a waiting publication before restoring another source."
            ]

          true ->
            []
        end

      source.retired_at ->
        ["This publication is already retired."]

      p["action"] == "retire" ->
        []

      is_nil(successor) or successor.id == source.id or successor.runner_id == source.runner_id or
          successor.source_id != source.source_id ->
        ["Choose another installation's active publication of the same source."]

      not is_nil(successor.retired_at) or not is_nil(successor.resume_after_revision) ->
        ["The successor must have an active accepted publication."]

      source.resume_after_revision ->
        ["The predecessor is awaiting a new complete inventory; retire it directly instead."]

      is_nil(source.coverage_version) or not source.coverage_confirmed or
        is_nil(successor.coverage_version) or not successor.coverage_confirmed ->
        [
          "Complete confirmed coverage catalogues are required for replacement; retirement remains available."
        ]

      Enum.any?(state.declarations, &(not &1.scope_resolved)) ->
        [
          "Unresolved declarations prevent claiming complete replacement; retire directly or fix the source catalogue."
        ]

      not Enum.any?(rows, & &1["selected"]) ->
        [
          "A publication without selected results cannot establish complete replacement; retire it directly."
        ]

      Enum.count(rows, & &1["selected"]) != length(state.streams) ->
        [
          "The accepted catalogue does not account for every admitted result; review the source before replacing it."
        ]

      Enum.any?(rows, &(&1["selected"] and &1["replacement_status"] != "ready")) ->
        [
          "Every selected predecessor result needs fresh compatible successor evidence. Inspect the replacement gaps below."
        ]

      true ->
        []
    end
  end

  defp waiting_restorations(runner_id) do
    Repo.aggregate(
      from(p in SourceInventory,
        where:
          p.runner_id == ^runner_id and is_nil(p.retired_at) and
            not is_nil(p.resume_after_revision)
      ),
      :count
    )
  end

  defp summary(state) do
    ids = Enum.map(state.incidents, & &1.id)

    groups =
      state.incidents
      |> Enum.map(& &1.condition_incident_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    pending =
      Repo.aggregate(
        from(o in Occurrence,
          where:
            (o.incident_id in ^ids or o.condition_incident_id in ^groups) and
              o.status in ~w(pending retrying delivering exhausted)
        ),
        :count
      )

    %{
      "assignments" => length(state.assignments),
      "results" => length(state.streams),
      "declared_scopes" => Enum.count(state.declarations, & &1.scope_resolved),
      "selected_results" => Enum.count(state.declarations, & &1.selected),
      "unresolved_declarations" => Enum.count(state.declarations, &(not &1.scope_resolved)),
      "open_incidents" => length(state.incidents),
      "shared_incidents" => length(groups),
      "pending_notifications" => pending
    }
  end

  defp impact_summary(state, rows, action) do
    withdrawing? =
      action != "restore" and is_nil(state.source.retired_at) and
        is_nil(state.source.resume_after_revision)

    summary(state)
    |> Map.merge(%{
      "scopes_losing_last_publisher" =>
        if(withdrawing?,
          do: Enum.count(rows, &(&1["scope_id"] && &1["remaining_publishers"] == 0)),
          else: 0
        ),
      "scopes_losing_last_selected" =>
        if(withdrawing?,
          do: Enum.count(rows, &(&1["selected"] && &1["remaining_selected"] == 0)),
          else: 0
        ),
      "matched_results" =>
        Enum.count(rows, &(&1["selected"] && &1["replacement_status"] == "ready")),
      "replacement_gaps" =>
        if(action == "replace",
          do: Enum.count(rows, &(&1["selected"] && &1["replacement_status"] != "ready")),
          else: 0
        ),
      "code_differs" =>
        state.successor &&
          state.source.coverage_code_revision != state.successor.coverage_code_revision,
      "runtime_differs" =>
        state.successor &&
          state.source.coverage_runtime_revision != state.successor.coverage_runtime_revision,
      "source_revision_differs" =>
        state.successor && state.source.source_revision != state.successor.source_revision
    })
  end

  defp publisher(source) do
    runner = Repo.get!(Runner, source.runner_id)

    lifecycle_status =
      cond do
        source.retired_at -> "retired"
        source.resume_after_revision -> "awaiting_inventory"
        true -> "active"
      end

    %{
      "id" => source.id,
      "runner_id" => source.runner_id,
      "runner_label" => runner.label,
      "source_id" => source.source_id,
      "inventory_revision" => source.revision,
      "source_revision" => source.source_revision,
      "coverage_revision" => source.coverage_revision,
      "coverage_received_at" => Monitoring.iso(source.coverage_received_at),
      "coverage_confirmed" => source.coverage_confirmed,
      "code_revision" => source.coverage_code_revision,
      "runtime_revision" => source.coverage_runtime_revision,
      "runner_context" => source.coverage_context,
      "last_seen_at" => Monitoring.iso(runner.last_seen_at),
      "lifecycle_revision" => source.lifecycle_revision,
      "lifecycle_status" => lifecycle_status,
      "retired_at" => Monitoring.iso(source.retired_at),
      "retirement_reason" => source.retirement_reason,
      "replacement_id" => source.replacement_id,
      "resume_after_revision" => source.resume_after_revision
    }
  end

  defp history(id, page) do
    query = from e in PublisherLifecycleEvent, where: e.publisher_id == ^id
    total = Repo.aggregate(query, :count)
    page = page(page, total)

    rows =
      Repo.all(
        from e in query,
          order_by: [desc: e.lifecycle_revision],
          limit: @limit,
          offset: ^((page - 1) * @limit),
          select: %PublisherLifecycleEvent{
            id: e.id,
            publisher_id: e.publisher_id,
            lifecycle_revision: e.lifecycle_revision,
            action: e.action,
            reason: e.reason,
            actor: e.actor,
            successor_id: e.successor_id,
            inserted_at: e.inserted_at,
            snapshot:
              fragment(
                "? - 'affected_assignment_ids' - 'replacement_evidence' - 'impact_items'",
                e.snapshot
              )
          }
      )

    paged(Enum.map(rows, &event_public/1), page, total)
  end

  defp event_public(e),
    do: %{
      "id" => e.id,
      "publisher_id" => e.publisher_id,
      "lifecycle_revision" => e.lifecycle_revision,
      "action" => e.action,
      "reason" => e.reason,
      "actor" => e.actor,
      "successor_id" => e.successor_id,
      "inserted_at" => Monitoring.iso(e.inserted_at),
      "summary" => e.snapshot["summary"],
      "before" => e.snapshot["before"],
      "after" => e.snapshot["after"],
      "successor" => e.snapshot["successor"]
    }

  defp proposal!(p) when is_map(p) do
    allowed = ~w(publisher_id action reason successor_id)

    unless Enum.all?(Map.keys(p), &(&1 in allowed)) and p["action"] in ~w(retire replace restore) and
             Parameters.text?(p["reason"], 500),
           do:
             Repo.rollback(
               {:invalid,
                "Choose retire, replace or restore and supply a reason within 500 bytes."}
             )

    id = positive_id(p["publisher_id"]) || Repo.rollback({:invalid, "Choose a publication."})

    successor =
      if p["action"] == "replace",
        do:
          positive_id(p["successor_id"]) ||
            Repo.rollback({:invalid, "Choose a successor publication."})

    if p["action"] != "replace" and not is_nil(p["successor_id"]) and p["successor_id"] != "",
      do: Repo.rollback({:invalid, "Only replacement accepts a successor."})

    %{"publisher_id" => id, "action" => p["action"], "reason" => String.trim(p["reason"])}
    |> then(fn value ->
      if successor, do: Map.put(value, "successor_id", successor), else: value
    end)
  end

  defp proposal!(_), do: Repo.rollback({:invalid, "Supply a lifecycle proposal."})

  defp find!(id) do
    id = positive_id(id) || Repo.rollback(:not_found)
    Repo.get(SourceInventory, id) || Repo.rollback(:not_found)
  end

  defp positive_id(n) when is_integer(n) and n > 0 and n < 9_223_372_036_854_775_807, do: n

  defp positive_id(n) when is_binary(n) and byte_size(n) < 20 do
    case Integer.parse(n) do
      {id, ""} -> positive_id(id)
      _ -> nil
    end
  end

  defp positive_id(_), do: nil

  defp page(value, total),
    do: min(positive_id(value) || 1, max(1, div(total + @limit - 1, @limit)))

  defp paged(items, page, total),
    do: %{
      "items" => items,
      "page" => page,
      "page_size" => @limit,
      "total" => total,
      "pages" => max(1, div(total + @limit - 1, @limit))
    }

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp verify_review!(token, expected) when is_binary(token) and byte_size(token) in 1..10000 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "publisher-lifecycle", token, max_age: @max_age) do
      {:ok, ^expected} -> :ok
      {:ok, _} -> Repo.rollback(:review_changed)
      {:error, :expired} -> Repo.rollback(:review_expired)
      _ -> Repo.rollback(:invalid_review)
    end
  end

  defp verify_review!(_, _), do: Repo.rollback(:invalid_review)
end
