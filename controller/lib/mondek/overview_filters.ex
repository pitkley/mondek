# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.OverviewFilters do
  @moduledoc false
  import Ecto.Query
  alias Mondek.{CoverageDeclaration, Repo, ResultStream, SourceInventory}

  @fields [{"environment", "Environment"}, {"target", "Target"}]

  def fields, do: @fields

  def params(values) do
    params =
      values
      |> Map.take(
        ~w(search environment target_kind target_key page healthy_page expected_page acknowledged_incident_page unacknowledged_incident_page)
      )
      |> Map.filter(fn {_key, value} ->
        is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)
      end)
      |> Map.new(fn {key, value} -> {key, String.slice(value, 0, 200)} end)
      |> Map.reject(fn {_key, value} -> value == "" end)

    if params["target_kind"] && params["target_key"],
      do: params,
      else: Map.drop(params, ~w(target_kind target_key))
  end

  def reset_pages(filters), do: Map.drop(filters, ~w(page healthy_page expected_page))
  def remove(filters, "environment"), do: Map.delete(filters, "environment")
  def remove(filters, "target"), do: Map.drop(filters, ~w(target_kind target_key))

  def selected(filters, "environment"),
    do: if(filters["environment"], do: {filters["environment"], ""})

  def selected(filters, "target"),
    do: if(filters["target_key"], do: {filters["target_key"], filters["target_kind"]})

  def put(filters, "environment", {key, ""}), do: Map.put(filters, "environment", key)

  def put(filters, "target", {key, kind}),
    do: Map.merge(filters, %{"target_key" => key, "target_kind" => kind})

  def options(field, search, selected \\ nil, mode \\ :overview) do
    streams =
      if mode == :checks,
        do: from(s in ResultStream),
        else: from(s in ResultStream, where: is_nil(s.retired_at))

    declarations =
      from(d in CoverageDeclaration,
        join: p in SourceInventory,
        on: p.id == d.source_inventory_id,
        where: is_nil(p.retired_at) and is_nil(p.resume_after_revision)
      )

    declarations =
      if mode == :coverage,
        do: declarations,
        else: from(d in declarations, where: d.scope_resolved)

    {streams, declarations} =
      case field do
        "environment" ->
          {
            from(s in streams,
              select: %{
                key: s.environment,
                kind: fragment("''::text"),
                label: s.environment_label
              }
            ),
            from(d in declarations,
              select: %{
                key: d.environment,
                kind: fragment("''::text"),
                label: d.environment_label
              }
            )
          }

        "target" ->
          {
            from(s in streams,
              select: %{
                key: fragment("?->>'key'", s.target),
                kind: fragment("?->>'kind'", s.target),
                label: fragment("?->>'label'", s.target)
              }
            ),
            from(d in declarations,
              select: %{key: d.target_key, kind: d.target_kind, label: d.target_label}
            )
          }
      end

    entries = if mode == :checks, do: streams, else: union_all(streams, ^declarations)

    query =
      from(o in subquery(entries),
        where: not is_nil(o.key) and not is_nil(o.kind)
      )

    query =
      case selected do
        {key, kind} ->
          from(o in query, where: o.key == ^key and o.kind == ^kind)

        nil ->
          from(o in query,
            where:
              fragment(
                "strpos(lower(concat_ws(' ', ?, ?, ?)), lower(?)) > 0",
                o.label,
                o.key,
                o.kind,
                ^search
              )
          )
      end

    Repo.all(
      from(o in query,
        group_by: [o.key, o.kind],
        order_by: [asc: coalesce(min(o.label), o.key), asc: o.key, asc: o.kind],
        limit: 20,
        select: %{key: o.key, kind: o.kind, label: coalesce(min(o.label), o.key)}
      )
    )
  end
end
