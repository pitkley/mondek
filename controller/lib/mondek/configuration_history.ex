# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationHistory do
  @moduledoc "Read-only, bounded inspection of accepted configuration changes."
  alias Mondek.{Repo, ConfigurationObjects}

  def recent do
    Repo.query!("""
    SELECT r.head, r.channel, r.inserted_at, changes.total, changes.path,
      COALESCE((r.files->>changes.path)::jsonb->>'name',
        (r.files->>changes.path)::jsonb->'scope'->>'check_key',
        (p.files->>changes.path)::jsonb->>'name',
        (p.files->>changes.path)::jsonb->'scope'->>'check_key', changes.path)
    FROM (SELECT * FROM configuration_revisions ORDER BY id DESC LIMIT 25) r
    LEFT JOIN configuration_revisions p ON p.head=r.parent
    LEFT JOIN LATERAL (
      SELECT count(*) OVER () AS total, path
      FROM jsonb_object_keys(r.files || COALESCE(p.files, '{}'::jsonb)) AS paths(path)
      WHERE (r.files->>path)::jsonb IS DISTINCT FROM (p.files->>path)::jsonb
      ORDER BY path LIMIT 3
    ) changes ON true
    ORDER BY r.id DESC, changes.path
    """).rows
    |> Enum.chunk_by(&hd/1)
    |> Enum.map(fn [[head, channel, at, total, _, _] | _] = rows ->
      %{
        head: head,
        channel: channel,
        inserted_at: at,
        changed_count: total || 0,
        names: for([_, _, _, _, path, name] <- rows, path, do: name)
      }
    end)
  end

  def detail(head, page \\ 1) do
    if is_binary(head) and Regex.match?(~r/\A[0-9a-f]{40}\z/, head) do
      case Repo.query!(
             """
             SELECT r.files, COALESCE(p.files, '{}'::jsonb)
             FROM configuration_revisions r LEFT JOIN configuration_revisions p ON p.head=r.parent
             WHERE r.head=$1
             """,
             [head]
           ).rows do
        [[current, previous]] ->
          paths = (Map.keys(current) ++ Map.keys(previous)) |> Enum.uniq() |> Enum.sort()

          changes =
            Enum.flat_map(paths, fn path ->
              before = decode(previous[path])
              after_value = decode(current[path])

              if before == after_value,
                do: [],
                else: [
                  %{
                    path: path,
                    before: before,
                    after: after_value,
                    action:
                      cond do
                        is_nil(before) -> "Added"
                        is_nil(after_value) -> "Removed"
                        true -> "Changed"
                      end
                  }
                ]
            end)

          pages = max(1, ceil(length(changes) / 10))
          page = min(max(page, 1), pages)

          %{
            head: head,
            total: length(changes),
            page: page,
            pages: pages,
            changes: Enum.slice(changes, (page - 1) * 10, 10)
          }

        [] ->
          nil
      end
    end
  end

  def field_changes(change) do
    before = change.before || %{}
    after_value = change.after || %{}
    keys = (Map.keys(before) ++ Map.keys(after_value)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      if key == "params" do
        first = before["params"] || %{}
        last = after_value["params"] || %{}

        (Map.keys(first) ++ Map.keys(last))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(fn parameter ->
          schema = after_value["parameter_schema"] || before["parameter_schema"] || %{}
          declaration = get_in(schema, ["fields", parameter]) || %{}
          unit = if declaration["unit"], do: " (#{declaration["unit"]})", else: ""
          label = (declaration["label"] || parameter) <> unit

          field_change(
            label,
            Map.get(first, parameter, :absent),
            Map.get(last, parameter, :absent)
          )
        end)
      else
        label = key |> String.replace("_", " ") |> String.capitalize()
        field_change(label, Map.get(before, key, :absent), Map.get(after_value, key, :absent))
      end
    end)
  end

  defp field_change(_label, value, value), do: []

  defp field_change(label, before, after_value),
    do: [%{label: label, before: compact(before), after: compact(after_value)}]

  defp compact(:absent), do: "Not present"
  defp compact(nil), do: "Not set"

  defp compact(value) do
    rendered = Jason.encode!(value)

    if String.length(rendered) > 180,
      do: String.slice(rendered, 0, 180) <> "… (see complete documents)",
      else: rendered
  end

  def display(nil), do: "Not present"
  def display(value), do: ConfigurationObjects.json(value)
  defp decode(nil), do: nil
  defp decode(body), do: Jason.decode!(body)
end
