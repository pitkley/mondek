# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RunnerFleet do
  @moduledoc """
  Bounded operator inspection of runner transport and published collection.

  `list/2` accepts search, source_id, contact (recent/overdue/never), collection
  (issues/fresh/empty), sort (attention/name/last_contact), page and page_size.
  All filters and ordering run in PostgreSQL before pagination. `counts` covers
  the fleet; `matching_counts` covers the complete filtered set. Both contain
  total, recent, overdue, never, issues, fresh, empty, check_count and coverage.

  Rows contain identity, contact_status, contact_seconds, collection_status,
  check_count, retired_check_count, coverage and sanitized last-reported status.
  Coverage contains active/expected_count, fresh, stale, unavailable and awaiting;
  it never derives target health from contact. Publications expose only source,
  execution context and publication metadata, with complete totals and an explicit
  limit (five on a list row, twenty in `detail/2`). No consumer settings are read.
  """
  import Ecto.Query
  require Mondek.Inspection

  alias Mondek.{Assignment, Inspection, Monitoring, MonitoringLoss, Repo, ResultStream, Runner}
  alias Mondek.SourceInventory

  @coverage_keys ~w(active expected_count fresh stale unavailable awaiting)
  @scheduler_keys ~w(active_checks running_checks max_concurrency due_waiting_checks oldest_due_seconds preparation_pending_checks prepared_waiting_checks)

  def counts(at \\ Monitoring.now()), do: at |> fleet_query() |> summarize()

  def list(filters \\ %{}, at \\ Monitoring.now()) do
    filters = normalize(filters)
    fleet = fleet_query(at)
    query = apply_filters(fleet, filters)
    counts = summarize(fleet)
    matching_counts = summarize(query)
    total = matching_counts["total"]
    size = filters["page_size"]
    page = min(filters["page"], max(1, ceil(total / size)))

    rows =
      query
      |> order(filters["sort"])
      |> offset(^((page - 1) * size))
      |> limit(^size)
      |> Repo.all()
      |> public_rows(5)

    %{
      "items" => rows,
      "total" => total,
      "page" => page,
      "page_size" => size,
      "counts" => counts,
      "matching_counts" => matching_counts,
      "filters" => Map.put(filters, "page", page)
    }
  end

  def detail(id, at \\ Monitoring.now()) do
    if is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)) do
      fleet_query(at)
      |> where([r], r.id == ^id)
      |> Repo.all()
      |> public_rows(20)
      |> List.first()
    end
  end

  def normalize(filters) do
    filters = if is_map(filters), do: filters, else: %{}
    filters = Map.new(filters, fn {key, value} -> {to_string(key), value} end)

    %{
      "search" => input_text(filters["search"], 200),
      "source_id" => input_text(filters["source_id"], 200),
      "contact" => choice(filters["contact"], ~w(all recent overdue never), "all"),
      "collection" => choice(filters["collection"], ~w(all issues fresh empty), "all"),
      "sort" => choice(filters["sort"], ~w(attention name last_contact), "attention"),
      "page" => number(filters["page"], 1, 1_000_000),
      "page_size" => number(filters["page_size"], 25, 50)
    }
  end

  defp fleet_query(at) do
    checks =
      from a in Assignment,
        group_by: a.runner_id,
        select: %{
          runner_id: a.runner_id,
          active: filter(count(), is_nil(a.retired_at)),
          retired: filter(count(), not is_nil(a.retired_at))
        }

    classified =
      from s in ResultStream,
        join: a in Assignment,
        on: a.id == s.assignment_id,
        join: r in Runner,
        on: r.id == a.runner_id,
        where: is_nil(s.retired_at) and is_nil(a.retired_at),
        select: %{runner_id: r.id, knowledge: Inspection.knowledge(s, a, r, ^at)}

    results =
      from s in subquery(classified),
        group_by: s.runner_id,
        select: %{
          runner_id: s.runner_id,
          active: count(),
          fresh: filter(count(), s.knowledge == "fresh"),
          stale: filter(count(), s.knowledge == "stale"),
          unavailable: filter(count(), s.knowledge == "unavailable"),
          awaiting: filter(count(), s.knowledge == "awaiting")
        }

    publications =
      from p in SourceInventory,
        group_by: p.runner_id,
        select: %{
          runner_id: p.runner_id,
          total: count(),
          active: filter(count(), is_nil(p.retired_at))
        }

    cutoff = DateTime.add(at, -MonitoringLoss.contact_seconds())

    summary =
      from r in Runner,
        left_join: a in subquery(checks),
        on: a.runner_id == r.id,
        left_join: s in subquery(results),
        on: s.runner_id == r.id,
        left_join: p in subquery(publications),
        on: p.runner_id == r.id,
        select: %{
          id: r.id,
          label: r.label,
          session_id: r.session_id,
          boot: r.boot,
          last_seen_at: r.last_seen_at,
          status: r.status,
          contact_status:
            fragment(
              "CASE WHEN ? IS NULL THEN 'never' WHEN ? > ?::timestamp THEN 'recent' ELSE 'overdue' END",
              r.last_seen_at,
              r.last_seen_at,
              ^cutoff
            ),
          check_count: coalesce(a.active, 0),
          retired_check_count: coalesce(a.retired, 0),
          expected_count: coalesce(s.active, 0),
          fresh: coalesce(s.fresh, 0),
          stale: coalesce(s.stale, 0),
          unavailable: coalesce(s.unavailable, 0),
          awaiting: coalesce(s.awaiting, 0),
          publication_count: coalesce(p.total, 0),
          active_publication_count: coalesce(p.active, 0),
          collection_status:
            fragment(
              "CASE WHEN COALESCE(?, 0) = 0 THEN 'empty' WHEN ? = ? THEN 'fresh' ELSE 'issues' END",
              s.active,
              s.fresh,
              s.active
            )
        }

    from r in subquery(summary), as: :runner
  end

  defp apply_filters(query, filters) do
    query =
      if filters["search"] != "" do
        term = "%" <> escape_like(filters["search"]) <> "%"

        publication =
          from p in SourceInventory,
            where:
              p.runner_id == parent_as(:runner).id and
                (ilike(p.source_id, ^term) or
                   fragment("?->>'id' ILIKE ?", p.coverage_context, ^term) or
                   fragment("?->>'label' ILIKE ?", p.coverage_context, ^term) or
                   fragment("?->>'local_environment' ILIKE ?", p.coverage_context, ^term)),
            select: 1

        from r in query,
          where:
            ilike(r.label, ^term) or fragment("?::text ILIKE ?", r.id, ^term) or
              exists(subquery(publication))
      else
        query
      end

    query =
      if filters["source_id"] != "" do
        publication =
          from p in SourceInventory,
            where: p.runner_id == parent_as(:runner).id and p.source_id == ^filters["source_id"],
            select: 1

        from r in query, where: exists(subquery(publication))
      else
        query
      end

    query =
      if filters["contact"] == "all",
        do: query,
        else: from(r in query, where: r.contact_status == ^filters["contact"])

    if filters["collection"] == "all",
      do: query,
      else: from(r in query, where: r.collection_status == ^filters["collection"])
  end

  defp order(query, "name"),
    do: from(r in query, order_by: [asc: fragment("lower(?)", r.label), asc: r.id])

  defp order(query, "last_contact"),
    do: from(r in query, order_by: [desc_nulls_last: r.last_seen_at, asc: r.id])

  defp order(query, _) do
    from r in query,
      order_by: [
        desc:
          fragment(
            "CASE WHEN ? = 'issues' OR ? <> 'recent' THEN 1 ELSE 0 END",
            r.collection_status,
            r.contact_status
          ),
        desc: r.unavailable,
        desc: r.stale,
        desc: r.awaiting,
        asc: fragment("lower(?)", r.label),
        asc: r.id
      ]
  end

  defp summarize(query) do
    row =
      Repo.one(
        from r in query,
          select: %{
            total: count(),
            recent: filter(count(), r.contact_status == "recent"),
            overdue: filter(count(), r.contact_status == "overdue"),
            never: filter(count(), r.contact_status == "never"),
            issues: filter(count(), r.collection_status == "issues"),
            fresh: filter(count(), r.collection_status == "fresh"),
            empty: filter(count(), r.collection_status == "empty"),
            check_count: fragment("COALESCE(SUM(?), 0)::bigint", r.check_count),
            expected_count: fragment("COALESCE(SUM(?), 0)::bigint", r.expected_count),
            fresh_results: fragment("COALESCE(SUM(?), 0)::bigint", r.fresh),
            stale: fragment("COALESCE(SUM(?), 0)::bigint", r.stale),
            unavailable: fragment("COALESCE(SUM(?), 0)::bigint", r.unavailable),
            awaiting: fragment("COALESCE(SUM(?), 0)::bigint", r.awaiting)
          }
      )

    row
    |> Map.take(~w(total recent overdue never issues fresh empty check_count)a)
    |> stringify()
    |> Map.put("coverage", coverage(%{row | fresh: row.fresh_results}))
  end

  defp public_rows(rows, publication_limit) do
    ids = Enum.map(rows, & &1.id)
    publications = publications(ids, publication_limit)

    Enum.map(rows, fn row ->
      row
      |> Map.drop(~w(expected_count fresh stale unavailable awaiting)a)
      |> stringify()
      |> Map.merge(%{
        "installation_id" => row.id,
        "last_seen_at" => Monitoring.iso(row.last_seen_at),
        "contact_seconds" => MonitoringLoss.contact_seconds(),
        "coverage" => coverage(row),
        "status" => safe_status(row.status),
        "publications" => Map.get(publications, row.id, []),
        "publication_limit" => publication_limit,
        "publications_omitted" => max(0, row.publication_count - publication_limit)
      })
    end)
  end

  defp publications([], _limit), do: %{}

  defp publications(ids, limit) do
    ranked =
      from p in SourceInventory,
        where: p.runner_id in ^ids,
        select: %{
          id: p.id,
          runner_id: p.runner_id,
          position:
            over(row_number(),
              partition_by: p.runner_id,
              order_by: [asc_nulls_first: p.retired_at, asc: p.source_id, asc: p.id]
            )
        }

    Repo.all(
      from p in SourceInventory,
        join: ranked in subquery(ranked),
        on: p.id == ranked.id,
        where: ranked.position <= ^limit,
        order_by: [asc: p.runner_id, asc: ranked.position],
        select:
          map(p, [
            :runner_id,
            :source_id,
            :revision,
            :source_revision,
            :received_at,
            :retired_at,
            :coverage_context,
            :coverage_confirmed,
            :coverage_received_at
          ])
    )
    |> Enum.group_by(& &1.runner_id, fn p ->
      p
      |> Map.drop([:runner_id, :coverage_context])
      |> stringify()
      |> Map.merge(%{
        "received_at" => Monitoring.iso(p.received_at),
        "retired_at" => Monitoring.iso(p.retired_at),
        "coverage_received_at" => Monitoring.iso(p.coverage_received_at),
        "runner_context" => safe_context(p.coverage_context)
      })
    end)
  end

  defp coverage(row) do
    row = stringify(row)
    row |> Map.take(@coverage_keys) |> Map.put("active", row["expected_count"])
  end

  defp safe_status(status) when is_map(status) do
    counters = Map.new(~w(queue_count queue_bytes dropped), &{&1, counter(status[&1])})
    scheduler = if is_map(status["scheduler"]), do: status["scheduler"], else: %{}

    Map.merge(counters, %{
      "scheduler" => Map.new(@scheduler_keys, &{&1, counter(scheduler[&1])}),
      "running" => running(status["running"]),
      "oldest_at" => timestamp(status["oldest_at"]),
      "diagnostic" => diagnostic(status["diagnostic"])
    })
  end

  defp safe_status(_), do: safe_status(%{})

  defp safe_context(context) when is_map(context),
    do: Map.new(~w(id label local_environment), &{&1, display_text(context[&1], 200)})

  defp safe_context(_), do: %{}

  defp counter(value) when is_number(value) and value >= 0 and value <= 1_000_000_000_000_000,
    do: value

  defp counter(_), do: nil
  defp running(value) when is_list(value), do: length(value)
  defp running(value) when is_map(value), do: map_size(value)
  defp running(value), do: counter(value)

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 100 do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> Monitoring.iso(at)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil
  defp diagnostic(value) when value in [nil, "", %{}, []], do: nil
  defp diagnostic(value) when is_binary(value), do: display_text(value, 2_000)

  defp diagnostic(value) do
    case Jason.encode(value) do
      {:ok, value} -> display_text(value, 2_000)
      _ -> nil
    end
  end

  defp display_text(value, limit) when is_binary(value) do
    if String.valid?(value), do: String.slice(String.replace(value, <<0>>, ""), 0, limit)
  end

  defp display_text(_, _), do: nil

  defp input_text(value, limit) when is_binary(value) do
    if byte_size(value) <= limit and String.valid?(value) and not String.contains?(value, <<0>>),
      do: String.trim(value),
      else: ""
  end

  defp input_text(_, _), do: ""
  defp choice(value, choices, fallback), do: if(value in choices, do: value, else: fallback)

  defp number(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> number(n, default, max)
      _ -> default
    end
  end

  defp number(value, _, max) when is_integer(value) and value > 0, do: min(value, max)
  defp number(_, default, _), do: default
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp escape_like(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
end
