# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceSchedules do
  @moduledoc "Finite reviewed series, materialized as ordinary notification windows."
  import Ecto.Query
  import Kernel, except: [apply: 2, apply: 3]

  alias Mondek.{
    Maintenance,
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

        series =
          Repo.insert!(%MaintenanceSeries{
            id: review["id"],
            revision: 1,
            name: p["name"],
            reason: p["reason"],
            actor: "Local operator",
            proposal: p,
            resolved_windows: windows,
            tzdata_version: expanded["timezone_version"],
            inserted_at: at,
            updated_at: at
          })

        children =
          Enum.map(
            windows,
            &Maintenance.insert_series_window!(Map.delete(p, "recurrence"), &1, series.id, at)
          )

        event!(
          series,
          "created",
          series.reason,
          %{"window_ids" => Enum.map(children, & &1.id), "count" => length(children)},
          at
        )

        Maintenance.series_wake!(scope)
        detail(series, children, %{}, at)
      end)

    Monitoring.notify()
    result
  end

  def get(id, params \\ %{}, at \\ Monitoring.now()) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
      Maintenance.lock!(:shared)
      series = find!(id)
      detail(series, children(series.id), if(is_map(params), do: params, else: %{}), at)
    end)
  end

  def cancel_preview(id, revision, reason, page_number \\ 1, at \\ nil, token \\ nil) do
    Repo.transaction(fn ->
      Maintenance.lock!(:shared)
      note!(reason)
      series = find!(id)
      if series.revision != revision, do: Repo.rollback(:stale)
      rows = children(id)
      at = at || Monitoring.now()
      upcoming = upcoming(rows, at)

      if upcoming == [],
        do:
          invalid!(
            "This series has no upcoming windows to cancel. Active windows must be ended individually."
          )

      review = cancellation_review(series, rows, upcoming, reason)
      if token && verify!(token, "cancel") != review, do: Repo.rollback(:review_changed)
      page_number = page(page_number)

      %{
        "id" => series.id,
        "revision" => series.revision,
        "name" => series.name,
        "reason" => reason,
        "review_token" => token || sign(review),
        "upcoming_count" => length(upcoming),
        "active_count" => Enum.count(rows, &active?(&1, at)),
        "rows" => slice(upcoming, page_number) |> Enum.map(&child_public(&1, series, at)),
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
        rows = children(id)
        Maintenance.series_lock_scope!(scope_window(series))
        at = at || Monitoring.now()
        upcoming = upcoming(rows, at)

        if cancellation_review(series, rows, upcoming, reason) != review,
          do: Repo.rollback(:review_changed)

        verify!(token, "cancel")
        cancelled = Enum.map(upcoming, &Maintenance.cancel_series_window!(&1, reason, at))
        series = Monitoring.change(series, %{revision: series.revision + 1, updated_at: at})

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
        detail(series, children(id), %{}, at)
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
    ordinary = Maintenance.series_list_query(params, at)

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

    matching = Maintenance.series_list_query(Map.put(params, "status", "all"), at)

    series =
      from w in MaintenanceWindow,
        where:
          not is_nil(w.series_id) and
            w.series_id in subquery(
              from m in matching, where: not is_nil(m.series_id), select: m.series_id
            ),
        group_by: w.series_id,
        select: %{
          id: w.series_id,
          kind: fragment("'series'::text"),
          sort_at:
            fragment(
              "CASE WHEN ? THEN max(COALESCE(?,?)) ELSE COALESCE(min(?) FILTER (WHERE ? IS NULL AND ?>?),max(?)) END",
              ^history?,
              w.cancelled_at,
              w.ends_at,
              w.starts_at,
              w.cancelled_at,
              w.ends_at,
              ^at,
              w.starts_at
            )
        }

    series =
      case params["status"] do
        "all" ->
          series

        "history" ->
          from w in series,
            having:
              fragment(
                "count(*) FILTER (WHERE ? IS NULL AND ?>?)=0",
                w.cancelled_at,
                w.ends_at,
                ^at
              )

        _ ->
          from w in series,
            having:
              fragment(
                "count(*) FILTER (WHERE ? IS NULL AND ?>?)>0",
                w.cancelled_at,
                w.ends_at,
                ^at
              )
      end

    union = union_all(ordinary, ^series)
    total = Repo.aggregate(from(e in subquery(union)), :count)
    page_number = page(params["page"])
    entries = from e in subquery(union), limit: @limit, offset: ^((page_number - 1) * @limit)

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

    members =
      Repo.all(
        from w in MaintenanceWindow,
          where: w.series_id in ^series_ids,
          select:
            struct(w, [
              :id,
              :series_id,
              :series_index,
              :revision,
              :starts_at,
              :ends_at,
              :cancelled_at
            ])
      )
      |> Enum.group_by(& &1.series_id)

    public =
      Enum.map(entries, fn
        %{kind: "window", id: id} -> Maintenance.public_window(windows[id], at)
        %{kind: "series", id: id} -> summary(parents[id], members[id], at)
      end)

    %{
      "windows" => public,
      "page" => page_number,
      "page_size" => @limit,
      "total" => total,
      "pages" => pages(total)
    }
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

  defp detail(series, windows, params, at) do
    occurrence_page = page(params["occurrence_page"])
    result_page = page(params["result_page"])
    inspection = Maintenance.series_inspection(scope_window(series), result_page)

    events =
      Repo.all(
        from e in MaintenanceSeriesEvent,
          where: e.series_id == ^series.id,
          order_by: [desc: e.revision],
          limit: 100
      )

    scope_labels =
      if series.proposal["scope"] == "check",
        do:
          Map.take(
            List.first(inspection["selection_summary"]) || %{},
            ~w(check_label runner_label)
          ),
        else: %{}

    summary(series, windows, at)
    |> Map.merge(scope_labels)
    |> Map.merge(%{
      "proposal" => series.proposal,
      "recurrence" => series.proposal["recurrence"],
      "timezone_version" => series.tzdata_version,
      "occurrences" => slice(windows, occurrence_page) |> Enum.map(&child_public(&1, series, at)),
      "occurrence_page" => occurrence_page,
      "occurrence_pages" => pages(length(windows)),
      "occurrence_total" => length(windows),
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
      "history_count" =>
        Repo.aggregate(
          from(e in MaintenanceSeriesEvent, where: e.series_id == ^series.id),
          :count
        )
    })
  end

  defp summary(series, rows, at) do
    active = Enum.count(rows, &active?(&1, at))
    upcoming = upcoming(rows, at)
    cancelled = Enum.count(rows, & &1.cancelled_at)
    ended = length(rows) - active - length(upcoming) - cancelled

    status =
      cond do
        active > 0 -> "active"
        upcoming != [] and ended == 0 -> "upcoming"
        upcoming != [] -> "between"
        cancelled == length(rows) -> "cancelled"
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
      "active_count" => active,
      "upcoming_count" => length(upcoming),
      "ended_count" => ended,
      "cancelled_count" => cancelled,
      "remaining_count" => active + length(upcoming),
      "occurrence_total" => length(rows),
      "next_starts_at" => upcoming |> Enum.map(& &1.starts_at) |> min_date() |> Monitoring.iso(),
      "final_ends_at" => rows |> Enum.map(& &1.ends_at) |> Enum.max(DateTime) |> Monitoring.iso(),
      "inserted_at" => Monitoring.iso(series.inserted_at),
      "updated_at" => Monitoring.iso(series.updated_at)
    }
  end

  defp child_public(window, series, at) do
    original = Enum.find(series.resolved_windows, &(&1["index"] == window.series_index))

    Maintenance.public_window(window, at)
    |> Map.drop(@scope_fields)
    |> Map.merge(%{
      "index" => window.series_index,
      "original_starts_at" => original["starts_at"],
      "original_ends_at" => original["ends_at"],
      "elapsed_seconds" =>
        DateTime.diff(window.ends_at, window.starts_at, :microsecond) / 1_000_000
    })
  end

  defp cancellation_review(series, rows, upcoming, reason),
    do: %{
      "action" => "cancel",
      "id" => series.id,
      "revision" => series.revision,
      "reason" => reason,
      "children" => Enum.map(rows, &{&1.id, &1.revision}),
      "upcoming_ids" => Enum.map(upcoming, & &1.id)
    }

  defp children(id),
    do:
      Repo.all(
        from w in MaintenanceWindow,
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

  defp upcoming(rows, at),
    do:
      Enum.filter(rows, &(is_nil(&1.cancelled_at) and DateTime.compare(&1.starts_at, at) == :gt))

  defp active?(w, at),
    do:
      is_nil(w.cancelled_at) and DateTime.compare(w.starts_at, at) != :gt and
        DateTime.compare(w.ends_at, at) == :gt

  defp min_date([]), do: nil
  defp min_date(values), do: Enum.min(values, DateTime)

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
