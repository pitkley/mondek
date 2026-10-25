# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionInspection do
  @moduledoc "Bounded shared-incident investigation with complete episode counts and independent evidence."
  import Ecto.Query
  require Mondek.Inspection

  alias Mondek.{
    Repo,
    Monitoring,
    Inspection,
    Maintenance,
    ConditionIncident,
    Incident,
    Assignment,
    ResultStream,
    Runner,
    Occurrence,
    OccurrenceEvidence,
    Observation,
    Attempt,
    Control
  }

  @page_size 25
  @history_limit 100

  defmacrop individually_acknowledged(i, at) do
    quote do
      fragment(
        "(?='until_incident_ends' OR (?='until' AND ?>?))",
        unquote(i).acknowledgement_mode,
        unquote(i).acknowledgement_mode,
        unquote(i).acknowledged_until,
        unquote(at)
      )
    end
  end

  defmacrop maintained(i, a, s, at) do
    quote do
      fragment(
        """
        EXISTS (SELECT 1 FROM maintenance_windows w
          WHERE w.cancelled_at IS NULL AND w.starts_at<=? AND w.ends_at>?
          AND ((w.scope='check' AND w.assignment_id=?)
            OR (w.scope='target' AND w.source_id=? AND w.environment IS NOT DISTINCT FROM ?
              AND w.target_kind=?->>'kind' AND w.target_key=?->>'key')
            OR (w.scope='selection' AND maintenance_selections_match(w.selections,?,?,?,?,?))))
        """,
        unquote(at),
        unquote(at),
        unquote(a).id,
        unquote(a).source_id,
        unquote(i).environment,
        unquote(s).target,
        unquote(s).target,
        unquote(a).id,
        unquote(a).source_id,
        unquote(i).environment,
        fragment("?->>'kind'", unquote(s).target),
        fragment("?->>'key'", unquote(s).target)
      )
    end
  end

  def detail(id, filters \\ %{}, at \\ Monitoring.now()) do
    if Repo.in_transaction?() do
      read_detail(id, filters, at)
    else
      {:ok, detail} =
        Repo.transaction(fn ->
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
          read_detail(id, filters, at)
        end)

      detail
    end
  end

  defp read_detail(id, filters, at) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %ConditionIncident{} = group <- Repo.get(ConditionIncident, id) do
      filters =
        if is_map(filters), do: Map.new(filters, fn {k, v} -> {to_string(k), v} end), else: %{}

      shared_ack? = Monitoring.acknowledgement_active?(group, at)
      query = from i in Incident, where: i.condition_incident_id == ^id
      counts = counts(query, shared_ack?, at)
      state = valid_state(filters["state"], group)

      selected =
        case state do
          "open" ->
            from i in query, where: i.status == "open"

          "history" ->
            from i in query, where: i.status == "closed"

          "all" ->
            query

          "uncovered" ->
            from i in query,
              join: a in Assignment,
              on: a.id == i.assignment_id,
              join: s in ResultStream,
              on: s.id == i.stream_id,
              where:
                i.status == "open" and not (^shared_ack?) and is_nil(a.retired_at) and
                  not coalesce(individually_acknowledged(i, ^at), false) and
                  not maintained(i, a, s, ^at),
              select: i
        end

      {page, page_meta} = page(selected, filters["page"])

      incidents =
        Repo.all(
          from i in selected,
            order_by: [
              desc: fragment("CASE WHEN ?='open' THEN 1 ELSE 0 END", i.status),
              desc: fragment("CASE ? WHEN 'CRIT' THEN 2 ELSE 1 END", i.health),
              desc: i.opened_at,
              desc: i.id
            ],
            limit: @page_size,
            offset: ^((page - 1) * @page_size)
        )

      assignment_ids = Enum.map(incidents, & &1.assignment_id) |> Enum.uniq()

      assignments =
        Repo.all(from a in Assignment, where: a.id in ^assignment_ids) |> Map.new(&{&1.id, &1})

      streams =
        Inspection.stream_details(Enum.map(incidents, & &1.stream_id), at)
        |> Map.new(&{&1["id"], &1})

      active_parents =
        incidents
        |> Enum.filter(&(&1.status == "open"))
        |> Enum.map(&{&1, assignments[&1.assignment_id]})

      windows = Maintenance.active_for_many(active_parents, at)

      {contradictions, contradiction_page} =
        contradictions(group, filters["contradiction_page"], at)

      {notices, notification_page, attempts, attempts_meta, notice_evidence, notification_counts} =
        notifications(group, filters, at)

      {controls, controls_meta} = controls(group)

      closing_refs =
        if group.closing_observation_id,
          do:
            Repo.all(
              from i in query,
                where: i.closing_observation_id == ^group.closing_observation_id,
                limit: 16,
                select: {i.closing_observation_id, i.result_key}
            ),
          else: []

      requested =
        Enum.flat_map(incidents, fn i ->
          [
            {i.opening_observation_id, i.result_key},
            {i.latest_observation_id, i.result_key},
            {i.closing_observation_id, i.result_key},
            {get_in(streams, [i.stream_id, "current", "observation_id"]), i.result_key}
          ]
        end) ++
          Enum.flat_map(contradictions, fn s ->
            [
              {s["current"]["confirmed_observation_id"], s["result_key"]},
              {s["current"]["observation_id"], s["result_key"]}
            ]
          end) ++ Enum.map(notice_evidence, &{&1.observation_id, &1.result_key}) ++ closing_refs

      {evidence, evidence_meta} = evidence(requested)
      by_id = Map.new(evidence, &{&1["id"], &1})

      contributions =
        Enum.map(incidents, fn incident ->
          assignment = assignments[incident.assignment_id]
          matching = Map.get(windows, incident.id, [])
          individual_ack? = Monitoring.acknowledgement_active?(incident, at)
          open? = incident.status == "open"

          %{
            "incident" => Monitoring.public(incident),
            "stream" => streams[incident.stream_id],
            "assignment" => Monitoring.public(assignment),
            "contribution_state" => contribution_state(incident),
            "last_failure_health" => incident.health,
            "measured_result" =>
              result(by_id[incident.latest_observation_id], incident.result_key),
            "evidence_ids" => %{
              "opening" => incident.opening_observation_id,
              "latest" => incident.latest_observation_id,
              "closing" => incident.closing_observation_id
            },
            "coverage" => %{
              "shared_acknowledgement" => open? and shared_ack?,
              "individual_acknowledgement" => individual_ack?,
              "maintenance_windows" => Enum.map(matching, &Maintenance.reference/1),
              "uncovered" =>
                open? and not shared_ack? and not individual_ack? and matching == [] and
                  is_nil(assignment.retired_at)
            }
          }
        end)

      %{
        "incident" => Monitoring.public(group) |> Map.put("acknowledgement_active", shared_ack?),
        "counts" => Map.put(counts, "contradictory_results", contradiction_page["total"]),
        "contributions" => contributions,
        "contribution_page" => Map.put(page_meta, "state", state),
        "contradictions" => contradictions,
        "contradiction_page" => contradiction_page,
        "occurrences" => Monitoring.inspect_occurrences(notices, at),
        "notification_page" => notification_page,
        "notification_counts" => notification_counts,
        "attempts" => Enum.map(attempts, &Monitoring.public/1),
        "controls" => Enum.map(controls, &Monitoring.public/1),
        "evidence" => evidence,
        "closing_evidence" => by_id[group.closing_observation_id],
        "evidence_projection" => "referenced_result_excerpts",
        "as_of" => Monitoring.iso(at),
        "limits" => %{
          "attempts" => attempts_meta,
          "controls" => controls_meta,
          "evidence" => evidence_meta
        }
      }
    else
      _ -> nil
    end
  end

  defp counts(query, shared_ack?, at) do
    Repo.one(
      from i in query,
        join: a in Assignment,
        on: a.id == i.assignment_id,
        join: s in ResultStream,
        on: s.id == i.stream_id,
        left_join: r in Runner,
        on: r.id == a.runner_id,
        select: %{
          "total" => count(i.id),
          "open" => filter(count(i.id), i.status == "open"),
          "recovered" =>
            filter(count(i.id), i.status == "closed" and i.closure_reason == "measured_recovery"),
          "withdrawn" =>
            filter(count(i.id), i.status == "closed" and i.closure_reason != "measured_recovery"),
          "critical" => filter(count(i.id), i.status == "open" and i.health == "CRIT"),
          "warning" => filter(count(i.id), i.status == "open" and i.health == "WARN"),
          "shared_acknowledged" => filter(count(i.id), i.status == "open" and ^shared_ack?),
          "individually_acknowledged" =>
            filter(count(i.id), i.status == "open" and individually_acknowledged(i, ^at)),
          "maintained" => filter(count(i.id), i.status == "open" and maintained(i, a, s, ^at)),
          "uncovered" =>
            filter(
              count(i.id),
              i.status == "open" and not (^shared_ack?) and is_nil(a.retired_at) and
                not coalesce(individually_acknowledged(i, ^at), false) and
                not maintained(i, a, s, ^at)
            ),
          "fresh" =>
            filter(
              count(i.id),
              i.status == "open" and Inspection.knowledge(s, a, r, ^at) == "fresh"
            ),
          "stale" =>
            filter(
              count(i.id),
              i.status == "open" and Inspection.knowledge(s, a, r, ^at) == "stale"
            ),
          "unavailable" =>
            filter(
              count(i.id),
              i.status == "open" and Inspection.knowledge(s, a, r, ^at) == "unavailable"
            ),
          "awaiting" =>
            filter(
              count(i.id),
              i.status == "open" and Inspection.knowledge(s, a, r, ^at) == "awaiting"
            )
        }
    )
  end

  defp contradictions(group, requested_page, at) do
    query =
      from s in ResultStream,
        join: a in Assignment,
        on: a.id == s.assignment_id,
        where:
          is_nil(s.retired_at) and is_nil(a.retired_at) and
            fragment(
              "?->>'namespace' = ? AND ?->>'key' = ?",
              s.condition,
              ^group.namespace,
              s.condition,
              ^group.key
            ) and
            fragment("? IS NOT DISTINCT FROM ?", s.environment, type(^group.environment, :string)) and
            fragment(
              "?->>'confirmed_observation_id' IS NOT NULL AND ?->>'health'='OK'",
              s.current,
              s.current
            )

    {page, meta} = page(query, requested_page)

    ids =
      Repo.all(
        from [s, a] in query,
          order_by: [asc: a.label, asc: s.label, asc: s.id],
          limit: @page_size,
          offset: ^((page - 1) * @page_size),
          select: s.id
      )

    details = Inspection.stream_details(ids, at) |> Map.new(&{&1["id"], &1})
    {Enum.map(ids, &details[&1]), meta}
  end

  defp notifications(group, filters, _at) do
    all = from o in Occurrence, where: o.condition_incident_id == ^group.id

    focused =
      case Ecto.UUID.cast(filters["notification_id"]) do
        {:ok, id} -> Repo.one(from o in all, where: o.id == ^id)
        :error -> nil
      end

    counts =
      Repo.all(from o in all, group_by: o.status, select: {o.status, count(o.id)}) |> Map.new()

    counts =
      Map.merge(
        Map.new(~w(pending retrying delivering exhausted delivered superseded), &{&1, 0}),
        counts
      )

    total_notices = Enum.sum(Map.values(counts))
    counts = Map.put(counts, "total", total_notices)

    status =
      case if(focused, do: "all", else: filters["notification_status"]) do
        value
        when value in ~w(all unresolved pending retrying delivering exhausted delivered superseded) ->
          value

        _ ->
          if group.status == "open", do: "unresolved", else: "all"
      end

    selected =
      case status do
        "all" -> all
        "unresolved" -> from o in all, where: o.status not in ["delivered", "superseded"]
        other -> from o in all, where: o.status == ^other
      end

    requested_page =
      if focused do
        # A direct attempt link must still locate its exact notification after
        # newer facts have moved it beyond the first page of retained history.
        newer =
          Repo.aggregate(
            from(o in all,
              where:
                o.inserted_at > ^focused.inserted_at or
                  (o.inserted_at == ^focused.inserted_at and o.id > ^focused.id)
            ),
            :count
          )

        div(newer, @page_size) + 1
      else
        filters["notification_page"]
      end

    {page, meta} = page(selected, requested_page)

    ordered =
      if status in ~w(all delivered superseded),
        do: from(o in selected, order_by: [desc: o.inserted_at, desc: o.id]),
        else: from(o in selected, order_by: [asc: o.inserted_at, asc: o.id])

    notices = Repo.all(from o in ordered, limit: @page_size, offset: ^((page - 1) * @page_size))
    ids = Enum.map(notices, & &1.id)

    attempts_query =
      from t in Attempt,
        join: o in Occurrence,
        on: o.id == t.occurrence_id,
        where: o.condition_incident_id == ^group.id

    displayed = from t in attempts_query, where: t.occurrence_id in ^ids
    # One latest attempt per displayed occurrence remains inspectable even when
    # one notification has used most of the group's retry history.
    latest =
      Repo.all(
        from t in displayed, distinct: t.occurrence_id, order_by: [desc: t.started_at, desc: t.id]
      )

    recent =
      Repo.all(
        from t in displayed, order_by: [desc: t.started_at, desc: t.id], limit: @history_limit
      )

    attempts =
      (latest ++ recent)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    refs = Repo.all(from e in OccurrenceEvidence, where: e.occurrence_id in ^ids)
    total = Repo.aggregate(attempts_query, :count)

    {notices, Map.merge(meta, %{"status" => status, "all_total" => total_notices}), attempts,
     %{
       "total" => total,
       "returned" => length(attempts),
       "omitted" => max(0, total - length(attempts)),
       "limit" => @history_limit + @page_size,
       "recent_limit" => @history_limit,
       "per_occurrence_latest" => true
     }, refs, counts}
  end

  defp controls(group) do
    members = from i in Incident, where: i.condition_incident_id == ^group.id, select: i.id

    scoped =
      from i in Incident,
        where:
          i.condition_incident_id == ^group.id and
            i.assignment_id == parent_as(:control).assignment_id and
            parent_as(:control).kind in [
              "maintenance",
              "check_retired",
              "source_removed",
              "publisher_retired",
              "publisher_replaced"
            ] and
            (is_nil(parent_as(:control).stream_id) or parent_as(:control).stream_id == i.stream_id) and
            parent_as(:control).until >= i.opened_at and
            (is_nil(i.closed_at) or parent_as(:control).inserted_at <= i.closed_at),
        select: i.id

    query =
      from c in Control,
        as: :control,
        where:
          c.condition_incident_id == ^group.id or
            c.incident_id in subquery(members) or exists(subquery(scoped))

    rows =
      Repo.all(
        from c in query, order_by: [desc: c.inserted_at, desc: c.id], limit: @history_limit
      )

    total = Repo.aggregate(query, :count)

    {rows,
     %{
       "total" => total,
       "returned" => length(rows),
       "omitted" => max(0, total - length(rows)),
       "limit" => @history_limit
     }}
  end

  defp evidence(requested) do
    requested =
      requested |> Enum.reject(fn {id, key} -> is_nil(id) or is_nil(key) end) |> Enum.uniq()

    by_id = Enum.group_by(requested, &elem(&1, 0), &elem(&1, 1))
    ids = Map.keys(by_id)

    rows =
      Repo.all(
        from o in Observation,
          where: o.id in ^ids,
          order_by: [desc: o.received_at, desc: o.id],
          select:
            {%Observation{
               id: o.id,
               assignment_id: o.assignment_id,
               installation_id: o.installation_id,
               session_id: o.session_id,
               generation: o.generation,
               sequence: o.sequence,
               started_at: o.started_at,
               evaluated_at: o.evaluated_at,
               received_at: o.received_at,
               disposition: o.disposition,
               payload:
                 fragment(
                   """
                   (? - 'results') || jsonb_build_object('results',
                     (SELECT coalesce(jsonb_agg(result ORDER BY position),'[]'::jsonb)
                      FROM jsonb_array_elements(?->'results') WITH ORDINALITY AS emitted(result,position)
                      WHERE result->>'key' IN (SELECT jsonb_array_elements_text(?->(?::text)))))
                   """,
                   o.payload,
                   o.payload,
                   type(^by_id, :map),
                   o.id
                 )
             }, fragment("jsonb_array_length(?->'results')", o.payload)}
      )

    public =
      Enum.map(rows, fn {observation, original_count} ->
        Monitoring.public(observation)
        |> Map.put("included_result_keys", by_id[observation.id])
        |> Map.put("excerpt", true)
        |> Map.put("original_result_count", original_count)
        |> Map.put(
          "omitted_result_count",
          original_count - length(observation.payload["results"])
        )
      end)

    {public,
     %{
       "requested" => length(ids),
       "returned" => length(rows),
       "missing" => length(ids) - length(rows)
     }}
  end

  defp result(nil, _key), do: nil

  defp result(evidence, key),
    do: Enum.find(evidence["payload"]["results"] || [], &(&1["key"] == key))

  defp contribution_state(%{status: "open"}), do: "open"
  defp contribution_state(%{closure_reason: "measured_recovery"}), do: "recovered"
  defp contribution_state(_), do: "withdrawn"
  defp valid_state(state, _group) when state in ~w(open history all uncovered), do: state
  defp valid_state(_, group), do: if(group.status == "open", do: "open", else: "history")

  defp page(query, requested) do
    total = Repo.aggregate(query, :count)
    pages = max(1, div(total + @page_size - 1, @page_size))

    value =
      case requested do
        integer when is_integer(integer) ->
          integer

        text when is_binary(text) ->
          case Integer.parse(text) do
            {integer, ""} -> integer
            _ -> 1
          end

        _ ->
          1
      end

    page = min(pages, max(1, value))
    returned = min(@page_size, max(0, total - (page - 1) * @page_size))

    {page,
     %{
       "page" => page,
       "page_size" => @page_size,
       "total" => total,
       "pages" => pages,
       "returned" => returned,
       "omitted" => max(0, total - returned)
     }}
  end
end
