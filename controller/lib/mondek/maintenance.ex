# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Maintenance do
  @moduledoc "Reviewed, finite notification windows over checks or explicitly named logical targets."
  import Ecto.Query
  import Kernel, except: [apply: 2, apply: 3]

  alias Mondek.{
    Assignment,
    ResultStream,
    Incident,
    Occurrence,
    MaintenanceWindow,
    MaintenanceEvent,
    Monitoring,
    Repo,
    Runner
  }

  @fields ~w(id revision name reason scope assignment_id source_id environment target_kind target_key selections timezone start_mode starts_local ends_local start_fold end_fold)
  @selector_fields ~w(scope assignment_id source_id environment target_kind target_key)
  @scope_fields @selector_fields ++ ["selections"]
  @selection_limit 512
  @limit 25
  @review_limit 4096
  @max_age 900
  @last ~U[9999-12-31 23:59:59.999999Z]

  # Caller owns the transaction. Take this before other mutation domains;
  # shared dispatch and exclusive edits follow docs/TRANSACTIONS-AND-LOCKS.md.
  def lock!(mode \\ :exclusive) do
    function =
      if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Repo.query!("SELECT #{function}(774009)")
    :ok
  end

  def list(params \\ %{}, at \\ Monitoring.now()) do
    Mondek.MaintenanceSchedules.list(params, at)
  end

  @doc false
  def series_list_query(params, at), do: filtered(params, at)

  @doc false
  def public_window(window, at), do: public(window, at)

  @doc false
  def series_scope!(proposal, lock_assignments? \\ false) do
    p = validate!(proposal)

    if p["id"] || p["revision"] not in [nil, 0],
      do: invalid!("Create a series from a new maintenance proposal.")

    lock_scope!(p)
    validate_scope!(p, nil)
    window = struct(MaintenanceWindow, atom_scope(p))
    rows = review_rows!(window)
    if lock_assignments?, do: lock_assignments!(rows)
    rows = if lock_assignments?, do: review_rows!(window), else: rows
    {p, window, rows}
  end

  @doc false
  def series_inspection(window, page_number \\ 1) do
    rows =
      Repo.all(
        from r in matching_query(window),
          limit: @limit,
          offset: ^((page(page_number) - 1) * @limit)
      )
      |> Enum.map(&row/1)

    %{
      "rows" => rows,
      "total" => Repo.aggregate(matching_query(window), :count),
      "matched_checks" =>
        Repo.aggregate(
          from([s, a, r] in exclude(exclude(matching_query(window), :select), :order_by),
            select: a.id,
            distinct: true
          ),
          :count
        ),
      "selection_summary" => selection_summary(window)
    }
  end

  @doc false
  def series_selection_summary(window, rows), do: selection_summary(window, rows)

  @doc false
  def series_overlaps(window, rows) do
    Repo.all(
      from w in overlapping_query(window, rows),
        limit: 1025,
        select: %MaintenanceWindow{
          id: w.id,
          revision: w.revision,
          name: w.name,
          reason: w.reason,
          scope: w.scope,
          starts_at: w.starts_at,
          ends_at: w.ends_at,
          cancelled_at: w.cancelled_at,
          series_id: w.series_id,
          series_index: w.series_index,
          selection_count:
            fragment(
              "CASE WHEN ?='selection' THEN cardinality(?) ELSE 1 END",
              w.scope,
              w.selections
            )
        }
    )
  end

  @doc false
  def series_state(rows, windows), do: state(rows, windows, nil)

  @doc false
  def insert_series_window!(p, resolved, series_id, at) do
    p = Map.merge(p, Map.take(resolved, ~w(starts_local ends_local)))

    window =
      candidate!(p, nil, at, resolved)
      |> Map.merge(%{id: resolved["id"], series_id: series_id, series_index: resolved["index"]})
      |> Repo.insert!()

    event!(window, "created", window.reason, at)
    window
  end

  @doc false
  def series_wake!(window), do: wake!(window)

  @doc false
  def series_lock_scope!(window), do: lock_scope!(scope(window))

  @doc false
  def cancel_series_window!(window, reason, at) do
    window = Repo.get!(MaintenanceWindow, window.id)

    window =
      Monitoring.change(window, %{
        revision: window.revision + 1,
        cancelled_at: at,
        cancelled_by: "Local operator",
        cancellation_reason: reason,
        updated_at: at
      })

    event!(window, "cancelled", reason, at)
    window
  end

  def get(id, at \\ Monitoring.now()) do
    case find(id) do
      nil ->
        {:error, :not_found}

      window ->
        rows = matching_rows(window, @limit)
        match_count = Repo.aggregate(matching_query(window), :count)

        history =
          Repo.all(
            from e in MaintenanceEvent,
              where: e.window_id == ^window.id,
              order_by: [desc: e.revision],
              limit: 100,
              select: %MaintenanceEvent{
                id: e.id,
                window_id: e.window_id,
                revision: e.revision,
                kind: e.kind,
                actor: e.actor,
                reason: e.reason,
                inserted_at: e.inserted_at,
                snapshot:
                  fragment(
                    "CASE WHEN ?->>'scope'='selection' THEN (? - 'selections') || jsonb_build_object('selection_count', jsonb_array_length(?->'selections'), 'scope_window_id', ?::text) ELSE ? END",
                    e.snapshot,
                    e.snapshot,
                    e.snapshot,
                    e.window_id,
                    e.snapshot
                  )
              }
          )

        {:ok,
         public(window, at)
         |> Map.merge(%{
           "proposal" => proposal(window),
           "scope_options" => [scope_option(window)],
           "current_matches" => Enum.take(rows, @limit),
           "selection_summary" => selection_summary(window),
           "match_count" => match_count,
           "history" => Enum.map(history, &Monitoring.public/1),
           "history_count" =>
             Repo.aggregate(from(e in MaintenanceEvent, where: e.window_id == ^window.id), :count)
         })}
    end
  end

  def seed(assignment_id, stream_id \\ nil, at \\ Monitoring.now()) do
    case assignment(assignment_id) do
      nil ->
        {:error, :not_found}

      %{retired_at: retired} when not is_nil(retired) ->
        {:error, :retired}

      a ->
        streams =
          Repo.all(
            from s in ResultStream,
              where: s.assignment_id == ^a.id and is_nil(s.retired_at),
              order_by: s.id
          )

        stream =
          if stream_id,
            do: Enum.find(streams, &(&1.id == stream_id)),
            else: if(length(streams) == 1, do: hd(streams))

        check = %{
          "scope" => "check",
          "assignment_id" => a.id,
          "source_id" => nil,
          "environment" => nil,
          "target_kind" => nil,
          "target_key" => nil,
          "label" => "#{a.label}: this check and all its results"
        }

        targets =
          if a.source_id do
            Enum.map(streams, fn s ->
              %{
                "scope" => "target",
                "assignment_id" => nil,
                "source_id" => a.source_id,
                "environment" => s.environment,
                "target_kind" => s.target["kind"],
                "target_key" => s.target["key"],
                "label" =>
                  "#{s.target["label"]}: across runners in #{s.environment || "the default monitored environment"}"
              }
            end)
            |> Enum.uniq_by(&Map.take(&1, ~w(source_id environment target_kind target_key)))
          else
            []
          end

        options = [check | targets]

        selected =
          if stream_id && stream,
            do:
              Enum.find(
                targets,
                check,
                &(&1["target_kind"] == stream.target["kind"] and
                    &1["target_key"] == stream.target["key"] and
                    &1["environment"] == stream.environment)
              ),
            else: check

        p =
          Map.drop(selected, [
            "label"
          ])
          |> Map.merge(%{
            "id" => nil,
            "revision" => nil,
            "name" => "Planned maintenance",
            "reason" => "",
            "timezone" => "Etc/UTC",
            "start_mode" => "now",
            "starts_local" => Mondek.MaintenanceTime.local(at, "Etc/UTC"),
            "ends_local" => Mondek.MaintenanceTime.local(DateTime.add(at, 3600), "Etc/UTC"),
            "start_fold" => "reject",
            "end_fold" => "reject"
          })

        {:ok, %{"proposal" => p, "scope_options" => options, "assignment_id" => a.id}}
    end
  end

  def preview(proposal, page_number \\ 1, at \\ nil, review_token \\ nil) do
    Repo.transaction(fn ->
      lock!(:shared)
      p = validate!(proposal)

      prior =
        if review_token do
          case verify(review_token) do
            {:ok, review} -> review
            {:error, reason} -> Repo.rollback(reason)
          end
        end

      if prior &&
           (prior["proposal"] != fingerprint(p) or
              prior["timezone_version"] != Mondek.MaintenanceTime.version()),
         do: Repo.rollback(:review_changed)

      current = reviewed_window!(p)
      lock_scope!(p)
      validate_scope!(p, current)
      at = at || Monitoring.now()
      candidate = candidate!(p, current, at, prior && prior["resolved"])
      rows = review_rows!(candidate)
      overlaps = overlapping(candidate, rows)
      state = state(rows, overlaps, current)
      if prior && prior["state"] != state, do: Repo.rollback(:review_changed)

      resolved = %{
        "starts_at" => Monitoring.iso(candidate.starts_at),
        "ends_at" => Monitoring.iso(candidate.ends_at)
      }

      review = %{
        "proposal" => fingerprint(p),
        "state" => state,
        "resolved" => resolved,
        "window_id" =>
          (current && current.id) || (prior && prior["window_id"]) || Ecto.UUID.generate(),
        "timezone_version" => Mondek.MaintenanceTime.version()
      }

      page_number = page(page_number)

      %{
        "proposal" => p,
        "review_token" =>
          review_token || Phoenix.Token.sign(MondekWeb.Endpoint, "maintenance-review", review),
        "fingerprint" =>
          fingerprint(%{
            "proposal" => p,
            "state" => state,
            "resolved" => resolved,
            "window_id" => review["window_id"]
          }),
        "rows" => Enum.slice(rows, (page_number - 1) * @limit, @limit),
        "selection_summary" => selection_summary(candidate, rows),
        "counts" => %{
          "matched_results" => length(rows),
          "matched_checks" => rows |> Enum.map(& &1["assignment_id"]) |> Enum.uniq() |> length()
        },
        "page" => page_number,
        "page_size" => @limit,
        "total" => length(rows),
        "pages" => max(1, div(length(rows) + @limit - 1, @limit)),
        "overlaps" => Enum.map(overlaps, &public(&1, at)),
        "starts_at" => resolved["starts_at"],
        "ends_at" => resolved["ends_at"]
      }
    end)
  end

  def apply(token, proposal, at \\ nil) do
    with {:ok, review} <- verify(token) do
      result =
        Repo.transaction(fn ->
          lock!()
          p = validate!(proposal)

          if fingerprint(p) != review["proposal"] or
               Mondek.MaintenanceTime.version() != review["timezone_version"],
             do: Repo.rollback(:review_changed)

          current = reviewed_window!(p)

          if is_nil(current) and Repo.get(MaintenanceWindow, review["window_id"]),
            do: Repo.rollback(:review_changed)

          lock_scope!(p)
          validate_scope!(p, current)
          lock_assignments!(review_rows!(struct(MaintenanceWindow, atom_scope(p))))
          at = at || Monitoring.now()
          candidate = candidate!(p, current, at, review["resolved"])
          rows = review_rows!(candidate)
          lock_assignments!(rows)
          rows = review_rows!(candidate)
          overlaps = overlapping(candidate, rows)
          if state(rows, overlaps, current) != review["state"], do: Repo.rollback(:review_changed)

          case verify(token) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          attrs = Map.from_struct(candidate) |> Map.drop([:__meta__, :id])

          window =
            if current,
              do: Monitoring.change(current, attrs),
              else: Repo.insert!(%{candidate | id: review["window_id"]})

          event!(window, if(current, do: "updated", else: "created"), window.reason, at)

          Mondek.MaintenanceSchedules.child_changed!(
            window,
            "occurrence_updated",
            window.reason,
            at
          )

          wake!(window)
          public(window, at)
        end)

      Monitoring.notify()
      result
    end
  end

  def cancel(id, revision, reason, at \\ nil) do
    with :ok <- note(reason) do
      result =
        Repo.transaction(fn ->
          lock!()
          window = find(id) || Repo.rollback(:not_found)
          lock_scope!(scope(window))
          at = at || Monitoring.now()
          if not is_integer(revision) or window.revision != revision, do: Repo.rollback(:stale)

          if window.cancelled_at || DateTime.compare(window.ends_at, at) != :gt,
            do: Repo.rollback({:invalid, "Only upcoming or active maintenance can be cancelled."})

          # The exclusive gate lock already serializes dispatch. Scope inventory
          # is locked independently; cancellation must work beyond preview limits.

          window =
            Monitoring.change(window, %{
              revision: window.revision + 1,
              cancelled_at: at,
              cancelled_by: "Local operator",
              cancellation_reason: reason,
              updated_at: at
            })

          event!(window, "cancelled", reason, at)

          Mondek.MaintenanceSchedules.child_changed!(
            window,
            "occurrence_cancelled",
            reason,
            at
          )

          wake!(window)

          public(window, at)
        end)

      Monitoring.notify()
      result
    end
  end

  def active_for(incident, assignment, at) do
    stream = incident.stream_id && Repo.get(ResultStream, incident.stream_id)

    query =
      from w in MaintenanceWindow,
        where: is_nil(w.cancelled_at) and w.starts_at <= ^at and w.ends_at > ^at

    check = dynamic([w], w.scope == "check" and w.assignment_id == ^assignment.id)

    match =
      if stream && assignment.source_id,
        do:
          dynamic(
            [w],
            ^check or
              (w.scope == "target" and w.source_id == ^assignment.source_id and
                 fragment(
                   "? IS NOT DISTINCT FROM ?",
                   w.environment,
                   type(^incident.environment, :string)
                 ) and w.target_kind == ^stream.target["kind"] and
                 w.target_key == ^stream.target["key"])
          ),
        else: check

    selectors =
      [check_selector(assignment.id)] ++
        target_selector(assignment.source_id, incident.environment, stream && stream.target)

    match =
      dynamic(
        [w],
        ^match or
          (w.scope == "selection" and
             fragment("? && ?", w.selections, type(^selectors, {:array, :map})))
      )

    Repo.all(from w in query, where: ^match, order_by: [asc: w.ends_at, asc: w.id])
  end

  def active_for_many(parents, at) do
    stream_ids =
      parents |> Enum.map(fn {i, _} -> i.stream_id end) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    streams =
      Repo.all(
        from s in ResultStream, where: s.id in ^stream_ids, select: struct(s, [:id, :target])
      )
      |> Map.new(&{&1.id, &1})

    rows =
      Enum.map(parents, fn {i, a} ->
        s = streams[i.stream_id]

        %{
          "assignment_id" => a.id,
          "source_id" => a.source_id,
          "environment" => i.environment,
          "target" => (s && s.target) || %{}
        }
      end)

    query = matching_windows(MaintenanceWindow, rows, Enum.map(rows, & &1["assignment_id"]))

    windows =
      Repo.all(
        from w in query,
          where: is_nil(w.cancelled_at) and w.starts_at <= ^at and w.ends_at > ^at
      )

    Map.new(parents, fn {i, a} ->
      s = streams[i.stream_id]

      matching =
        Enum.filter(windows, fn w ->
          matches_row?(w, %{
            "assignment_id" => a.id,
            "source_id" => a.source_id,
            "environment" => i.environment,
            "target" => (s && s.target) || %{}
          })
        end)

      {i.id, matching}
    end)
  end

  @doc "Match exact logical result scopes, including declared targets with no admitted assignment."
  def active_for_rows(rows, at) do
    rows = Enum.map(rows, &Map.update(&1, "target", %{}, fn target -> target || %{} end))

    assignment_ids =
      rows |> Enum.map(& &1["assignment_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    query = matching_windows(MaintenanceWindow, rows, assignment_ids)

    windows =
      Repo.all(
        from w in query,
          where: is_nil(w.cancelled_at) and w.starts_at <= ^at and w.ends_at > ^at,
          order_by: [asc: w.ends_at, asc: w.id]
      )

    Map.new(rows, fn row ->
      {Map.fetch!(row, "key"), Enum.filter(windows, &matches_row?(&1, row))}
    end)
  end

  @doc "Compact incident reference; inspect the window itself for its complete immutable scope."
  def reference(window) do
    window
    |> Monitoring.public()
    |> Map.take(
      ~w(id revision name reason scope starts_at ends_at cancelled_at series_id series_index)
    )
    |> Map.merge(%{
      "scope_window_id" => window.id,
      "selection_count" =>
        window.selection_count ||
          if(window.scope == "selection", do: length(window.selections), else: 1)
    })
  end

  def for_assignment(id, at \\ Monitoring.now()) do
    case assignment(id) do
      nil ->
        []

      _ ->
        streams = rows_query() |> where([s, a], a.id == ^id) |> Repo.all() |> Enum.map(&row/1)

        query = matching_windows(MaintenanceWindow, streams, [id])

        Repo.all(representatives(query, at))
        |> Enum.filter(fn w ->
          check_selector(id) in selectors(w) or
            Enum.any?(streams, &matches_row?(w, &1))
        end)
        |> Enum.take(100)
        |> Enum.map(fn w ->
          public(w, at)
          |> Map.put(
            "matching_stream_ids",
            streams |> Enum.filter(&matches_row?(w, &1)) |> Enum.map(& &1["id"])
          )
        end)
    end
  end

  def for_stream(id, at \\ Monitoring.now()) do
    case uuid(id) && Repo.get(ResultStream, id) do
      nil ->
        []

      false ->
        []

      stream ->
        a = Repo.get!(Assignment, stream.assignment_id)
        query = matching_windows(MaintenanceWindow, [row({stream, a, nil})], [a.id])

        Repo.all(representatives(query, at))
        |> Enum.map(&(public(&1, at) |> Map.put("matching_stream_ids", [id])))
    end
  end

  defp representatives(query, at) do
    ranked =
      from w in query,
        where: is_nil(w.cancelled_at) and w.ends_at > ^at,
        select: %{
          id: w.id,
          rank:
            fragment(
              "CASE WHEN ?<=? THEN 1 ELSE row_number() OVER (PARTITION BY COALESCE(?::text,?::text) ORDER BY ?,?) END",
              w.starts_at,
              ^at,
              w.series_id,
              w.id,
              w.starts_at,
              w.id
            )
        }

    ids = from r in subquery(ranked), where: r.rank == 1, select: r.id

    from w in query,
      where: w.id in subquery(ids),
      order_by: [asc: w.starts_at, asc: w.id],
      limit: 100
  end

  defp filtered(params, at) do
    query =
      case params["status"] do
        "all" ->
          MaintenanceWindow

        "history" ->
          from w in MaintenanceWindow, where: not is_nil(w.cancelled_at) or w.ends_at <= ^at

        _ ->
          from w in MaintenanceWindow, where: is_nil(w.cancelled_at) and w.ends_at > ^at
      end

    cond do
      is_binary(params["stream_id"]) and uuid(params["stream_id"]) ->
        selected =
          Repo.all(
            from s in ResultStream,
              join: a in Assignment,
              on: a.id == s.assignment_id,
              left_join: r in Runner,
              on: r.id == a.runner_id,
              where: s.id == ^params["stream_id"],
              select: {s, a, r.label}
          )
          |> Enum.map(&row/1)

        matching_windows(query, selected, Enum.map(selected, & &1["assignment_id"]))

      is_binary(params["assignment_id"]) ->
        selected =
          Repo.all(
            from s in ResultStream,
              join: a in Assignment,
              on: a.id == s.assignment_id,
              left_join: r in Runner,
              on: r.id == a.runner_id,
              where: a.id == ^params["assignment_id"],
              select: {s, a, r.label}
          )
          |> Enum.map(&row/1)

        matching_windows(query, selected, [params["assignment_id"]])

      true ->
        query
    end
  end

  defp matching_windows(query, rows, assignment_ids) do
    selected =
      (Enum.map(assignment_ids, &check_selector/1) ++
         Enum.flat_map(rows, fn r ->
           target_selector(r["source_id"], r["environment"], r["target"])
         end))
      |> Enum.uniq()

    from w in query,
      where:
        (w.scope in ["check", "target"] and
           fragment(
             "maintenance_selections_match(?, ?, ?, ?, ?, ?)",
             type(^selected, {:array, :map}),
             w.assignment_id,
             w.source_id,
             w.environment,
             w.target_kind,
             w.target_key
           )) or
          (w.scope == "selection" and
             fragment("? && ?", w.selections, type(^selected, {:array, :map})))
  end

  defp validate!(p) when is_map(p) do
    p = Map.put_new(p, "selections", [])
    p = Enum.reduce(@fields, p, fn key, p -> Map.put_new(p, key, nil) end)

    if is_nil(p["id"]) and p["revision"] not in [nil, 0],
      do: invalid!("A new maintenance window cannot carry an existing revision.")

    if not is_nil(p["id"]) and
         (not is_integer(p["revision"]) or p["revision"] < 1 or
            p["revision"] >= 9_223_372_036_854_775_807),
       do: invalid!("Supply the reviewed maintenance revision.")

    if Enum.any?(Map.keys(p), &(&1 not in @fields)),
      do: invalid!("Submit only maintenance form fields.")

    if not text?(p["name"], 200) or note(p["reason"]) != :ok or
         p["scope"] not in ["check", "target", "selection"] or not text?(p["timezone"], 200) or
         p["start_mode"] not in ["now", "scheduled"] or
         p["start_fold"] not in ["reject", "earlier", "later"] or
         p["end_fold"] not in ["reject", "earlier", "later"],
       do: invalid!("Supply a name, reason, scope, timezone and valid start/end choices.")

    if p["scope"] == "selection" do
      if not is_list(p["selections"]) or length(p["selections"]) not in 1..@selection_limit,
        do: invalid!("Choose between 1 and #{@selection_limit} checks or exact targets.")

      selected = Enum.map(p["selections"], &normalize_selector!/1) |> Enum.uniq() |> Enum.sort()
      Map.put(p, "selections", selected)
    else
      if p["selections"] != [], do: invalid!("Selections require selection scope.")
      validate_selector_shape!(p)
      p
    end
  end

  defp validate!(_), do: invalid!("Supply a maintenance proposal.")
  defp reviewed_window!(%{"id" => nil}), do: nil

  defp reviewed_window!(p) do
    current = find(p["id"]) || Repo.rollback(:not_found)
    if p["revision"] != current.revision, do: Repo.rollback(:stale)

    if current.cancelled_at,
      do: invalid!("Cancelled windows cannot be edited. Create a new window.")

    current
  end

  defp validate_scope!(p, current) do
    if current && Map.take(p, @scope_fields) != scope(current),
      do:
        invalid!(
          "A saved window's scope is fixed. Cancel it and create another window to change scope."
        )

    if p["scope"] == "selection" do
      if Enum.any?(
           ~w(assignment_id source_id environment target_kind target_key),
           &(not is_nil(p[&1]))
         ),
         do: invalid!("A selection cannot also carry a single check or target scope.")

      validate_selection!(p["selections"], current)
    else
      validate_selector!(p, current)
    end
  end

  defp normalize_selector!(p) when is_map(p) do
    if Enum.any?(Map.keys(p), &(&1 not in @selector_fields)) or
         p["scope"] not in ["check", "target"],
       do: invalid!("Each selection must be an exact check or target without extra fields.")

    validate_selector_shape!(p)
    Map.new(@selector_fields, &{&1, p[&1]})
  end

  defp normalize_selector!(_), do: invalid!("Each selection must be an exact check or target.")

  defp validate_selection!(selected, current) do
    check_ids = for %{"scope" => "check", "assignment_id" => id} <- selected, do: id

    checks =
      Repo.all(from a in Assignment, where: a.id in ^check_ids, select: {a.id, a.retired_at})

    if length(checks) != length(check_ids) or
         (is_nil(current) and Enum.any?(checks, fn {_, retired} -> not is_nil(retired) end)),
       do: invalid!("Choose active checks. Saved selections retain retired check instances.")

    if is_nil(current) do
      targets = Enum.filter(selected, &(&1["scope"] == "target"))

      if Enum.any?(
           Mondek.MaintenanceSelection.describe(targets),
           &(&1["matched_results"] == 0)
         ),
         do:
           invalid!(
             "Create target maintenance from existing results. Saved target windows continue to match future replacements."
           )
    end
  end

  defp validate_selector_shape!(%{"scope" => "check"} = p) do
    if not Mondek.Protocol.assignment_id?(p["assignment_id"]) or
         not Enum.all?(~w(source_id environment target_kind target_key), &is_nil(p[&1])),
       do: invalid!("Choose an exact check instance without target fields.")
  end

  defp validate_selector_shape!(%{"scope" => "target"} = p) do
    if not is_nil(p["assignment_id"]) or not text?(p["source_id"], 200) or
         not text?(p["target_kind"], 64) or not text?(p["target_key"], 200) or
         not (is_nil(p["environment"]) or text?(p["environment"], 128)),
       do: invalid!("Choose an exact source-declared target and monitored environment.")
  end

  defp validate_selector!(p, current) do
    case p["scope"] do
      "check" ->
        a = assignment(p["assignment_id"])

        if not Enum.all?(~w(source_id environment target_kind target_key), &is_nil(p[&1])) or
             is_nil(a) or (is_nil(current) and not is_nil(a.retired_at)),
           do: invalid!("Choose an active check.")

      "target" ->
        if not is_nil(p["assignment_id"]) or not text?(p["source_id"], 200) or
             not text?(p["target_kind"], 64) or not text?(p["target_key"], 200) or
             not (is_nil(p["environment"]) or text?(p["environment"], 128)),
           do: invalid!("Choose an exact source-declared target and monitored environment.")

        if is_nil(current) and matching_rows(struct(MaintenanceWindow, atom_scope(p)), 1) == [],
          do:
            invalid!(
              "Create target maintenance from an existing result. Saved target windows continue to match future replacements."
            )
    end
  end

  defp candidate!(p, current, at, resolved) do
    starts =
      cond do
        resolved -> parse!(resolved["starts_at"])
        p["start_mode"] == "now" -> at
        unchanged_time?(p, current, :start) -> current.starts_at
        true -> resolve!(p["starts_local"], p["timezone"], p["start_fold"])
      end

    ends =
      cond do
        resolved -> parse!(resolved["ends_at"])
        unchanged_time?(p, current, :end) -> current.ends_at
        true -> resolve!(p["ends_local"], p["timezone"], p["end_fold"])
      end

    if DateTime.compare(ends, at) != :gt or DateTime.compare(ends, starts) != :gt or
         DateTime.compare(ends, @last) == :gt,
       do: invalid!("Maintenance must end after its start and after now, within UTC year 9999.")

    if is_nil(resolved) and p["start_mode"] == "scheduled" and DateTime.compare(starts, at) == :lt and
         (is_nil(current) or DateTime.compare(starts, current.starts_at) != :eq),
       do: invalid!("Choose a future start, or Start now.")

    if current && DateTime.compare(current.starts_at, at) != :gt &&
         (DateTime.compare(starts, current.starts_at) != :eq or p["timezone"] != current.timezone),
       do:
         invalid!(
           "An active window's original start and timezone are fixed; its end and reason can be updated."
         )

    if current && DateTime.compare(current.ends_at, at) != :gt,
      do: invalid!("Ended windows cannot be edited. Create a new window.")

    attrs =
      atom_scope(p)
      |> Map.merge(%{
        id: current && current.id,
        revision: if(current, do: current.revision + 1, else: 1),
        name: p["name"],
        reason: p["reason"],
        actor: "Local operator",
        timezone: p["timezone"],
        tzdata_version:
          if(current && unchanged_time?(p, current, :start) && unchanged_time?(p, current, :end),
            do: current.tzdata_version,
            else: Mondek.MaintenanceTime.version()
          ),
        starts_local:
          if(p["start_mode"] == "now",
            do: Mondek.MaintenanceTime.local(starts, p["timezone"]),
            else: p["starts_local"]
          ),
        ends_local: p["ends_local"],
        start_fold:
          if(p["start_mode"] == "now",
            do: Mondek.MaintenanceTime.fold(starts, p["timezone"]),
            else: p["start_fold"]
          ),
        end_fold: p["end_fold"],
        starts_at: usec(starts),
        ends_at: usec(ends),
        inserted_at: if(current, do: current.inserted_at, else: at),
        updated_at: at,
        series_id: current && current.series_id,
        series_index: current && current.series_index
      })

    struct(MaintenanceWindow, attrs)
  end

  defp rows_query do
    from s in ResultStream,
      join: a in Assignment,
      on: a.id == s.assignment_id,
      left_join: r in Runner,
      on: r.id == a.runner_id,
      where: is_nil(s.retired_at) and is_nil(a.retired_at),
      order_by: [asc: s.id],
      select: {s, a, r.label}
  end

  defp matching_query(window) do
    query = rows_query()
    selected = selectors(window)
    check_ids = for %{"scope" => "check", "assignment_id" => id} <- selected, do: id
    match = dynamic([s, a, r], a.id in ^check_ids)

    match =
      selected
      |> Enum.filter(&(&1["scope"] == "target"))
      |> Enum.group_by(
        &{&1["source_id"], &1["environment"], &1["target_kind"]},
        & &1["target_key"]
      )
      |> Enum.reduce(match, fn {{source, environment, kind}, keys}, acc ->
        dynamic(
          [s, a, r],
          ^acc or
            (a.source_id == ^source and
               fragment("? IS NOT DISTINCT FROM ?", s.environment, type(^environment, :string)) and
               fragment("?->>'kind'", s.target) == ^kind and
               fragment("?->>'key'", s.target) in ^keys)
        )
      end)

    from [s, a, r] in query, where: ^match
  end

  defp matching_rows(window, limit) do
    query = matching_query(window)
    query = if limit, do: from(r in query, limit: ^limit), else: query
    Repo.all(query) |> Enum.map(&row/1)
  end

  defp review_rows!(window) do
    rows = matching_rows(window, @review_limit + 1)

    if length(rows) > @review_limit,
      do:
        invalid!(
          "A maintenance review supports at most #{@review_limit} current results. Existing window cancellation remains available."
        )

    rows
  end

  defp row({s, a, runner}),
    do: %{
      "id" => s.id,
      "assignment_id" => a.id,
      "check_label" => a.label,
      "label" => s.label,
      "runner_label" => runner,
      "environment" => s.environment,
      "environment_label" => s.environment_label,
      "target" => s.target,
      "source_id" => a.source_id,
      "assignment_revision" => a.revision
    }

  defp matches_row?(w, r), do: Enum.any?(selectors(w), &selector_matches_row?(&1, r))

  defp selector_matches_row?(%{"scope" => "check"} = s, r),
    do: s["assignment_id"] == r["assignment_id"]

  defp selector_matches_row?(s, r),
    do:
      s["source_id"] == r["source_id"] and s["environment"] == r["environment"] and
        s["target_kind"] == r["target"]["kind"] and s["target_key"] == r["target"]["key"]

  defp selectors(%{scope: "selection", selections: selected}), do: selected
  defp selectors(w), do: [Monitoring.public(w) |> Map.take(@selector_fields)]

  defp check_selector(id),
    do:
      Map.new(@selector_fields, &{&1, nil})
      |> Map.merge(%{"scope" => "check", "assignment_id" => id})

  defp target_selector(nil, _, _), do: []
  defp target_selector(_, _, nil), do: []

  defp target_selector(source, environment, %{"kind" => kind, "key" => key}),
    do: [
      %{
        "scope" => "target",
        "assignment_id" => nil,
        "source_id" => source,
        "environment" => environment,
        "target_kind" => kind,
        "target_key" => key
      }
    ]

  defp target_selector(_, _, _), do: []

  defp selection_summary(window, rows \\ nil) do
    selected = selectors(window)

    contexts =
      selected
      |> Mondek.MaintenanceSelection.describe()
      |> Map.new(&{Map.take(&1, @selector_fields), &1})

    Enum.map(selected, fn selector ->
      context = Map.fetch!(contexts, selector)

      count =
        if rows,
          do: Enum.count(rows, &selector_matches_row?(selector, &1)),
          else: context["matched_results"]

      labels =
        if selector["scope"] == "check" do
          %{
            "check_label" => context["check_label"] || context["label"],
            "runner_label" => context["runner_label"],
            "retired" => not context["available"]
          }
        else
          %{"target_label" => context["label"]}
        end

      selector |> Map.merge(labels) |> Map.put("matched_results", count)
    end)
  end

  defp overlapping(candidate, rows) do
    Repo.all(overlapping_query(candidate, rows))
  end

  defp overlapping_query(candidate, rows) do
    query = matching_windows(MaintenanceWindow, rows, Enum.map(rows, & &1["assignment_id"]))

    selected = selectors(candidate)

    query =
      from w in MaintenanceWindow,
        where:
          w.id in subquery(from m in query, select: m.id) or
            (w.scope in ["check", "target"] and
               fragment(
                 "maintenance_selections_match(?, ?, ?, ?, ?, ?)",
                 type(^selected, {:array, :map}),
                 w.assignment_id,
                 w.source_id,
                 w.environment,
                 w.target_kind,
                 w.target_key
               )) or
            (w.scope == "selection" and
               fragment("? && ?", w.selections, type(^selected, {:array, :map})))

    query =
      from w in query,
        where:
          is_nil(w.cancelled_at) and w.starts_at < ^candidate.ends_at and
            w.ends_at > ^candidate.starts_at,
        order_by: w.id

    if candidate.id, do: from(w in query, where: w.id != ^candidate.id), else: query
  end

  defp state(rows, windows, current),
    do:
      fingerprint(%{
        "rows" => rows,
        "overlaps" => Enum.map(windows, &{&1.id, &1.revision}),
        "revision" => current && current.revision
      })

  defp lock_scope!(p) do
    selected = if p["scope"] == "selection", do: p["selections"], else: [p]
    check_ids = for %{"scope" => "check", "assignment_id" => id} <- selected, do: id
    check_sources = Repo.all(from a in Assignment, where: a.id in ^check_ids, select: a.source_id)
    target_sources = for %{"scope" => "target", "source_id" => source} <- selected, do: source

    (check_sources ++ target_sources)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Mondek.ConfigurationRules.lock_source!/1)
  end

  defp lock_assignments!(rows) do
    ids = rows |> Enum.map(& &1["assignment_id"]) |> Enum.uniq()
    Repo.all(from a in Assignment, where: a.id in ^ids, order_by: a.id, lock: "FOR UPDATE")
  end

  defp wake!(w) do
    query =
      from o in Occurrence,
        join: i in Incident,
        on: i.id == o.incident_id or i.condition_incident_id == o.condition_incident_id,
        join: a in Assignment,
        on: a.id == i.assignment_id,
        left_join: s in ResultStream,
        on: s.id == i.stream_id

    selected = selectors(w)

    query =
      from [o, i, a, s] in query,
        where:
          fragment(
            "maintenance_selections_match(?, ?, ?, ?, ?->>'kind', ?->>'key')",
            type(^selected, {:array, :map}),
            a.id,
            a.source_id,
            i.environment,
            s.target,
            s.target
          )

    group_ids =
      Repo.all(
        from [o, i, a, s] in query,
          where: not is_nil(o.condition_incident_id),
          select: o.condition_incident_id,
          distinct: true
      )

    # Finishing an in-flight group delivery holds its condition lock before
    # touching sibling occurrences. Gate edits must use that same order.
    Mondek.Conditions.lock_ids!(group_ids)

    ids = from [o, i, a, s] in query, select: o.id
    Repo.update_all(from(o in Occurrence, where: o.id in subquery(ids)), inc: [gate_revision: 1])

    # A monitoring episode may cover logical declarations without assignments.
    # Wake its durable holds conservatively; dispatch rechecks every exact scope.
    Mondek.MonitoringLoss.lock!()

    Repo.update_all(
      from(o in Occurrence,
        where:
          not is_nil(o.monitoring_incident_id) and
            o.status in ["pending", "retrying", "delivering", "exhausted"]
      ),
      inc: [gate_revision: 1]
    )
  end

  defp event!(w, kind, reason, at),
    do:
      Repo.insert!(%MaintenanceEvent{
        window_id: w.id,
        revision: w.revision,
        kind: kind,
        actor: "Local operator",
        reason: reason,
        snapshot: Monitoring.public(w),
        inserted_at: at
      })

  defp public(w, at),
    do:
      Monitoring.public(w)
      |> Map.put(
        "status",
        cond do
          w.cancelled_at -> "cancelled"
          DateTime.compare(w.ends_at, at) != :gt -> "ended"
          DateTime.compare(w.starts_at, at) == :gt -> "upcoming"
          true -> "active"
        end
      )
      |> Map.merge(check_context(w))
      |> Map.put("kind", "window")
      |> Map.put("exception", not is_nil(w.series_id) and w.revision > 1)

  defp proposal(w),
    do:
      scope(w)
      |> Map.merge(%{
        "id" => w.id,
        "revision" => w.revision,
        "name" => w.name,
        "reason" => w.reason,
        "timezone" => w.timezone,
        "start_mode" => "scheduled",
        "starts_local" => w.starts_local || Mondek.MaintenanceTime.local(w.starts_at, w.timezone),
        "ends_local" => w.ends_local || Mondek.MaintenanceTime.local(w.ends_at, w.timezone),
        "start_fold" => w.start_fold,
        "end_fold" => w.end_fold
      })

  defp scope(w), do: Monitoring.public(w) |> Map.take(@scope_fields)

  defp unchanged_time?(_, nil, _), do: false

  defp unchanged_time?(p, current, endpoint) do
    local = if endpoint == :start, do: "starts_local", else: "ends_local"
    fold = if endpoint == :start, do: "start_fold", else: "end_fold"
    original = proposal(current)

    p["timezone"] == current.timezone and p[local] == original[local] and
      p[fold] == original[fold]
  end

  defp atom_scope(p),
    do: Map.new(@scope_fields, fn key -> {String.to_existing_atom(key), p[key]} end)

  defp scope_option(w),
    do:
      scope(w)
      |> Map.put(
        "label",
        case w.scope do
          "check" -> "#{check_context(w)["check_label"] || "This check"}: all its results"
          "target" -> "This target across runners in its source and monitored environment"
          "selection" -> "#{length(w.selections)} selected checks and targets"
        end
      )

  defp find(id), do: if(uuid(id), do: Repo.get(MaintenanceWindow, id))

  defp check_context(%{scope: "check", assignment_id: id}) do
    Repo.one(
      from a in Assignment,
        left_join: r in Runner,
        on: r.id == a.runner_id,
        where: a.id == ^id,
        select: %{"check_label" => a.label, "runner_label" => r.label}
    ) || %{}
  end

  defp check_context(_), do: %{}
  defp uuid(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp assignment(id), do: if(Mondek.Protocol.assignment_id?(id), do: Repo.get(Assignment, id))

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)

  defp verify(token) when is_binary(token) and byte_size(token) < 10000 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "maintenance-review", token, max_age: @max_age) do
      {:ok, review} -> {:ok, review}
      {:error, :expired} -> {:error, :review_expired}
      _ -> {:error, :invalid_review}
    end
  end

  defp verify(_), do: {:error, :invalid_review}

  defp resolve!(text, zone, fold) do
    case Mondek.MaintenanceTime.resolve(text, zone, fold) do
      {:ok, date} -> date
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp parse!(text) do
    {:ok, date, _} = DateTime.from_iso8601(text)
    date
  end

  defp usec(date), do: %{date | microsecond: {elem(date.microsecond, 0), 6}}

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> page(n)
      _ -> 1
    end
  end

  defp page(value) when is_integer(value) and value > 0, do: min(value, 100_000)
  defp page(_), do: 1

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp note(reason),
    do:
      if(text?(reason, 500) and not String.match?(reason, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/),
        do: :ok,
        else: {:error, {:invalid, "Supply a nonblank reason of at most 500 bytes."}}
      )

  defp invalid!(reason), do: Repo.rollback({:invalid, reason})
end
