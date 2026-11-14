# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ObserverFilters do
  @moduledoc "Explicit runner/source scope shared by check and coverage inventories."
  import Ecto.Query
  alias Mondek.{Repo, Runner, SourceInventory}
  @fields [{"runner_id", "Runner"}, {"source_id", "Source"}]

  def fields, do: @fields

  def params(values) do
    values
    |> Map.take(~w(runner_id source_id))
    |> Map.filter(fn {_, value} ->
      is_binary(value) && value != "" && byte_size(value) <= 200 && String.valid?(value) &&
        !String.contains?(value, <<0>>)
    end)
  end

  def selected(filters, field), do: if(filters[field], do: {filters[field], ""})
  def remove(filters, field), do: Map.delete(filters, field)
  def put(filters, field, {key, ""}), do: Map.put(filters, field, key)

  def options(field, search, selected \\ nil)

  def options("runner_id", search, selected) do
    query = from(r in Runner)

    query =
      case selected do
        {id, ""} ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> from r in query, where: r.id == ^id
            _ -> from r in query, where: false
          end

        nil ->
          from r in query,
            where:
              fragment(
                "strpos(lower(concat_ws(' ', ?, ?::text)), lower(?)) > 0",
                r.label,
                r.id,
                ^search
              )
      end

    Repo.all(
      from r in query, order_by: [asc: r.label, asc: r.id], limit: 20, select: {r.id, r.label}
    )
    |> Enum.map(fn {id, label} ->
      %{
        key: id,
        kind: "",
        label: (label || "Unnamed runner") <> " (" <> String.slice(id, 0, 8) <> ")",
        show_key: false
      }
    end)
  end

  def options("source_id", search, selected) do
    query =
      case selected do
        {source, ""} ->
          from p in SourceInventory, where: p.source_id == ^source

        nil ->
          from p in SourceInventory,
            where: fragment("strpos(lower(?), lower(?)) > 0", p.source_id, ^search)
      end

    Repo.all(
      from p in query,
        distinct: p.source_id,
        order_by: p.source_id,
        limit: 20,
        select: p.source_id
    )
    |> Enum.map(&%{key: &1, kind: "", label: &1, show_key: false})
  end
end
