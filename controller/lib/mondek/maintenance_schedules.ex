# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceSchedules do
  @moduledoc "Reviewed recurring series, materialized as ordinary notification windows."
  import Ecto.Query
  import Kernel, except: [apply: 2, apply: 3]

  alias Mondek.{
    Maintenance,
    MaintenanceEvent,
    MaintenanceWindow,
    MaintenanceSeries,
    MaintenanceSeriesEvent,
    MaintenanceRecurrence,
    MaintenanceTime,
    Monitoring,
    Repo
  }

  @limit 25
  @max_overlaps 1024
  @scope_fields ~w(scope assignment_id source_id environment target_kind target_key selections)

  def preview(proposal, occurrence_page \\ 1, result_page \\ 1, at \\ nil, token \\ nil) do
    Repo.transaction(fn ->
      Maintenance.lock!(:shared)
      prior = if token, do: verify!(token, "create")
      {p, scope, rows, expanded} = prepare!(proposal, false)
      check_proposal!(prior, p)
      at = at || Monitoring.now()
      future!(expanded["windows"], at)

      windows =
        if prior,
          do: prior["windows"],
          else: Enum.map(expanded["windows"], &Map.put(&1, "id", Ecto.UUID.generate()))

      {windows, overlaps} = overlaps(scope, windows, rows)
      state = Maintenance.series_state(rows, overlaps)
      if prior && prior["state"] != state, do: Repo.rollback(:review_changed)

      review = %{
        "action" => "create",
        "id" => (prior && prior["id"]) || Ecto.UUID.generate(),
        "proposal" => fingerprint(p),
        "state" => state,
        "windows" => windows,
        "timezone_version" => expanded["timezone_version"]
      }

      occurrence_page = page(occurrence_page)
      result_page = page(result_page)

      %{
        "proposal" => p,
        "recurrence" => p["recurrence"],
        "timezone" => p["timezone"],
        "review_token" => token || sign(review),
        "timezone_version" => expanded["timezone_version"],
        "first_starts_at" => hd(windows)["starts_at"],
        "final_ends_at" => List.last(windows)["ends_at"],
        "occurrences" => slice(windows, occurrence_page),
        "occurrence_total" => length(windows),
        "occurrence_page" => occurrence_page,
        "occurrence_pages" => pages(length(windows)),
        "rows" => slice(rows, result_page),
        "result_page" => result_page,
        "result_total" => length(rows),
        "result_pages" => pages(length(rows)),
        "page_size" => @limit,
        "counts" => %{
          "matched_results" => length(rows),
          "matched_checks" => rows |> Enum.map(& &1["assignment_id"]) |> Enum.uniq() |> length()
        },
        "selection_summary" => Maintenance.series_selection_summary(scope, rows),
        "overlaps" => Enum.take(overlaps, @limit) |> Enum.map(&Maintenance.reference/1),
        "overlap_total" => length(overlaps),
        "overlap_omitted" => max(0, length(overlaps) - @limit)
      }
    end)
  end

  def apply(token, proposal, at \\ nil) do
    result =
      Repo.transaction(fn ->
        review = verify!(token, "create")
        Maintenance.lock!()
        {p, scope, rows, expanded} = prepare!(proposal, true)
        check_proposal!(review, p)
        if Repo.get(MaintenanceSeries, review["id"]), do: Repo.rollback(:review_changed)
        at = at || Monitoring.now()
        future!(expanded["windows"], at)
        {windows, overlaps} = overlaps(scope, review["windows"], rows)

        if Maintenance.series_state(rows, overlaps) != review["state"],
          do: Repo.rollback(:review_changed)

        verify!(token, "create")

        series = create!(review["id"], p, windows, expanded["timezone_version"], at)
        Maintenance.series_wake!(scope)
        detail(series, %{}, at)
      end)

    Monitoring.notify()
    result
  end

  @doc false
  def managed_preview!(proposal, at) do
    {canonical, scope, rows, expanded} = prepare!(proposal, false)
    future!(expanded["windows"], at)
    {windows, overlaps} = overlaps(scope, expanded["windows"], rows)

    %{
      proposal: canonical,
      scope: scope,
      rows: rows,
      windows: windows,
      version: expanded["timezone_version"],
      impact: %{
        "dates" => windows,
        "matches" => length(rows),
        "sample_results" => Enum.take(rows, 25),
        "overlaps" => Enum.map(overlaps, &Maintenance.reference/1),
        "state" => Maintenance.series_state(rows, overlaps),
        "timezone_version" => expanded["timezone_version"]
      }
    }
  end

  @doc false
  def managed_create!(prepared, owner, at) do
    windows = Enum.map(prepared.windows, &Map.put(&1, "id", Ecto.UUID.generate()))
    create!(Ecto.UUID.generate(), prepared.proposal, windows, prepared.version, at, owner)
  end

  @doc false
  def managed_retirement!(series, at) do
    upcoming =
      Repo.all(
        from w in children(series.id),
          where: w.revision == 1 and is_nil(w.cancelled_at) and w.starts_at > ^at,
          limit: 129
      )

    if length(upcoming) > 128,
      do: invalid!("This maintenance project exceeds the reviewed window limit.")

    protection =
      protected_windows(from(w in MaintenanceWindow, where: w.series_id == ^series.id), at)

    %{
      series: series,
      scope: scope_window(series),
      upcoming: upcoming,
      impact: %{
        "series_id" => series.id,
        "revision" => series.revision,
        "next_index" => series.next_index,
        "stops_generation" => generating?(series),
        "cancel" => Enum.map(upcoming, &%{"id" => &1.id, "revision" => &1.revision}),
        "preserve" => Enum.map(protection.windows, & &1["id"]),
        "preserve_through" => Monitoring.iso(protection.through)
      }
    }
  end

  @doc false
  def managed_protection!(project, key, at) do
    history =
      from e in MaintenanceSeriesEvent,
        where:
          e.kind == "created" and fragment("?->>'project' = ?", e.snapshot, ^project) and
            fragment("?->>'key' = ?", e.snapshot, ^key),
        select: e.series_id

    protected_windows(
      from(w in MaintenanceWindow, where: w.series_id in subquery(history)),
      at
    )
  end

  defp protected_windows(query, at) do
    rows =
      Repo.all(
        from w in query,
          join: e in MaintenanceEvent,
          on: e.window_id == w.id and e.revision == 1,
          where:
            (is_nil(w.cancelled_at) and w.starts_at <= ^at and w.ends_at > ^at) or
              (w.revision > 1 and
                 (w.ends_at > ^at or
                    fragment("(?->>'ends_at')::timestamptz > ?", e.snapshot, ^at)) and
                 fragment(
                   """
                   NOT EXISTS (
                     SELECT 1 FROM maintenance_series_events retired
                     WHERE retired.series_id = ? AND retired.kind = 'upcoming_cancelled'
                       AND retired.snapshot->>'project' IS NOT NULL
                       AND retired.snapshot->'window_ids' @> jsonb_build_array(?::text)
                   )
                   """,
                   w.series_id,
                   w.id
                 )),
          order_by: [w.series_id, w.series_index],
          limit: 129,
          select: {w.id, w.revision, w.ends_at, fragment("?->>'ends_at'", e.snapshot)}
      )

    if length(rows) > 128,
      do: invalid!("This maintenance project exceeds its protected window limit.")

    through =
      rows
      |> Enum.flat_map(fn {_, _, current_end, original_end} ->
        [current_end, parse(original_end)]
      end)
      |> Enum.max(DateTime, fn -> nil end)

    %{
      through: through,
      windows:
        Enum.map(rows, fn {id, revision, _, _} -> %{"id" => id, "revision" => revision} end)
    }
  end

  @doc false
  def managed_retire!(plan, reason, owner, at) do
    series = plan.series
    cancelled = Enum.map(plan.upcoming, &Maintenance.cancel_series_window!(&1, reason, at))
    attrs = %{revision: series.revision + 1, updated_at: at}

    attrs =
      if generating?(series),
        do: Map.merge(attrs, %{refill_at: nil, generation_stopped_at: at}),
        else: attrs

    series = Monitoring.change(series, attrs)

    event!(
      series,
      "upcoming_cancelled",
      reason,
      Map.merge(owner, %{
        "window_ids" => Enum.map(cancelled, & &1.id),
        "count" => length(cancelled)
      }),
      at
    )
  end

  defp create!(id, proposal, windows, version, at, owner \\ %{}) do
    series =
      %MaintenanceSeries{
        id: id,
        revision: 1,
        name: proposal["name"],
        reason: proposal["reason"],
        actor: "Local operator",
        proposal: proposal,
        resolved_windows: windows,
        tzdata_version: version,
        inserted_at: at,
        updated_at: at
      }
      |> start_generation(windows)
      |> Repo.insert!()

    ordinary = Map.delete(proposal, "recurrence")
    children = Enum.map(windows, &Maintenance.insert_series_window!(ordinary, &1, series.id, at))

    event!(
      series,
      "created",
      series.reason,
      Map.merge(owner, %{"window_ids" => Enum.map(children, & &1.id), "count" => length(children)}),
      at
    )

    series
  end

  def get(id, params \\ %{}, at \\ Monitoring.now()) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
      Maintenance.lock!(:shared)
      series = find!(id)
      detail(series, if(is_map(params), do: params, else: %{}), at)
    end)
  end

  @doc false
  def child_spec(_),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}

  @doc false
  def start_link(_) do
    refill_before_dispatch(Monitoring.now())
    :ignore
  end

  defp refill_before_dispatch(at) do
    if refill_due(at) == @limit, do: refill_before_dispatch(at)
  end

  @doc "Materialize a bounded batch of due rules under the dispatch and cancellation lock."
  def refill_due(at) do
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    ids =
      Repo.all(
        from s in MaintenanceSeries,
          where: s.refill_at <= ^at,
          order_by: [asc: s.refill_at, asc: s.id],
          limit: @limit,
          select: s.id
      )

    Enum.each(ids, fn id ->
      {:ok, _} =
        Repo.transaction(fn ->
          Maintenance.lock!()

          case Repo.get(MaintenanceSeries, id) do
            %{refill_at: %DateTime{} = refill_at} = series ->
              if DateTime.compare(refill_at, at) != :gt, do: refill!(series, at)

            _ ->
              :ok
          end
        end)
    end)

    length(ids)
  end

  defp start_generation(%{proposal: %{"recurrence" => %{"end_mode" => "open"}}} = series, windows) do
    %{
      series
      | next_index: length(windows) + 1,
        refill_at: parse(hd(windows)["starts_at"]),
        generated_through_at: parse(List.last(windows)["ends_at"])
    }
  end

  defp start_generation(series, _windows), do: series

  defp refill!(series, at) do
    scope = scope_window(series)
    Maintenance.series_lock_scope!(scope)

    {windows, next_index, previous_end, issue} =
      MaintenanceRecurrence.extend(
        series.proposal,
        series.next_index,
        series.generated_through_at,
        at
      )

    ordinary = Map.delete(series.proposal, "recurrence")

    Enum.each(windows, fn window ->
      window = Map.put(window, "id", Ecto.UUID.generate())
      Maintenance.insert_series_window!(ordinary, window, series.id, at)
    end)

    Monitoring.change(series, %{
      next_index: next_index,
      generated_through_at: previous_end,
      generation_issue: issue,
      refill_at: if(is_nil(issue), do: DateTime.add(at, 1, :day)),
      updated_at: at
    })

    if windows != [], do: Maintenance.series_wake!(scope)
  end

  def cancel_preview(id, revision, reason, page_number \\ 1, at \\ nil, token \\ nil) do
    Repo.transaction(fn ->
      Maintenance.lock!(:shared)
      note!(reason)
      series = find!(id)
      if series.revision != revision, do: Repo.rollback(:stale)
      at = at || Monitoring.now()
      upcoming = upcoming_children(id, at)
      stops_generation? = generating?(series)

      if upcoming == [] and not stops_generation?,
        do:
          invalid!(
            "This series has no upcoming windows to cancel. Active windows must be ended individually."
          )

      review = cancellation_review(series, upcoming, reason)
      if token && verify!(token, "cancel") != review, do: Repo.rollback(:review_changed)
      page_number = page(page_number)

      %{
        "id" => series.id,
        "revision" => series.revision,
        "name" => series.name,
        "reason" => reason,
        "timezone" => series.proposal["timezone"],
        "review_token" => token || sign(review),
        "stops_generation" => stops_generation?,
        "upcoming_count" => length(upcoming),
        "active_count" =>
          window_counts([id], at) |> Map.get(id, empty_counts()) |> Map.fetch!(:active),
        "rows" => child_public_rows(slice(upcoming, page_number), at),
        "page" => page_number,
        "pages" => pages(length(upcoming)),
        "total" => length(upcoming),
        "page_size" => @limit
      }
    end)
  end

  def cancel(id, token, reason, at \\ nil) do
    result =
      Repo.transaction(fn ->
        review = verify!(token, "cancel")
        Maintenance.lock!()
        note!(reason)
        series = find!(id)
        Maintenance.series_lock_scope!(scope_window(series))
        at = at || Monitoring.now()
        upcoming = upcoming_children(id, at)

        if cancellation_review(series, upcoming, reason) != review,
          do: Repo.rollback(:review_changed)

        verify!(token, "cancel")
        cancelled = Enum.map(upcoming, &Maintenance.cancel_series_window!(&1, reason, at))
        attrs = %{revision: series.revision + 1, updated_at: at}

        attrs =
          if generating?(series),
            do: Map.merge(attrs, %{refill_at: nil, generation_stopped_at: at}),
            else: attrs

        series = Monitoring.change(series, attrs)

        event!(
          series,
          "upcoming_cancelled",
          reason,
          %{"window_ids" => Enum.map(cancelled, & &1.id), "count" => length(cancelled)},
          at
        )

        # Every member has the same immutable scope; one wake preserves existing
        # occurrence, payload, job and retry-budget identities.
        Maintenance.series_wake!(scope_window(series))
        detail(series, %{}, at)
      end)

    Monitoring.notify()
    result
  end

  @doc false
  def child_changed!(%{series_id: nil}, _, _, _), do: :ok

  def child_changed!(window, kind, reason, at) do
    # Ordinary window mutations already hold the exclusive maintenance gate.
    series = find!(window.series_id)
    series = Monitoring.change(series, %{revision: series.revision + 1, updated_at: at})

    event!(
      series,
      kind,
      reason,
      %{
        "window_id" => window.id,
        "index" => window.series_index,
        "window_revision" => window.revision,
        "starts_at" => Monitoring.iso(window.starts_at),
        "ends_at" => Monitoring.iso(window.ends_at),
        "cancelled_at" => Monitoring.iso(window.cancelled_at)
      },
      at
    )
  end

  @doc false
  def list(params, at) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        list_snapshot(params, at)
      end)

    result
  end

  defp list_snapshot(params, at) do
    params = if is_map(params), do: params, else: %{}
    history? = params["status"] == "history"
    selectors = Maintenance.series_list_selectors(params)
    ordinary = Maintenance.series_list_query(params, at, selectors)

    ordinary =
      from w in ordinary,
        where: is_nil(w.series_id),
        select: %{
          id: w.id,
          kind: fragment("'window'::text"),
          sort_at:
            fragment(
              "CASE WHEN ? THEN COALESCE(?,?) ELSE ? END",
              ^history?,
              w.cancelled_at,
              w.ends_at,
              w.starts_at
            )
        }

    matching = Maintenance.series_list_query(Map.put(params, "status", "all"), at, selectors)
    search = if is_binary(params["search"]), do: params["search"], else: ""
    scope = if params["scope"] in ~w(check target selection), do: params["scope"]

    scope_match = parent_scope_match(selectors)

    parent_match =
      dynamic(
        [s],
        not is_nil(s.next_index) and ^scope_match and
          fragment(
            "strpos(lower(concat_ws(' ', ?, ?)), lower(?)) > 0",
            s.name,
            s.reason,
            ^search
          ) and
          (^is_nil(scope) or fragment("?->>'scope'", s.proposal) == ^(scope || ""))
      )

    series =
      from s in MaintenanceSeries,
        left_join: w in MaintenanceWindow,
        on: w.series_id == s.id,
        where:
          s.id in subquery(
            from m in matching, where: not is_nil(m.series_id), select: m.series_id
          ),
        or_where: ^parent_match,
        group_by: s.id,
        select: %{
          id: s.id,
          kind: fragment("'series'::text"),
          sort_at:
            fragment(
              "CASE WHEN ? THEN COALESCE(max(COALESCE(?,?)),?) ELSE COALESCE(min(?) FILTER (WHERE ? IS NULL AND ?>?),max(?),?) END",
              ^history?,
              w.cancelled_at,
              w.ends_at,
              s.updated_at,
              w.starts_at,
              w.cancelled_at,
              w.ends_at,
              ^at,
              w.starts_at,
              s.updated_at
            )
        }

    series =
      case params["status"] do
        "all" ->
          series

        "history" ->
          from [s, w] in series,
            having:
              (is_nil(s.next_index) or not is_nil(s.generation_stopped_at)) and
                fragment(
                  "count(*) FILTER (WHERE ? IS NULL AND ?>?)=0",
                  w.cancelled_at,
                  w.ends_at,
                  ^at
                )

        _ ->
          from [s, w] in series,
            having:
              (not is_nil(s.next_index) and is_nil(s.generation_stopped_at)) or
                fragment(
                  "count(*) FILTER (WHERE ? IS NULL AND ?>?)>0",
                  w.cancelled_at,
                  w.ends_at,
                  ^at
                )
      end

    union = union_all(ordinary, ^series)
    matches = from(e in subquery(union))

    matches =
      if params["kind"] in ["window", "series"],
        do: from(e in matches, where: e.kind == ^params["kind"]),
        else: matches

    total = Repo.aggregate(matches, :count)
    page_number = min(page(params["page"]), max(1, ceil(total / @limit)))
    entries = from e in matches, limit: @limit, offset: ^((page_number - 1) * @limit)

    entries =
      if history?,
        do: from(e in entries, order_by: [desc: e.sort_at, desc: e.id]),
        else: from(e in entries, order_by: [asc: e.sort_at, asc: e.id])

    entries = Repo.all(entries)
    window_ids = for %{kind: "window", id: id} <- entries, do: id
    series_ids = for %{kind: "series", id: id} <- entries, do: id

    windows =
      Repo.all(from w in MaintenanceWindow, where: w.id in ^window_ids) |> Map.new(&{&1.id, &1})

    parents =
      Repo.all(
        from s in MaintenanceSeries,
          where: s.id in ^series_ids,
          select: %MaintenanceSeries{
            id: s.id,
            revision: s.revision,
            name: s.name,
            reason: s.reason,
            actor: s.actor,
            next_index: s.next_index,
            generation_stopped_at: s.generation_stopped_at,
            generation_issue: s.generation_issue,
            inserted_at: s.inserted_at,
            updated_at: s.updated_at,
            proposal:
              fragment(
                "jsonb_build_object('timezone',?->'timezone','recurrence',?->'recurrence','scope',?->'scope','selection_count',jsonb_array_length(?->'selections'),'assignment_id',?->'assignment_id','source_id',?->'source_id','environment',?->'environment','target_kind',?->'target_kind','target_key',?->'target_key')",
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal,
                s.proposal
              )
          }
      )
      |> Map.new(&{&1.id, &1})

    check_ids =
      for {_id, parent} <- parents,
          parent.proposal["scope"] == "check",
          do: parent.proposal["assignment_id"]

    labels =
      Repo.all(
        from a in Mondek.Assignment,
          left_join: r in Mondek.Runner,
          on: r.id == a.runner_id,
          where: a.id in ^check_ids,
          select: {a.id, %{"check_label" => a.label, "runner_label" => r.label}}
      )
      |> Map.new()

    parents =
      Map.new(parents, fn {id, parent} ->
        {id,
         %{
           parent
           | proposal: Map.merge(parent.proposal, labels[parent.proposal["assignment_id"]] || %{})
         }}
      end)

    counts = window_counts(series_ids, at)

    public =
      Enum.map(entries, fn
        %{kind: "window", id: id} -> Maintenance.public_window(windows[id], at)
        %{kind: "series", id: id} -> summary(parents[id], Map.get(counts, id, empty_counts()))
      end)

    %{
      "windows" => public,
      "page" => page_number,
      "page_size" => @limit,
      "total" => total,
      "pages" => pages(total)
    }
  end

  defp parent_scope_match(nil), do: dynamic(true)

  defp parent_scope_match(selectors) do
    dynamic(
      [s],
      fragment(
        """
        CASE WHEN ?->>'scope'='selection'
        THEN ARRAY(SELECT jsonb_array_elements(?->'selections')) && ?
        ELSE maintenance_selections_match(?, ?->>'assignment_id', ?->>'source_id',
                                         ?->>'environment', ?->>'target_kind', ?->>'target_key')
        END
        """,
        s.proposal,
        s.proposal,
        type(^selectors, {:array, :map}),
        type(^selectors, {:array, :map}),
        s.proposal,
        s.proposal,
        s.proposal,
        s.proposal,
        s.proposal
      )
    )
  end

  defp prepare!(proposal, lock?) when is_map(proposal) do
    {recurrence, ordinary} = Map.pop(proposal, "recurrence")
    {p, scope, rows} = Maintenance.series_scope!(ordinary, lock?)

    case MaintenanceRecurrence.expand(p, recurrence) do
      {:ok, expanded} ->
        # Each ordinary window and its original event retain the immutable
        # intent. Bound the combined materialization, not just the HTTP body.
        bytes =
          byte_size(Jason.encode!(p)) * length(expanded["windows"]) * 2 +
            byte_size(Jason.encode!(expanded))

        if bytes > 8_388_608,
          do:
            invalid!(
              "This series exceeds the 8 MiB materialized-scope limit. Use fewer dates or a smaller explicit selection."
            )

        {Map.put(p, "recurrence", expanded["recurrence"]), scope, rows, expanded}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp prepare!(_, _), do: invalid!("Supply a recurring maintenance proposal.")

  defp overlaps(scope, windows, rows) do
    {windows, indexed} =
      Enum.map_reduce(windows, %{}, fn w, indexed ->
        candidate = %{scope | starts_at: parse(w["starts_at"]), ends_at: parse(w["ends_at"])}
        overlaps = Maintenance.series_overlaps(candidate, rows)
        indexed = Enum.reduce(overlaps, indexed, &Map.put(&2, &1.id, &1))

        if map_size(indexed) > @max_overlaps,
          do:
            invalid!(
              "A series review supports at most #{@max_overlaps} overlapping windows. Narrow its scope or date range."
            )

        {Map.merge(w, %{
           "elapsed_seconds" =>
             DateTime.diff(candidate.ends_at, candidate.starts_at, :microsecond) / 1_000_000,
           "overlap_count" => length(overlaps)
         }), indexed}
      end)

    {windows, indexed |> Map.values() |> Enum.sort_by(& &1.id)}
  end

  defp detail(series, params, at) do
    counts = window_counts([series.id], at) |> Map.get(series.id, empty_counts())
    occurrence_page = min(page(params["occurrence_page"]), pages(counts.total))
    result_page = page(params["result_page"])
    inspection = Maintenance.series_inspection(scope_window(series), result_page)

    windows =
      Repo.all(
        from w in children(series.id), limit: @limit, offset: ^((occurrence_page - 1) * @limit)
      )

    event_query = from e in MaintenanceSeriesEvent, where: e.series_id == ^series.id
    history_count = Repo.aggregate(event_query, :count)
    history_page = min(page(params["history_page"]), pages(history_count))

    events =
      Repo.all(
        from e in event_query,
          order_by: [desc: e.revision],
          limit: @limit,
          offset: ^((history_page - 1) * @limit)
      )

    scope_labels =
      if series.proposal["scope"] == "check",
        do:
          Map.take(
            List.first(inspection["selection_summary"]) || %{},
            ~w(check_label runner_label)
          ),
        else: %{}

    summary(series, counts)
    |> Map.merge(scope_labels)
    |> Map.merge(%{
      "proposal" => series.proposal,
      "recurrence" => series.proposal["recurrence"],
      "timezone_version" => series.tzdata_version,
      "occurrences" => child_public_rows(windows, at),
      "occurrence_page" => occurrence_page,
      "occurrence_pages" => pages(counts.total),
      "occurrence_total" => counts.total,
      "rows" => inspection["rows"],
      "result_page" => result_page,
      "result_total" => inspection["total"],
      "result_pages" => pages(inspection["total"]),
      "selection_summary" => inspection["selection_summary"],
      "counts" => %{
        "matched_results" => inspection["total"],
        "matched_checks" => inspection["matched_checks"]
      },
      "page_size" => @limit,
      "history" => Enum.map(events, &Monitoring.public/1),
      "history_count" => history_count,
      "history_page" => history_page,
      "history_pages" => pages(history_count)
    })
  end

  defp window_counts(ids, at) do
    Repo.all(
      from w in MaintenanceWindow,
        where: w.series_id in ^ids,
        group_by: w.series_id,
        select:
          {w.series_id,
           %{
             total: count(w.id),
             active:
               filter(
                 count(w.id),
                 is_nil(w.cancelled_at) and w.starts_at <= ^at and w.ends_at > ^at
               ),
             upcoming: filter(count(w.id), is_nil(w.cancelled_at) and w.starts_at > ^at),
             cancelled: filter(count(w.id), not is_nil(w.cancelled_at)),
             next: filter(min(w.starts_at), is_nil(w.cancelled_at) and w.starts_at > ^at),
             final: max(w.ends_at)
           }}
    )
    |> Map.new()
  end

  defp empty_counts, do: %{total: 0, active: 0, upcoming: 0, cancelled: 0, next: nil, final: nil}

  defp generating?(series),
    do: not is_nil(series.next_index) and is_nil(series.generation_stopped_at)

  defp summary(series, counts) do
    ended = counts.total - counts.active - counts.upcoming - counts.cancelled

    status =
      cond do
        counts.active > 0 -> "active"
        counts.upcoming > 0 and ended == 0 -> "upcoming"
        counts.upcoming > 0 or generating?(series) -> "between"
        counts.cancelled == counts.total -> "cancelled"
        true -> "completed"
      end

    %{
      "kind" => "series",
      "id" => series.id,
      "revision" => series.revision,
      "name" => series.name,
      "reason" => series.reason,
      "actor" => series.actor,
      "status" => status,
      "timezone" => series.proposal["timezone"],
      "scope" => series.proposal["scope"],
      "assignment_id" => series.proposal["assignment_id"],
      "check_label" => series.proposal["check_label"],
      "runner_label" => series.proposal["runner_label"],
      "source_id" => series.proposal["source_id"],
      "environment" => series.proposal["environment"],
      "target_kind" => series.proposal["target_kind"],
      "target_key" => series.proposal["target_key"],
      "selection_count" =>
        series.proposal["selection_count"] || length(series.proposal["selections"] || []),
      "recurrence" => series.proposal["recurrence"],
      "generation_enabled" => generating?(series),
      "generation_issue" => series.generation_issue,
      "generation_stopped_at" => Monitoring.iso(series.generation_stopped_at),
      "active_count" => counts.active,
      "upcoming_count" => counts.upcoming,
      "ended_count" => ended,
      "cancelled_count" => counts.cancelled,
      "remaining_count" => counts.active + counts.upcoming,
      "occurrence_total" => counts.total,
      "next_starts_at" => Monitoring.iso(counts.next),
      "final_ends_at" => Monitoring.iso(counts.final),
      "inserted_at" => Monitoring.iso(series.inserted_at),
      "updated_at" => Monitoring.iso(series.updated_at)
    }
  end

  defp child_public_rows(windows, at) do
    ids = Enum.map(windows, & &1.id)

    originals =
      Repo.all(
        from e in MaintenanceEvent,
          where: e.window_id in ^ids and e.revision == 1 and e.kind == "created",
          select:
            {e.window_id,
             fragment(
               "jsonb_build_object('starts_local',?->'starts_local','ends_local',?->'ends_local','starts_at',?->'starts_at','ends_at',?->'ends_at')",
               e.snapshot,
               e.snapshot,
               e.snapshot,
               e.snapshot
             )}
      )
      |> Map.new()

    Enum.map(windows, &child_public(&1, originals[&1.id] || %{}, at))
  end

  defp child_public(window, original, at) do
    Maintenance.public_window(window, at)
    |> Map.drop(@scope_fields)
    |> Map.merge(%{
      "index" => window.series_index,
      "original_starts_local" => original["starts_local"],
      "original_ends_local" => original["ends_local"],
      "original_starts_at" => original["starts_at"],
      "original_ends_at" => original["ends_at"],
      "elapsed_seconds" =>
        DateTime.diff(window.ends_at, window.starts_at, :microsecond) / 1_000_000
    })
  end

  defp cancellation_review(series, upcoming, reason),
    do: %{
      "action" => "cancel",
      "id" => series.id,
      "revision" => series.revision,
      "reason" => reason,
      "children" => fingerprint(Enum.map(upcoming, &{&1.id, &1.revision}))
    }

  defp upcoming_children(id, at) do
    Repo.all(from w in children(id), where: is_nil(w.cancelled_at) and w.starts_at > ^at)
  end

  defp children(id),
    do:
      from(w in MaintenanceWindow,
        where: w.series_id == ^id,
        order_by: w.series_index,
        select:
          struct(w, [
            :id,
            :series_id,
            :series_index,
            :revision,
            :name,
            :reason,
            :actor,
            :timezone,
            :tzdata_version,
            :starts_local,
            :ends_local,
            :start_fold,
            :end_fold,
            :starts_at,
            :ends_at,
            :cancelled_at,
            :cancelled_by,
            :cancellation_reason,
            :inserted_at,
            :updated_at
          ])
      )

  defp scope_window(series),
    do:
      struct(
        MaintenanceWindow,
        Map.new(@scope_fields, &{String.to_existing_atom(&1), series.proposal[&1]})
      )

  defp future!(windows, at) do
    if Enum.any?(windows, &(DateTime.compare(parse(&1["starts_at"]), at) != :gt)),
      do:
        invalid!(
          "Every series occurrence must start in the future. Choose a new first date and review again."
        )
  end

  defp check_proposal!(nil, _), do: :ok

  defp check_proposal!(review, p) do
    if review["proposal"] != fingerprint(p) or
         review["timezone_version"] != MaintenanceTime.version(),
       do: Repo.rollback(:review_changed)
  end

  defp find!(id),
    do:
      if(is_binary(id) and byte_size(id) == 36 and match?({:ok, _}, Ecto.UUID.cast(id)),
        do: Repo.get(MaintenanceSeries, id)
      ) || Repo.rollback(:not_found)

  defp event!(series, kind, reason, snapshot, at),
    do:
      Repo.insert!(%MaintenanceSeriesEvent{
        series_id: series.id,
        revision: series.revision,
        kind: kind,
        actor: "Local operator",
        reason: reason,
        snapshot: snapshot,
        inserted_at: at
      })

  defp note!(reason) do
    if not is_binary(reason) or byte_size(reason) not in 1..500 or not String.valid?(reason) or
         String.trim(reason) == "" or String.match?(reason, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/),
       do: invalid!("Supply a nonblank reason of at most 500 bytes.")
  end

  defp sign(review),
    do: Phoenix.Token.sign(MondekWeb.Endpoint, "maintenance-series-review", review)

  defp verify!(token, action) when is_binary(token) and byte_size(token) < 65_536 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "maintenance-series-review", token,
           max_age: 900
         ) do
      {:ok, %{"action" => ^action} = review} -> review
      {:error, :expired} -> Repo.rollback(:review_expired)
      _ -> Repo.rollback(:invalid_review)
    end
  end

  defp verify!(_, _), do: Repo.rollback(:invalid_review)

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)

  defp parse(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> page(n)
      _ -> 1
    end
  end

  defp page(value) when is_integer(value), do: min(100_000, max(1, value))
  defp page(_), do: 1
  defp pages(total), do: max(1, div(total + @limit - 1, @limit))
  defp slice(rows, page), do: Enum.slice(rows, (page - 1) * @limit, @limit)
  defp invalid!(message), do: Repo.rollback({:invalid, message})
end
