# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Inspection do
  @moduledoc "Paged operator queries; summary counts never depend on the visible page."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Monitoring,
    Assignment,
    ResultStream,
    Runner,
    Incident,
    Occurrence,
    Observation,
    Control,
    Attempt
  }

  @configuration_stages ~w(saved prepared active measured)
  @target_summary_fields ~w(identity label environment_label urgency total observers critical warning unknown healthy fresh stale unavailable awaiting retired inventory_total id)a

  # One identity expression for grouping and exact-target investigation. Missing
  # historical source/target identities remain isolated by retained stream ID.
  defmacrop target_identity(stream, assignment) do
    quote do
      fragment(
        "jsonb_build_array(?::text, ?::text, ?->>'kind', ?->>'key', CASE WHEN ?::text IS NULL OR ?->>'key' IS NULL OR ?->>'kind' IS NULL THEN ?::text ELSE NULL END)",
        unquote(assignment).source_id,
        unquote(stream).environment,
        unquote(stream).target,
        unquote(stream).target,
        unquote(assignment).source_id,
        unquote(stream).target,
        unquote(stream).target,
        unquote(stream).id
      )
    end
  end

  defmacrop target_identity_id(identity) do
    quote do
      fragment(
        "'target-' || encode(sha256(convert_to('[' || (SELECT string_agg(value::text, ',' ORDER BY ordinality) FROM jsonb_array_elements(?) WITH ORDINALITY) || ']', 'UTF8')), 'hex')",
        unquote(identity)
      )
    end
  end

  defmacrop browse_identity(stream, assignment) do
    quote do
      fragment(
        "CASE WHEN ? IS NULL THEN ? ELSE jsonb_build_array(?::text, ?::text, 'check-group', ?->>'key', NULL, 'group') END",
        unquote(stream).check_group,
        target_identity(unquote(stream), unquote(assignment)),
        unquote(assignment).source_id,
        unquote(stream).environment,
        unquote(stream).check_group
      )
    end
  end

  defmacrop browse_identity_id(identity) do
    quote do
      fragment(
        "CASE WHEN jsonb_array_length(?) = 6 THEN 'group-' ELSE 'target-' END || encode(sha256(convert_to('[' || (SELECT string_agg(value::text, ',' ORDER BY ordinality) FROM jsonb_array_elements(?) WITH ORDINALITY) || ']', 'UTF8')), 'hex')",
        unquote(identity),
        unquote(identity)
      )
    end
  end

  @doc "Opaque exact-target identity for a public result, including isolated legacy results."
  def target_id(%{"id" => id} = stream) when is_binary(id) do
    target = stream["target"] || %{}
    source = stream["source_id"]
    kind = target["kind"]
    key = target["key"]
    fallback = if is_nil(source) or is_nil(kind) or is_nil(key), do: id
    identity = [source, stream["environment"], kind, key, fallback]
    "target-" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(identity)), case: :lower)
  end

  def target_id(_), do: nil

  @doc "Inspect one runner independently of the bounded fleet listing."
  def runner_detail(id) do
    if uuid?(id) do
      case Repo.get(Runner, id) do
        nil -> nil
        runner -> Monitoring.public(runner)
      end
    end
  end

  # Keep SQL classification aligned with Monitoring.acknowledgement_active?/2:
  # expiry is exclusive, and a closed incident never has an active acknowledgement.
  defmacrop acknowledgement_active_sql(incident, at) do
    quote do
      fragment(
        "? = 'open' AND COALESCE(? = 'until_incident_ends' OR (? = 'until' AND ? > ?::timestamp), FALSE)",
        unquote(incident).status,
        unquote(incident).acknowledgement_mode,
        unquote(incident).acknowledgement_mode,
        unquote(incident).acknowledged_until,
        unquote(at)
      )
    end
  end

  defmacrop measured_health(s) do
    quote do
      fragment(
        "CASE WHEN ?->>'confirmed_observation_id' IS NOT NULL THEN ?->>'health' ELSE NULL END",
        unquote(s).current,
        unquote(s).current
      )
    end
  end

  # Measured is an achieved milestone for the desired version, independent of
  # whether its last evidence is still fresh or a later collection failed.
  defmacrop configuration_stage_sql(a) do
    quote do
      fragment(
        "CASE WHEN ? IS NOT NULL THEN 'retired' WHEN (CASE WHEN ? IS NOT NULL THEN ? ELSE (?->>'confirmed_generation')::bigint END) = ? THEN 'measured' WHEN ? = ? THEN 'active' WHEN ? = ? THEN 'prepared' ELSE 'saved' END",
        unquote(a).retired_at,
        unquote(a).source_id,
        unquote(a).observed_generation,
        unquote(a).current,
        unquote(a).desired_generation,
        unquote(a).active_generation,
        unquote(a).desired_generation,
        unquote(a).prepared_generation,
        unquote(a).desired_generation
      )
    end
  end

  @doc false
  defmacro knowledge(s, a, r, at) do
    quote do
      fragment(
        "CASE WHEN ? IS NOT NULL THEN 'retired' WHEN ? = '{}'::jsonb OR (?->>'generation')::bigint IS DISTINCT FROM ? OR (? IS NOT NULL AND ?->>'session_id' IS DISTINCT FROM ?::text) THEN 'awaiting' WHEN ?->>'knowledge' IN ('unavailable','stale') THEN ?->>'knowledge' WHEN ?->>'source_at' IS NULL OR (?->>'source_at')::timestamptz <= ?::timestamptz - (? * INTERVAL '1 second') THEN 'stale' ELSE 'fresh' END",
        unquote(s).retired_at,
        unquote(s).current,
        unquote(s).current,
        unquote(a).authorized_generation,
        unquote(r).id,
        unquote(s).current,
        unquote(r).session_id,
        unquote(s).current,
        unquote(s).current,
        unquote(s).current,
        unquote(s).current,
        unquote(at),
        unquote(a).freshness_seconds
      )
    end
  end

  defp base_streams do
    from s in ResultStream,
      as: :stream,
      join: a in Assignment,
      on: a.id == s.assignment_id,
      left_join: r in Runner,
      on: r.id == a.runner_id
  end

  def coverage(at) do
    classified =
      from [s, a, r] in base_streams(),
        where: is_nil(s.retired_at),
        select: %{knowledge: knowledge(s, a, r, ^at)}

    counts =
      Repo.all(
        from c in subquery(classified), group_by: c.knowledge, select: {c.knowledge, count()}
      )
      |> Map.new()

    active = Enum.sum(Map.values(counts))

    %{
      "active" => active,
      "expected_count" => active,
      "fresh" => Map.get(counts, "fresh", 0),
      "pending" => Map.get(counts, "awaiting", 0),
      "stale" => Map.get(counts, "stale", 0),
      "unavailable" => Map.get(counts, "unavailable", 0)
    }
  end

  def navigation_counts(at) do
    standalone =
      Repo.one(
        from i in Incident,
          where: i.status == "open" and is_nil(i.condition_incident_id),
          select: {count(), filter(count(), acknowledgement_active_sql(i, ^at))}
      )

    grouped =
      Repo.one(
        from g in Mondek.ConditionIncident,
          where: g.status == "open",
          select: {count(), filter(count(), acknowledgement_active_sql(g, ^at))}
      )

    open_count = elem(standalone, 0) + elem(grouped, 0)
    acknowledged_count = elem(standalone, 1) + elem(grouped, 1)

    %{
      "monitoring_loss" => Mondek.MonitoringLoss.counts(at),
      "open_incident_count" => open_count,
      "unacknowledged_incident_count" => open_count - acknowledged_count,
      "acknowledged_incident_count" => acknowledged_count
    }
  end

  def overview(at, runner_id \\ nil) do
    counts = navigation_counts(at)

    %{
      "version" => 1,
      "now" => Monitoring.iso(at),
      "coverage" => coverage(at),
      "monitoring_loss" => counts["monitoring_loss"],
      "open_incident_count" => counts["open_incident_count"],
      "unacknowledged_incident_count" => counts["unacknowledged_incident_count"],
      "acknowledged_incident_count" => counts["acknowledged_incident_count"],
      "runners" => runners(at, runner_id),
      "runner_count" => Repo.aggregate(Runner, :count),
      "runner_counts" => Mondek.RunnerFleet.counts(at),
      "assignment_limits" => %{
        "active" => Repo.aggregate(from(a in Assignment, where: is_nil(a.retired_at)), :count),
        "active_limit" => 512,
        "active_limit_scope" => "per_runner",
        "retired_total" =>
          Repo.aggregate(from(a in Assignment, where: not is_nil(a.retired_at)), :count)
      },
      "notification_backlog" => backlog(),
      "assignments" => [],
      "incidents" => [],
      "occurrences" => [],
      "attempts" => [],
      "controls" => [],
      "jobs" => [],
      "evidence" => [],
      "retention" => Mondek.Retention.summary()
    }
  end

  def runners(at \\ nil, runner_id \\ nil) do
    counts =
      Repo.all(
        from a in Assignment,
          where: is_nil(a.retired_at),
          group_by: a.runner_id,
          select: {a.runner_id, count(a.id)}
      )
      |> Map.new()

    coverage = if at, do: runner_coverage(at), else: %{}

    runner_query = from r in Runner, order_by: [asc: r.label, asc: r.id], limit: 100

    runner_query =
      cond do
        runner_id in [nil, ""] -> runner_query
        uuid?(runner_id) -> from r in runner_query, where: r.id == ^runner_id
        true -> from r in runner_query, where: false
      end

    Repo.all(runner_query)
    |> Enum.map(fn r ->
      public =
        Monitoring.public(r)
        |> Map.merge(%{
          "installation_id" => r.id,
          "check_count" => Map.get(counts, r.id, 0)
        })

      if at,
        do: Map.put(public, "coverage", Map.get(coverage, r.id, empty_coverage())),
        else: public
    end)
  end

  defp runner_coverage(at) do
    classified =
      from [s, a, r] in base_streams(),
        where: is_nil(s.retired_at),
        select: %{runner_id: a.runner_id, knowledge: knowledge(s, a, r, ^at)}

    Repo.all(
      from c in subquery(classified),
        group_by: [c.runner_id, c.knowledge],
        select: {c.runner_id, c.knowledge, count()}
    )
    |> Enum.reduce(%{}, fn {runner_id, knowledge, count}, coverage ->
      Map.update(coverage, runner_id, Map.put(empty_coverage(), knowledge, count), fn values ->
        Map.put(values, knowledge, count)
      end)
    end)
    |> Map.new(fn {runner_id, values} ->
      {runner_id, Map.put(values, "active", Enum.sum(Map.values(values)))}
    end)
  end

  defp empty_coverage,
    do: %{"active" => 0, "fresh" => 0, "awaiting" => 0, "stale" => 0, "unavailable" => 0}

  defp facets do
    assignments =
      from a in Assignment,
        where: not is_nil(a.environment),
        select: %{
          id: a.environment,
          label: coalesce(a.environment_label, a.environment),
          priority: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 2 END", a.retired_at)
        }

    streams =
      from s in ResultStream,
        where: not is_nil(s.environment),
        select: %{
          id: s.environment,
          label: coalesce(s.environment_label, s.environment),
          priority: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 3 END", s.retired_at)
        }

    incidents =
      from i in Incident,
        where: not is_nil(i.environment),
        select: %{
          id: i.environment,
          label: coalesce(i.environment_label, i.environment),
          priority: 4
        }

    environments = assignments |> union_all(^streams) |> union_all(^incidents)

    entries =
      Repo.all(
        from e in subquery(environments),
          distinct: e.id,
          order_by: [asc: e.id, asc: e.priority, asc: e.label],
          select: %{id: e.id, label: e.label},
          limit: 100
      )
      |> Enum.map(&%{"id" => &1.id, "label" => &1.label})

    %{"runners" => runners(), "environments" => entries}
  end

  def list_streams(filters, at) do
    f = normalize(filters)
    query = base_streams() |> stream_filters(f, at)

    query =
      if f["attention"] in [true, "true"],
        do:
          from([s, a, r] in query,
            order_by: [
              desc:
                fragment(
                  "CASE ? WHEN 'CRIT' THEN 3 WHEN 'WARN' THEN 2 ELSE 1 END",
                  measured_health(s)
                )
            ]
          ),
        else: query

    {page, size, total} = page(query, f)

    rows =
      Repo.all(
        from [s, a, r] in query,
          order_by: [asc: a.label, asc: s.label, asc: s.id],
          offset: ^((page - 1) * size),
          limit: ^size,
          select: {s, a, r, knowledge(s, a, r, ^at)}
      )

    %{
      items: public_streams(rows),
      total: total,
      page: page,
      page_size: size,
      filter_counts: stream_filter_counts(f, at),
      scope_target: scope_target(f, at),
      coverage: coverage(at),
      facets: facets()
    }
  end

  @doc "Group-contiguous result pages, with summaries over every matching result."
  def list_grouped_streams(filters, at) do
    f = normalize(filters)
    query = base_streams() |> stream_filters(f, at)
    {page, size, total} = page(query, f)
    ranked = ranked_streams(query, at, true)
    summaries = target_summaries(ranked, f, at, true)
    {items, groups} = grouped_page(ranked, summaries, page, size)

    %{
      items: items,
      groups: groups,
      total: total,
      page: page,
      page_size: size,
      filter_counts: stream_filter_counts(f, at),
      scope_target: scope_target(f, at),
      coverage: coverage(at),
      facets: facets()
    }
  end

  @doc "Bounded target index and a separately paged selected target's matching results."
  def list_target_streams(filters, at) do
    f = normalize(filters)
    query = base_streams() |> stream_filters(f, at)
    ranked = ranked_streams(query, at, true)
    summaries = target_summaries(ranked, f, at, true)
    target_total = Repo.aggregate(from(g in subquery(summaries)), :count)
    group_limit = number(f["group_limit"], 100, 1000)

    search =
      if is_binary(f["group_search"]), do: String.slice(f["group_search"], 0, 200), else: ""

    sidebar = from g in subquery(summaries), order_by: [asc: g.label, asc: g.identity]

    sidebar =
      if search == "" do
        sidebar
      else
        # Literal substring matching: percent and underscore are not wildcards.
        from g in sidebar,
          where:
            fragment("strpos(lower(?), lower(?)) > 0", g.label, ^search) or
              fragment(
                "strpos(lower(concat_ws(' ', ?->>0, ?->>1, ?->>3)), lower(?)) > 0",
                g.identity,
                g.identity,
                g.identity,
                ^search
              )
      end

    group_total = Repo.aggregate(sidebar, :count)
    targets = Repo.all(from g in sidebar, limit: ^group_limit)

    selected_id = f["target"]

    selected =
      if present?(selected_id) do
        Repo.one(from g in subquery(summaries), where: g.id == ^selected_id, limit: 1)
      end ||
        Repo.one(
          from g in subquery(summaries), order_by: [asc: g.label, asc: g.identity], limit: 1
        )

    selected_total = if selected, do: selected.total, else: 0
    size = number(f["page_size"], 50, 100)
    page = min(number(f["page"], 1, 1_000_000), max(1, ceil(selected_total / size)))

    {items, groups} =
      if selected,
        do: grouped_page(ranked, summaries, page, size, selected.id),
        else: {[], []}

    %{
      items: items,
      groups: groups,
      total: Repo.aggregate(query, :count),
      page: page,
      page_size: size,
      target_groups: Enum.map(targets, &public_target/1),
      target_total: target_total,
      target_page: 1,
      target_page_size: group_limit,
      group_total: group_total,
      group_limit: group_limit,
      group_has_more: group_total > group_limit and group_limit < 1000,
      group_limit_reached: group_total > group_limit and group_limit == 1000,
      selected_target: selected && public_target(selected),
      selected_total: selected_total,
      filter_counts: stream_filter_counts(f, at),
      scope_target: scope_target(f, at),
      coverage: coverage(at),
      facets: facets()
    }
  end

  # Keep the named investigation boundary visible even when a secondary filter
  # has no results. Membership still applies: retired-only targets do not become
  # active simply to supply a label. Unscoped inventories need no extra query.
  defp scope_target(f, at) do
    if valid_target_scope?(f["target_scope"]) do
      scope = Map.take(f, ["status", "target_scope"])
      ranked = base_streams() |> stream_filters(scope, at) |> ranked_streams(at)
      summary = target_summaries(ranked, scope, at)

      case Repo.one(from g in subquery(summary), limit: 1) do
        nil -> nil
        target -> public_target(target)
      end
    end
  end

  defp valid_target_scope?(scope) when is_binary(scope),
    do: byte_size(scope) == 71 and String.match?(scope, ~r/^target-[0-9a-f]{64}$/)

  defp valid_target_scope?(_), do: false

  defp ranked_streams(query, at, browsing \\ false) do
    classified =
      from [s, a, r] in query,
        select: %{
          id: s.id,
          identity: target_identity(s, a),
          target_label:
            fragment("COALESCE(?->>'label', ?->>'key', ?)", s.target, s.target, s.label),
          environment_label: coalesce(s.environment_label, s.environment),
          runner_id: a.runner_id,
          check_label: a.label,
          result_label: s.label,
          health: measured_health(s),
          knowledge: knowledge(s, a, r, ^at),
          active: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", s.retired_at)
        }

    classified =
      if browsing do
        from [s, a, _r] in classified,
          select_merge: %{
            identity: browse_identity(s, a),
            target_label:
              fragment(
                "COALESCE(?->>'label', ?->>'label', ?->>'key', ?)",
                s.check_group,
                s.target,
                s.target,
                s.label
              )
          }
      else
        classified
      end

    from c in subquery(classified),
      select_merge: %{
        urgency:
          fragment(
            "CASE WHEN ? = 0 THEN 0 WHEN ? = 'CRIT' THEN 5 WHEN ? = 'WARN' THEN 4 WHEN ? <> 'fresh' OR ? IS NULL THEN 3 WHEN ? = 'UNKNOWN' THEN 2 ELSE 1 END",
            c.active,
            c.health,
            c.health,
            c.knowledge,
            c.health,
            c.health
          ),
        health_rank:
          fragment(
            "CASE ? WHEN 'CRIT' THEN 3 WHEN 'WARN' THEN 2 WHEN 'UNKNOWN' THEN 1 ELSE 0 END",
            c.health
          ),
        freshness_rank:
          fragment(
            "CASE ? WHEN 'unavailable' THEN 3 WHEN 'stale' THEN 2 WHEN 'awaiting' THEN 1 ELSE 0 END",
            c.knowledge
          )
      }
  end

  defp grouped_page(ranked, summaries, page, size, target_id \\ nil) do
    positioned =
      from c in subquery(ranked),
        select_merge: %{
          position:
            over(row_number(),
              partition_by: c.identity,
              order_by: [
                desc: c.urgency,
                desc: c.health_rank,
                desc: c.freshness_rank,
                asc: c.check_label,
                asc: c.result_label,
                asc: c.id
              ]
            )
        }

    # Cross-table text search can make PostgreSQL estimate a single matching
    # result. Do not let that estimate put a complete target aggregate inside
    # the result loop: compute the summaries once before joining the page.
    materialized_summaries =
      from g in "inventory_target_summaries", select: map(g, @target_summary_fields)

    query =
      from [s, a, r] in base_streams(),
        join: c in subquery(positioned),
        on: c.id == s.id,
        join: g in subquery(materialized_summaries),
        on: g.identity == c.identity,
        order_by: [desc: g.urgency, asc: g.label, asc: g.identity, asc: c.position],
        offset: ^((page - 1) * size),
        limit: ^size,
        select: {s, a, r, c.knowledge, g, c.position}

    query = with_cte(query, "inventory_target_summaries", as: ^summaries, materialized: true)

    query =
      if target_id,
        do: from([s, a, r, c, g] in query, where: g.id == ^target_id),
        else: query

    rows = Repo.all(query)
    items = public_streams(Enum.map(rows, fn {s, a, r, k, _, _} -> {s, a, r, k} end))

    groups =
      Enum.zip(rows, items)
      |> Enum.chunk_by(fn {{_, _, _, _, g, _}, _} -> g.identity end)
      |> Enum.map(fn members ->
        {{_, _, _, _, g, first}, _} = hd(members)
        {{_, _, _, _, _, last}, _} = List.last(members)

        Map.merge(public_target(g), %{
          "items" => Enum.map(members, &elem(&1, 1)),
          "first_index" => first,
          "last_index" => last
        })
      end)

    {items, groups}
  end

  defp target_summaries(ranked, f, at, browsing \\ false) do
    inventory =
      base_streams()
      |> stream_filters(Map.take(f, ["status", "environment", "target_scope"]), at)
      |> ranked_streams(at, browsing)

    totals =
      from c in subquery(inventory),
        group_by: c.identity,
        select: %{identity: c.identity, total: count()}

    summaries =
      from c in subquery(ranked),
        group_by: c.identity,
        select: %{
          identity: c.identity,
          label: min(c.target_label),
          environment_label: min(c.environment_label),
          urgency: max(c.urgency),
          total: count(),
          observers: count(c.runner_id, :distinct),
          critical: filter(count(), c.health == "CRIT"),
          warning: filter(count(), c.health == "WARN"),
          unknown: filter(count(), c.health == "UNKNOWN"),
          healthy: filter(count(), c.health == "OK"),
          fresh: filter(count(), c.knowledge == "fresh"),
          stale: filter(count(), c.knowledge == "stale"),
          unavailable: filter(count(), c.knowledge == "unavailable"),
          awaiting: filter(count(), c.knowledge == "awaiting"),
          retired: filter(count(), c.knowledge == "retired")
        }

    from g in subquery(summaries),
      join: inventory in subquery(totals),
      on: inventory.identity == g.identity,
      select_merge: %{
        inventory_total: inventory.total,
        id: browse_identity_id(g.identity)
      }
  end

  defp public_target(g) do
    {source, environment, kind, key, group_key} =
      case g.identity do
        [source, environment, "check-group", key, nil, "group"] ->
          {source, environment, nil, nil, key}

        [source, environment, kind, key, _fallback] ->
          {source, environment, kind, key, nil}
      end

    %{
      "id" => g.id,
      "label" => g.label,
      "source_id" => source,
      "environment" => environment,
      "environment_label" => g.environment_label,
      "group_key" => group_key,
      "is_check_group" => not is_nil(group_key),
      "target_kind" => kind,
      "target_key" => key,
      "total" => g.total,
      "inventory_total" => g.inventory_total,
      "observers" => g.observers,
      "health_counts" => %{
        "CRIT" => g.critical,
        "WARN" => g.warning,
        "UNKNOWN" => g.unknown,
        "OK" => g.healthy
      },
      "knowledge_counts" => %{
        "fresh" => g.fresh,
        "stale" => g.stale,
        "unavailable" => g.unavailable,
        "awaiting" => g.awaiting,
        "retired" => g.retired
      }
    }
  end

  defp stream_filter_counts(f, at) do
    classified =
      base_streams()
      |> stream_filters(Map.drop(f, ["health", "freshness", "attention"]), at)
      |> ranked_streams(at)

    counts =
      Repo.one(
        from c in subquery(classified),
          select: %{
            all: count(),
            attention:
              filter(
                count(),
                c.knowledge != "fresh" or is_nil(c.health) or c.health in ["WARN", "CRIT"]
              ),
            critical: filter(count(), c.health == "CRIT"),
            gaps: filter(count(), c.knowledge != "fresh")
          }
      )

    counts = Map.new(counts, fn {key, count} -> {to_string(key), count} end)

    if unacknowledged?(f) do
      attention =
        base_streams()
        |> stream_filters(
          f |> Map.drop(["health", "freshness"]) |> Map.put("attention", true),
          at
        )
        |> Repo.aggregate(:count)

      Map.put(counts, "attention", attention)
    else
      counts
    end
  end

  defp stream_filters(query, f, at) do
    query =
      case f["status"] do
        "all" -> query
        "retired" -> from([s, a, r] in query, where: not is_nil(s.retired_at))
        _ -> from([s, a, r] in query, where: is_nil(s.retired_at))
      end

    query = assignment_filters(query, f)

    # Unlike `target` (a selected-index preference), this is a hard inventory
    # boundary. Unknown, absent or retired scopes must not fall back elsewhere.
    query =
      cond do
        f["target_scope"] in [nil, ""] ->
          query

        valid_target_scope?(f["target_scope"]) ->
          from([s, a, r] in query,
            where: target_identity_id(target_identity(s, a)) == ^f["target_scope"]
          )

        true ->
          from([s, a, r] in query, where: false)
      end

    query =
      case f["health"] do
        "not_measured" ->
          from([s, a, r] in query,
            where: fragment("?->>'confirmed_observation_id' IS NULL", s.current)
          )

        health when health in ~w(OK WARN CRIT UNKNOWN) ->
          from([s, a, r] in query,
            where: measured_health(s) == ^health
          )

        _ ->
          query
      end

    freshness = f["freshness"]

    query =
      cond do
        freshness == "gaps" ->
          from([s, a, r] in query, where: knowledge(s, a, r, ^at) != "fresh")

        freshness in ~w(fresh stale unavailable awaiting) ->
          from([s, a, r] in query, where: knowledge(s, a, r, ^at) == ^freshness)

        true ->
          query
      end

    query = attention_filter(query, f, at)

    if present?(f["search"]) do
      term = "%" <> escape_like(f["search"]) <> "%"

      from [s, a, r] in query,
        where:
          ilike(a.label, ^term) or ilike(s.label, ^term) or ilike(a.source_key, ^term) or
            ilike(a.source_id, ^term) or ilike(fragment("?->>'label'", s.target), ^term) or
            ilike(fragment("?->>'key'", s.target), ^term) or ilike(r.label, ^term)
    else
      query
    end
  end

  defp unacknowledged?(f), do: f["unacknowledged"] in [true, "true"]

  defp attention_filter(query, f, at) do
    cond do
      f["attention"] not in [true, "true"] ->
        query

      unacknowledged?(f) ->
        health_acknowledgement =
          from i in Incident,
            left_join: group in Mondek.ConditionIncident,
            on: group.id == i.condition_incident_id,
            where:
              i.stream_id == parent_as(:stream).id and i.status == "open" and
                (acknowledgement_active_sql(i, ^at) or
                   acknowledgement_active_sql(group, ^at)),
            select: 1

        # Monitoring-loss ownership belongs to an exact continuous gap, not an
        # entire runner/source or the bounded incident member snapshot. Follow
        # its surviving owner when coverage and runner gaps describe one outage.
        # Before grace elapses or an episode exists, the result remains visible.
        collection_acknowledgement =
          from gap in Mondek.MonitoringGap,
            left_join: owner in Mondek.MonitoringGap,
            on: owner.identity == fragment("(?->>'suppressed_by')::uuid", gap.details),
            join: episode in Mondek.MonitoringIncident,
            on: episode.scope_key == coalesce(owner.scope_key, gap.scope_key),
            where:
              gap.key == fragment("?::text", parent_as(:stream).id) and
                coalesce(owner.ready_at, gap.ready_at) <= ^at and
                acknowledgement_active_sql(episode, ^at),
            select: 1

        # Health and collection are independent problems on one result. A hold
        # on either incident cannot hide an unacknowledged problem of the other.
        from [s, a, r] in query,
          where:
            (measured_health(s) in ["WARN", "CRIT"] and
               not exists(subquery(health_acknowledgement))) or
              ((knowledge(s, a, r, ^at) != "fresh" or is_nil(measured_health(s))) and
                 not exists(subquery(collection_acknowledgement)))

      true ->
        from [s, a, r] in query,
          where:
            knowledge(s, a, r, ^at) != "fresh" or is_nil(measured_health(s)) or
              measured_health(s) in ["WARN", "CRIT"]
    end
  end

  defp assignment_filters(query, f) do
    query =
      if present?(f["runner_id"]) do
        if uuid?(f["runner_id"]),
          do: from([s, a, r] in query, where: a.runner_id == ^f["runner_id"]),
          else: from([s, a, r] in query, where: false)
      else
        query
      end

    if present?(f["environment"]),
      do: from([s, a, r] in query, where: s.environment == ^f["environment"]),
      else: query
  end

  def checks_query(filters) do
    f = normalize(filters)

    query =
      from a in Assignment,
        as: :assignment,
        left_join: r in Runner,
        on: r.id == a.runner_id

    query =
      case f["status"] do
        "all" -> query
        "retired" -> from([a, r] in query, where: not is_nil(a.retired_at))
        _ -> from([a, r] in query, where: is_nil(a.retired_at))
      end

    query =
      if present?(f["runner_id"]) do
        if uuid?(f["runner_id"]),
          do: from([a, r] in query, where: a.runner_id == ^f["runner_id"]),
          else: from([a, r] in query, where: false)
      else
        query
      end

    query =
      if present?(f["environment"]),
        do: from([a, r] in query, where: a.environment == ^f["environment"]),
        else: query

    query =
      if present?(f["search"]) do
        term = "%" <> escape_like(f["search"]) <> "%"

        matching_results =
          from s in ResultStream,
            where: s.assignment_id == parent_as(:assignment).id,
            where: is_nil(s.retired_at) or not is_nil(parent_as(:assignment).retired_at),
            where:
              ilike(s.label, ^term) or ilike(fragment("?->>'label'", s.target), ^term) or
                ilike(fragment("?->>'key'", s.target), ^term),
            select: 1

        from [a, r] in query,
          where:
            ilike(a.label, ^term) or ilike(a.source_key, ^term) or ilike(a.source_id, ^term) or
              exists(subquery(matching_results))
      else
        query
      end

    case configuration_stage_filter(f["configuration_stage"]) do
      nil -> query
      stage -> from([a, r] in query, where: configuration_stage_sql(a) == ^stage)
    end
  end

  def list_checks(filters, at) do
    f = normalize(filters)
    query = checks_query(filters)
    {page, size, total} = page(query, f)

    rows =
      Repo.all(
        from [a, r] in query,
          order_by: [asc: a.label, asc: a.id],
          offset: ^((page - 1) * size),
          limit: ^size,
          select: {a, r, configuration_stage_sql(a)}
      )

    items =
      Enum.map(rows, fn {a, r, stage} ->
        Monitoring.public(a)
        |> Map.merge(%{
          "runner_label" => r && r.label,
          "result_count" => length(a.expected_keys),
          "configuration_stage" => stage
        })
      end)

    global_counts =
      Repo.all(
        from a in Assignment,
          where: is_nil(a.retired_at),
          group_by: configuration_stage_sql(a),
          select: {configuration_stage_sql(a), count(a.id)}
      )
      |> Map.new()

    global_counts = Map.merge(Map.new(@configuration_stages, &{&1, 0}), global_counts)

    scope_total =
      if configuration_stage_filter(f["configuration_stage"]),
        do: Repo.aggregate(checks_query(Map.delete(f, "configuration_stage")), :count),
        else: total

    %{
      items: items,
      total: total,
      page: page,
      page_size: size,
      configuration_summary: %{
        "stage" => configuration_stage_filter(f["configuration_stage"]),
        "scope_total" => scope_total,
        "global_total" => Enum.sum(Map.values(global_counts)),
        "global_counts" => global_counts
      },
      coverage: coverage(at),
      facets: facets()
    }
  end

  defp configuration_stage_filter(stage) when stage in @configuration_stages, do: stage
  defp configuration_stage_filter(_), do: nil

  def list_incidents(filters, at) do
    f = normalize(filters)

    query =
      from i in Incident,
        join: a in Assignment,
        on: a.id == i.assignment_id,
        left_join: s in ResultStream,
        on: s.id == i.stream_id,
        left_join: r in Runner,
        on: r.id == a.runner_id,
        left_join: g in Mondek.ConditionIncident,
        on: g.id == i.condition_incident_id,
        where: is_nil(g.id) or g.status == "closed" or i.status == "open"

    query =
      case f["status"] do
        "all" ->
          query

        "closed" ->
          from([i, a, s, r, g] in query,
            where: fragment("COALESCE(?, ?)", g.status, i.status) == "closed"
          )

        _ ->
          from([i, a, s, r, g] in query,
            where: fragment("COALESCE(?, ?)", g.status, i.status) == "open"
          )
      end

    query =
      if present?(f["runner_id"]) do
        if uuid?(f["runner_id"]),
          do: from([i, a, s, r] in query, where: a.runner_id == ^f["runner_id"]),
          else: from([i, a, s, r] in query, where: false)
      else
        query
      end

    query =
      if f["health"] in ~w(OK WARN CRIT UNKNOWN),
        do:
          from([i, a, s, r, g] in query,
            where: fragment("COALESCE(?, ?)", g.health, i.health) == ^f["health"]
          ),
        else: query

    query =
      if present?(f["environment"]),
        do: from([i, a, s, r] in query, where: i.environment == ^f["environment"]),
        else: query

    query =
      if present?(f["search"]) do
        term = "%" <> escape_like(f["search"]) <> "%"

        from [i, a, s, r, g] in query,
          where:
            ilike(g.label, ^term) or ilike(g.key, ^term) or ilike(g.namespace, ^term) or
              ilike(a.label, ^term) or ilike(s.label, ^term) or ilike(a.source_key, ^term) or
              ilike(a.source_id, ^term) or ilike(fragment("?->>'label'", s.target), ^term) or
              ilike(fragment("?->>'key'", s.target), ^term)
      else
        query
      end

    # Deduplicate exact operator incident identities before pagination. Scope
    # filters match an active contribution of an open group, or retained members
    # of a closed group; severity remains the whole incident's measured severity.
    selected =
      from [i, a, s, r, g] in query,
        distinct: true,
        select: %{
          id: type(fragment("COALESCE(?, ?)", g.id, i.id), :binary_id),
          grouped: not is_nil(g.id),
          health: type(fragment("COALESCE(?, ?)", g.health, i.health), :string),
          status: type(fragment("COALESCE(?, ?)", g.status, i.status), :string),
          acknowledgement_active:
            fragment(
              "CASE WHEN ? IS NULL THEN ? ELSE ? END",
              g.id,
              acknowledgement_active_sql(i, ^at),
              acknowledgement_active_sql(g, ^at)
            ),
          opened_at:
            type(fragment("COALESCE(?, ?)", g.opened_at, i.opened_at), :utc_datetime_usec)
        }

    selected = from(x in subquery(selected))
    {page, size, total} = page(selected, f)

    acknowledged_total =
      Repo.aggregate(from(x in selected, where: x.acknowledgement_active), :count)

    identities =
      Repo.all(
        from x in selected,
          order_by: [
            asc: x.acknowledgement_active,
            desc:
              fragment(
                "CASE ? WHEN 'CRIT' THEN 3 WHEN 'WARN' THEN 2 WHEN 'UNKNOWN' THEN 1 ELSE 0 END",
                x.health
              ),
            asc: fragment("CASE ? WHEN 'open' THEN 0 ELSE 1 END", x.status),
            asc: x.opened_at,
            asc: x.id
          ],
          offset: ^((page - 1) * size),
          limit: ^size
      )

    standalone_ids = for %{grouped: false, id: id} <- identities, do: id
    condition_ids = for %{grouped: true, id: id} <- identities, do: id

    rows =
      Repo.all(
        from [i, a, s, r] in query,
          where: i.id in ^standalone_ids and is_nil(i.condition_incident_id),
          select: {i, a, s, r}
      )

    items =
      Enum.map(rows, fn {i, a, s, r} ->
        Monitoring.public(i)
        |> Map.merge(%{
          "check_label" => a.label,
          "incident_kind" => "result",
          "result_label" => s && s.label,
          "stream_id" => s && s.id,
          "target" => s && s.target,
          "runner_id" => a.runner_id,
          "runner_label" => r && r.label,
          "environment" => i.environment,
          "environment_label" => i.environment_label
        })
      end)

    counts =
      Repo.all(
        from i in Incident,
          join: a in Assignment,
          on: a.id == i.assignment_id,
          where: i.condition_incident_id in ^condition_ids,
          group_by: i.condition_incident_id,
          select:
            {i.condition_incident_id,
             %{
               contributions: count(i.id),
               open_contributions: filter(count(i.id), i.status == "open"),
               results: count(i.stream_id, :distinct),
               observers: count(a.runner_id, :distinct)
             }}
      )
      |> Map.new()

    matches =
      Repo.all(
        from [i, a, s, r, g] in query,
          where: g.id in ^condition_ids,
          group_by: g.id,
          select: {g.id, count(i.stream_id, :distinct)}
      )
      |> Map.new()

    groups =
      Repo.all(from g in Mondek.ConditionIncident, where: g.id in ^condition_ids)
      |> Enum.map(fn group ->
        Monitoring.public(group)
        |> Map.merge(%{
          "incident_kind" => "condition",
          "check_label" => group.label,
          "result_label" => group.label,
          "environment_label" => group.environment,
          "contribution_count" => counts[group.id].contributions,
          "open_contribution_count" => counts[group.id].open_contributions,
          "result_count" => counts[group.id].results,
          "observer_count" => counts[group.id].observers,
          "matching_result_count" => matches[group.id],
          "scope_filtered" => present?(f["runner_id"]) or present?(f["search"])
        })
      end)

    by_id = Map.new(items ++ groups, &{&1["id"], &1})

    items =
      for identity <- identities, item = by_id[identity.id], not is_nil(item) do
        Map.put(item, "acknowledgement_active", identity.acknowledgement_active)
      end

    %{
      items: items,
      total: total,
      acknowledged_total: acknowledged_total,
      unacknowledged_total: total - acknowledged_total,
      page: page,
      page_size: size,
      coverage: coverage(at),
      facets: facets()
    }
  end

  def stream_detail(id, at) do
    if uuid?(id) do
      case Repo.one(
             from [s, a, r] in base_streams(),
               where: s.id == ^id,
               select: {s, a, r, knowledge(s, a, r, ^at)}
           ) do
        {s, a, r, k} -> hd(public_streams([{s, a, r, k}]))
        nil -> nil
      end
    end
  end

  @doc false
  def stream_details(ids, at) do
    ids = ids |> Enum.filter(&uuid?/1) |> Enum.uniq()

    Repo.all(
      from [s, a, r] in base_streams(),
        where: s.id in ^ids,
        select: {s, a, r, knowledge(s, a, r, ^at)}
    )
    |> public_streams()
  end

  def streams_for(assignment_id, at) do
    Repo.all(
      from [s, a, r] in base_streams(),
        where: a.id == ^assignment_id and is_nil(s.retired_at),
        order_by: s.result_key,
        limit: 16,
        select: {s, a, r, knowledge(s, a, r, ^at)}
    )
    |> Enum.map(fn {s, a, r, k} -> hd(public_streams([{s, a, r, k}])) end)
  end

  def stream_inspection(id, at) do
    with stream when not is_nil(stream) <- stream_detail(id, at) do
      assignment_id = stream["assignment_id"]

      incident_query =
        from i in Incident, where: i.stream_id == ^id

      incidents =
        Repo.all(
          from i in incident_query,
            order_by: [desc: i.status, desc: i.opened_at, desc: i.id],
            limit: 100
        )

      ids = Enum.map(incidents, & &1.id)

      control_query =
        from c in Control,
          where:
            c.assignment_id == ^assignment_id and
              ((is_nil(c.incident_id) and is_nil(c.stream_id)) or c.stream_id == ^id or
                 c.incident_id in ^ids)

      controls =
        Repo.all(from c in control_query, order_by: [desc: c.inserted_at, desc: c.id], limit: 100)

      occurrences =
        Repo.all(
          from o in Occurrence,
            where: o.incident_id in ^ids,
            order_by: [desc: o.inserted_at, desc: o.id],
            limit: 100
        )

      references =
        [
          stream["current"]["observation_id"],
          stream["current"]["confirmed_observation_id"]
          | Enum.map(incidents, & &1.closing_observation_id)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      referenced = Repo.all(from o in Observation, where: o.id in ^references)

      recent =
        Repo.all(
          from o in stream_evidence_query(Repo.get!(ResultStream, id)),
            order_by: [desc: o.received_at, desc: o.id],
            limit: 12
        )

      evidence =
        (referenced ++ recent)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.received_at, {:desc, DateTime})

      %{
        "stream" => stream,
        "assignment" => Monitoring.assignment_detail(assignment_id, at),
        "incidents" => Enum.map(incidents, &Monitoring.public/1),
        "controls" => Enum.map(controls, &Monitoring.public/1),
        "occurrences" => Monitoring.inspect_occurrences(occurrences, at),
        "evidence" => Enum.map(evidence, &Monitoring.public/1),
        "limits" => %{
          "incidents" => history_limit(incident_query, incidents, 100),
          "controls" => history_limit(control_query, controls, 100),
          "evidence" => %{
            "referenced" => length(references),
            "missing" => length(references) - length(referenced),
            "recent_limit" => 12
          }
        }
      }
    end
  end

  def stream_evidence_query(stream) do
    query =
      from o in Observation,
        where:
          o.assignment_id == ^stream.assignment_id and
            o.generation >= ^stream.admission_generation

    if stream.retirement_generation,
      do: from(o in query, where: o.generation < ^stream.retirement_generation),
      else: query
  end

  def delivery_inspection(filters, at) do
    filters = normalize(filters)
    status = filters["notification_status"] || "unresolved"

    {status, query} =
      case status do
        "all" ->
          {status, from(o in Occurrence)}

        value when value in ~w(pending retrying delivering exhausted delivered superseded) ->
          {value, from(o in Occurrence, where: o.status == ^value)}

        _ ->
          {"unresolved",
           from(o in Occurrence, where: o.status not in ["delivered", "superseded"])}
      end

    # Count occurrences before reading their attempts. Multiple attempts must not
    # duplicate a notification or change which page an operator is reviewing.
    {page, size, total} =
      page(query, %{"page" => filters["notification_page"], "page_size" => 25})

    ordered =
      if status in ~w(all delivered superseded),
        do: from(o in query, order_by: [desc: o.inserted_at, desc: o.id]),
        else:
          from(o in query,
            order_by: [
              asc:
                fragment(
                  "CASE ? WHEN 'exhausted' THEN 0 WHEN 'retrying' THEN 1 WHEN 'pending' THEN 2 ELSE 3 END",
                  o.status
                ),
              asc: o.inserted_at,
              asc: o.id
            ]
          )

    occurrences = Repo.all(from o in ordered, offset: ^((page - 1) * size), limit: ^size)

    occurrence_ids = Enum.map(occurrences, & &1.id)
    attempt_query = from t in Attempt, where: t.occurrence_id in ^occurrence_ids

    attempts =
      Repo.all(from t in attempt_query, order_by: [desc: t.started_at, desc: t.id], limit: 100)

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "Mondek.NotificationWorker",
          order_by: [desc: j.id],
          limit: 100
      )

    %{
      "occurrences" => Monitoring.inspect_occurrences(occurrences, at),
      "notification_page" => %{
        "status" => status,
        "page" => page,
        "page_size" => size,
        "total" => total
      },
      "attempts" => Enum.map(attempts, &Monitoring.public/1),
      "notification_attempts" => history_limit(attempt_query, attempts, 100),
      "jobs" => Enum.map(jobs, &Monitoring.public/1),
      "notification_backlog" => backlog()
    }
  end

  @doc "Inspect an exact retained notification independently of list filters and page boundaries."
  def notification_detail(id, at) do
    with true <- uuid?(id),
         %Occurrence{} = occurrence <- Repo.get(Occurrence, id),
         [inspected] <- Monitoring.inspect_occurrences([occurrence], at) do
      query = from t in Attempt, where: t.occurrence_id == ^id
      attempts = Repo.all(from t in query, order_by: [desc: t.started_at, desc: t.id], limit: 100)

      jobs =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Mondek.NotificationWorker" and
                fragment("?->>'occurrence_id' = ?", j.args, ^id),
            order_by: [desc: j.id],
            limit: 30
        )

      %{
        "occurrence" => inspected,
        "attempts" => Enum.map(attempts, &Monitoring.public/1),
        "notification_attempts" => history_limit(query, attempts, 100),
        "jobs" => Enum.map(jobs, &Monitoring.public/1)
      }
    else
      _ -> nil
    end
  end

  defp public_streams(rows) do
    predicate =
      Enum.reduce(rows, dynamic(false), fn {s, a, _r, _k}, pred ->
        case s.current["confirmed_generation"] do
          generation when is_integer(generation) ->
            dynamic([c], ^pred or (c.assignment_id == ^a.id and c.generation == ^generation))

          _ ->
            pred
        end
      end)

    configs =
      Repo.all(
        from c in Mondek.Configuration,
          where: ^predicate,
          select: {{c.assignment_id, c.generation}, c.params}
      )
      |> Map.new()

    Enum.map(rows, fn {s, a, r, k} ->
      stream_public(s, a, r, k)
      |> Map.update!(
        "current",
        &Map.put(
          &1,
          "confirmed_params",
          Map.get(configs, {a.id, s.current["confirmed_generation"]})
        )
      )
    end)
  end

  defp stream_public(s, a, r, k) do
    Monitoring.public(s)
    |> Map.merge(%{
      "current" => Map.put(s.current, "knowledge", k),
      "retired" => not is_nil(s.retired_at),
      "check_label" => a.label,
      "runner_id" => a.runner_id,
      "runner_label" => r && r.label,
      "source_key" => a.source_key,
      "source_id" => a.source_id,
      "source_revision" => a.source_revision,
      "definition_revision" => a.definition_revision,
      "environment" => s.environment,
      "environment_label" => s.environment_label,
      "params_owner" => a.params_owner,
      "desired_generation" => a.desired_generation,
      "prepared_generation" => a.prepared_generation,
      "authorized_generation" => a.authorized_generation,
      "active_generation" => a.active_generation,
      "observed_generation" => s.current["confirmed_generation"],
      "retirement_reason" => s.retirement_reason || a.retirement_reason
    })
  end

  defp backlog do
    counts =
      Repo.all(
        from o in Occurrence,
          where: o.status not in ["delivered", "superseded"],
          group_by: o.status,
          select: {o.status, count()}
      )
      |> Map.new()

    total = Enum.sum(Map.values(counts))

    %{
      "total" => total,
      "exhausted" => Map.get(counts, "exhausted", 0),
      "returned" => min(total, 100),
      "omitted" => max(0, total - 100),
      "limit" => 100
    }
  end

  defp history_limit(query, rows, max),
    do: %{
      "total" => Repo.aggregate(query, :count),
      "returned" => length(rows),
      "limit" => max,
      "omitted" => max(0, Repo.aggregate(query, :count) - length(rows))
    }

  defp page(query, f) do
    total = Repo.aggregate(query, :count)
    size = number(f["page_size"], 50, 100)
    page = min(number(f["page"], 1, 1_000_000), max(1, ceil(total / size)))
    {page, size, total}
  end

  defp number(v, default, max) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> number(n, default, max)
      _ -> default
    end
  end

  defp number(v, _default, max) when is_integer(v) and v > 0, do: min(v, max)
  defp number(_, default, _), do: default
  defp normalize(f) when is_map(f), do: Map.new(f, fn {k, v} -> {to_string(k), v} end)
  defp normalize(_), do: %{}

  defp present?(v),
    do:
      is_binary(v) and byte_size(v) in 1..200 and String.valid?(v) and
        not String.contains?(v, <<0>>)

  defp uuid?(v), do: is_binary(v) and byte_size(v) == 36 and match?({:ok, _}, Ecto.UUID.cast(v))

  defp escape_like(v),
    do:
      v
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
end
