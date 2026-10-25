# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceSelection do
  @moduledoc "Bounded discovery of explicit maintenance scopes; filters never become saved scope."
  import Ecto.Query

  alias Mondek.{
    Assignment,
    Inspection,
    MaintenanceTime,
    Monitoring,
    Repo,
    ResultStream,
    Runner
  }

  @fields ~w(scope assignment_id source_id environment target_kind target_key)
  @limit 512
  @page_size 25

  @doc "Bounded named filter suggestions; choices never define saved maintenance scope."
  def filter_choices do
    assignments =
      from a in Assignment,
        where: is_nil(a.retired_at) and not is_nil(a.environment),
        select: %{
          id: a.environment,
          label: coalesce(a.environment_label, a.environment),
          priority: 0
        }

    streams =
      from s in ResultStream,
        join: a in Assignment,
        on: a.id == s.assignment_id,
        where: is_nil(s.retired_at) and is_nil(a.retired_at) and not is_nil(s.environment),
        select: %{
          id: s.environment,
          label: coalesce(s.environment_label, s.environment),
          priority: 1
        }

    environments = assignments |> union_all(^streams)

    environments =
      Repo.all(
        from e in subquery(environments),
          distinct: e.id,
          order_by: [e.id, e.priority, e.label],
          limit: 101,
          select: %{"id" => e.id, "label" => e.label}
      )

    runners =
      Repo.all(
        from r in Runner,
          order_by: [r.label, r.id],
          limit: 101,
          select: %{"id" => r.id, "label" => r.label}
      )

    sources =
      Repo.all(
        from a in Assignment,
          where: is_nil(a.retired_at) and not is_nil(a.source_id),
          distinct: a.source_id,
          order_by: a.source_id,
          limit: 101,
          select: %{"id" => a.source_id, "label" => a.source_id}
      )

    %{
      "environments" => Enum.take(environments, 100),
      "runners" => Enum.take(runners, 100),
      "sources" => Enum.take(sources, 100),
      "truncated" => %{
        "environments" => length(environments) > 100,
        "runners" => length(runners) > 100,
        "sources" => length(sources) > 100
      }
    }
  end

  def list(params \\ %{}) do
    query = candidates(params)

    count_query =
      query |> exclude(:select) |> exclude(:order_by) |> select([_], %{item: fragment("1")})

    total = Repo.aggregate(subquery(count_query), :count)
    pages = max(1, div(total + @page_size - 1, @page_size))
    page = min(page(params["page"]), pages)

    items =
      query
      |> limit(^@page_size)
      |> offset(^((page - 1) * @page_size))
      |> Repo.all()
      |> Enum.map(&decorate/1)

    %{
      "items" => items,
      "total" => total,
      "page" => page,
      "page_size" => @page_size,
      "pages" => pages
    }
  end

  def all(params \\ %{}) do
    rows = candidates(params) |> limit(^(@limit + 1)) |> Repo.all()

    if length(rows) > @limit do
      {:error,
       {:invalid,
        "A window can select at most #{@limit} checks or targets. Narrow the search; nothing was added."}}
    else
      {:ok, Enum.map(rows, &decorate/1)}
    end
  end

  def valid?(selections) when is_list(selections) and length(selections) <= @limit,
    do: Enum.all?(selections, &valid_scope?/1)

  def valid?(_), do: false

  def normalize(selections) do
    if valid?(selections) do
      selections
      |> Enum.map(&identity/1)
      |> Enum.uniq()
      |> Enum.sort_by(&key/1)
    else
      []
    end
  end

  def key(scope), do: scope |> identity() |> Jason.encode!() |> Base.url_encode64(padding: false)

  def describe(selections) do
    selections = normalize(selections)
    checks = for %{"scope" => "check", "assignment_id" => id} <- selections, do: id
    targets = Enum.filter(selections, &(&1["scope"] == "target"))

    check_rows =
      check_query(from(a in Assignment, where: a.id in ^checks, select: a.id)) |> Repo.all()

    target_match = Enum.reduce(targets, dynamic(false), &target_match/2)

    target_rows =
      target_query(from([s, a, r] in active_results(), where: ^target_match)) |> Repo.all()

    found = Map.new(check_rows ++ target_rows, fn row -> {key(row), decorate(row)} end)

    selections
    |> Enum.map(fn selector ->
      Map.get_lazy(found, key(selector), fn ->
        selector
        |> Map.merge(%{
          "label" => fallback_label(selector),
          "matched_results" => 0,
          "available" => false
        })
        |> decorate()
      end)
    end)
    |> Enum.sort_by(fn row ->
      {row["label"], row["scope"], row["source_id"] || "", row["environment"] || "",
       row["target_kind"] || "", row["target_key"] || "", row["assignment_id"] || ""}
    end)
  end

  def proposal(selections, at \\ Monitoring.now()) do
    %{
      "id" => nil,
      "revision" => nil,
      "name" => "Planned maintenance",
      "reason" => "",
      "scope" => "selection",
      "assignment_id" => nil,
      "source_id" => nil,
      "environment" => nil,
      "target_kind" => nil,
      "target_key" => nil,
      "selections" => normalize(selections),
      "timezone" => "Etc/UTC",
      "start_mode" => "now",
      "starts_local" => MaintenanceTime.local(at, "Etc/UTC"),
      "ends_local" => MaintenanceTime.local(DateTime.add(at, 3600), "Etc/UTC"),
      "start_fold" => "reject",
      "end_fold" => "reject"
    }
  end

  defp candidates(params) do
    valid =
      Enum.all?(~w(search source_id environment runner_id), fn field ->
        value = params[field]
        value in [nil, ""] or text?(value, if(field == "environment", do: 128, else: 200))
      end)

    if valid,
      do: candidate_query(params),
      else: check_query(from(a in Assignment, where: false, select: a.id))
  end

  defp candidate_query(%{"kind" => "target"} = params) do
    active_results()
    |> result_filters(params)
    |> target_query()
  end

  defp candidate_query(params) do
    selected =
      params
      |> Map.take(~w(search environment runner_id))
      |> Inspection.checks_query()

    selected =
      if present?(params["source_id"]),
        do: from([a, r] in selected, where: a.source_id == ^params["source_id"]),
        else: selected

    check_query(from([a, r] in selected, select: a.id))
  end

  defp check_query(selected) do
    from a in Assignment,
      left_join: r in Runner,
      on: r.id == a.runner_id,
      left_join: s in ResultStream,
      on: s.assignment_id == a.id and is_nil(s.retired_at) and is_nil(a.retired_at),
      where: a.id in subquery(selected),
      group_by: [a.id, r.label],
      order_by: [asc: a.label, asc: a.id],
      select: %{
        "scope" => "check",
        "assignment_id" => a.id,
        "label" => a.label,
        "check_label" => a.label,
        "runner_label" => r.label,
        "runner_id" => a.runner_id,
        "check_source" => a.source_id,
        "check_environment" => a.environment,
        "matched_results" => count(s.id),
        "available" => is_nil(a.retired_at)
      }
  end

  defp active_results do
    from s in ResultStream,
      join: a in Assignment,
      on: a.id == s.assignment_id,
      left_join: r in Runner,
      on: r.id == a.runner_id,
      where: is_nil(s.retired_at) and is_nil(a.retired_at) and not is_nil(a.source_id)
  end

  # Filters discover identities. Counts deliberately include the whole target,
  # including observers and results outside the discovery filter.
  defp target_query(selected) do
    identities =
      from [s, a, r] in selected,
        distinct: true,
        select: %{
          source: a.source_id,
          environment: s.environment,
          kind: fragment("?->>'kind'", s.target),
          key: fragment("?->>'key'", s.target)
        }

    from [s, a, r] in active_results(),
      join: t in subquery(identities),
      on:
        a.source_id == t.source and
          fragment("? IS NOT DISTINCT FROM ?", s.environment, t.environment) and
          fragment("?->>'kind'", s.target) == t.kind and fragment("?->>'key'", s.target) == t.key,
      group_by: [t.source, t.environment, t.kind, t.key],
      order_by: [
        asc: min(fragment("?->>'label'", s.target)),
        asc: t.source,
        asc: t.environment,
        asc: t.kind,
        asc: t.key
      ],
      select: %{
        "scope" => "target",
        "source_id" => t.source,
        "environment" => t.environment,
        "target_kind" => t.kind,
        "target_key" => t.key,
        "label" => min(fragment("?->>'label'", s.target)),
        "matched_results" => count(s.id),
        "observer_count" => count(a.runner_id, :distinct),
        "available" => true
      }
  end

  defp result_filters(query, params) do
    query =
      if present?(params["search"]) do
        term = "%" <> escape_like(params["search"]) <> "%"

        from [s, a, r] in query,
          where:
            ilike(s.label, ^term) or ilike(a.label, ^term) or ilike(a.source_key, ^term) or
              ilike(a.source_id, ^term) or ilike(fragment("?->>'label'", s.target), ^term) or
              ilike(fragment("?->>'key'", s.target), ^term)
      else
        query
      end

    query =
      if present?(params["source_id"]),
        do: from([s, a, r] in query, where: a.source_id == ^params["source_id"]),
        else: query

    query =
      if present?(params["environment"]),
        do: from([s, a, r] in query, where: s.environment == ^params["environment"]),
        else: query

    if present?(params["runner_id"]) do
      if match?({:ok, _}, Ecto.UUID.cast(params["runner_id"])),
        do: from([s, a, r] in query, where: a.runner_id == ^params["runner_id"]),
        else: from(s in query, where: false)
    else
      query
    end
  end

  defp target_match(selector, acc) do
    dynamic(
      [s, a, r],
      ^acc or
        (a.source_id == ^selector["source_id"] and
           fragment(
             "? IS NOT DISTINCT FROM ?",
             s.environment,
             type(^selector["environment"], :string)
           ) and
           fragment("?->>'kind'", s.target) == ^selector["target_kind"] and
           fragment("?->>'key'", s.target) == ^selector["target_key"])
    )
  end

  defp decorate(row) do
    scope = identity(row)

    context =
      if scope["scope"] == "check" do
        "#{row["runner_label"] || row["runner_id"] || "Observer unavailable"} · #{row["check_environment"] || "No declared environment"} · source #{row["check_source"] || "built-in checks"} · check #{scope["assignment_id"]}"
      else
        "#{scope["target_kind"]}: #{scope["target_key"]} · #{scope["environment"] || "No declared environment"} · source #{scope["source_id"]} · all matching observers"
      end

    row
    |> Map.merge(scope)
    |> Map.put("key", key(scope))
    |> Map.put("context", context)
    |> Map.put("label", row["label"] || fallback_label(scope))
  end

  defp identity(scope), do: Map.new(@fields, &{&1, Map.get(scope, &1)})
  defp fallback_label(%{"scope" => "check"} = scope), do: "Check #{scope["assignment_id"]}"
  defp fallback_label(scope), do: "#{scope["target_kind"]}: #{scope["target_key"]}"

  defp valid_scope?(%{"scope" => "check"} = scope),
    do:
      Mondek.Protocol.assignment_id?(scope["assignment_id"]) and
        Enum.all?(~w(source_id environment target_kind target_key), &is_nil(scope[&1]))

  defp valid_scope?(%{"scope" => "target"} = scope),
    do:
      is_nil(scope["assignment_id"]) and text?(scope["source_id"], 200) and
        text?(scope["target_kind"], 64) and text?(scope["target_key"], 200) and
        (is_nil(scope["environment"]) or text?(scope["environment"], 128))

  defp valid_scope?(_), do: false

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        not String.contains?(value, <<0>>) and String.trim(value) != ""

  defp present?(value), do: is_binary(value) and value != ""

  defp escape_like(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  defp page(value) when is_integer(value), do: value |> max(1) |> min(100_000)

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> page(number)
      _ -> 1
    end
  end

  defp page(_), do: 1
end
