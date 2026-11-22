# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationCandidates do
  @moduledoc "Read-only inspection of hinted dependencies for an open health episode."
  import Ecto.Query

  alias Mondek.{
    Assignment,
    ConditionIncident,
    Configuration,
    Incident,
    Monitoring,
    Repo,
    ResultStream
  }

  @members 16
  @hints 32
  @candidates 20
  @matches 4
  @contributors 4

  def for_episode(type, id) when type in ["individual", "condition"] and is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {canonical, episode} <- subject(type, uuid) do
      inspect_episode(canonical, episode)
    else
      _ -> nil
    end
  end

  def for_episode(_, _), do: nil

  defp subject("individual", id) do
    case Repo.get(Incident, id) do
      %Incident{condition_incident_id: nil} = i -> {"individual", i}
      %Incident{condition_incident_id: group} -> subject("condition", group)
      nil -> nil
    end
  end

  defp subject("condition", id) do
    if group = Repo.get(ConditionIncident, id), do: {"condition", group}
  end

  defp inspect_episode(type, episode) do
    base = %{
      "subject" => %{"type" => type, "id" => episode.id},
      "status" => "unavailable",
      "truncated" => false,
      "conflicting_hints" => false,
      "hint_count" => 0,
      "candidates" => []
    }

    if episode.status == "open" do
      evidence = contributions(type, episode.id)
      members = Enum.take(evidence, @members)
      hints = Enum.flat_map(members, &opening_hints/1)

      grouped =
        hints
        |> Enum.flat_map(fn {ref, hs} -> Enum.map(hs, &{&1, ref}) end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()

      searched = Enum.take(grouped, @hints)
      {candidates, more?} = candidates(episode, searched)
      truncated = more? or length(evidence) > @members or length(grouped) > @hints

      status =
        cond do
          hints == [] -> "unavailable"
          truncated or length(hints) < length(members) -> "incomplete"
          true -> "complete"
        end

      %{
        base
        | "status" => status,
          "truncated" => truncated,
          "candidates" => candidates,
          "hint_count" => length(searched),
          "conflicting_hints" => length(Enum.uniq_by(hints, fn {_, hs} -> Enum.sort(hs) end)) > 1
      }
    else
      base
    end
  end

  defp contributions(type, id) do
    scope =
      if type == "condition",
        do: dynamic([i], i.condition_incident_id == ^id),
        else: dynamic([i], i.id == ^id)

    Repo.all(
      from i in Incident,
        left_join: c in Configuration,
        on: c.assignment_id == i.assignment_id and c.generation == i.opening_generation,
        where: i.status == "open",
        where: ^scope,
        order_by: i.id,
        limit: ^(@members + 1),
        select: {i.id, i.assignment_id, i.opening_generation, i.result_key, c.definition}
    )
  end

  defp opening_hints({id, assignment, generation, key, %{"outputs" => outputs}})
       when is_list(outputs) do
    with %{} = output <- Enum.find(outputs, &(&1["key"] == key)),
         hints = Map.get(output, "correlation_hints", []),
         true <- Mondek.Protocol.correlation_hints?(hints) do
      [{%{"incident_id" => id, "assignment_id" => assignment, "generation" => generation}, hints}]
    else
      _ -> []
    end
  end

  defp opening_hints(_), do: []

  defp candidates(subject, hints) do
    {rows, truncated} =
      Enum.reduce(hints, {[], false}, fn {hint, refs}, {acc, truncated} ->
        matches = matching_parents(subject, hint, refs)

        found =
          Enum.flat_map(matches, fn p ->
            refs
            |> Enum.filter(&Map.has_key?(p.overlaps, &1["incident_id"]))
            |> Enum.group_by(fn ref ->
              if p.overlaps[ref["incident_id"]], do: "overlap", else: "later_opening"
            end)
            |> Enum.map(fn {timing, contributors} ->
              {p, p.distance,
               Map.merge(hint, %{"contributors" => contributors, "timing" => timing})}
            end)
          end)

        {found ++ acc, truncated or length(matches) > @candidates}
      end)

    grouped =
      rows
      |> Enum.group_by(fn {p, _, _} -> {p.type, p.id} end)
      |> Enum.sort_by(fn {identity, entries} ->
        {Enum.min(Enum.map(entries, &elem(&1, 1))), identity}
      end)
      |> Enum.map(fn {_, [{p, _, _} | _] = entries} -> {p, Enum.map(entries, &elem(&1, 2))} end)

    returned = Enum.take(grouped, @candidates)

    evidence_cut =
      Enum.any?(returned, fn {_, matches} ->
        length(matches) > @matches or
          Enum.any?(matches, &(length(&1["contributors"]) > @contributors))
      end)

    items =
      returned
      |> Enum.map(fn {p, matches} ->
        %{
          "type" => p.type,
          "id" => p.id,
          "label" => p.label,
          "health" => p.health,
          "opened_at" => Monitoring.iso(p.opened_at),
          "matches" =>
            matches
            |> Enum.sort()
            |> Enum.take(@matches)
            |> Enum.map(
              &Map.update!(&1, "contributors", fn refs -> Enum.take(refs, @contributors) end)
            )
        }
      end)

    {items, evidence_cut or truncated or length(grouped) > @candidates}
  end

  defp matching_parents(subject, hint, refs) do
    query = parents(hint["depends_on"])
    subject_type = if is_struct(subject, ConditionIncident), do: "condition", else: "individual"
    contributor_ids = Enum.map(refs, & &1["incident_id"])
    seconds = hint["window_seconds"]

    # A Condition can gain measured contributions at different times. For each
    # declaring incident choose the closest qualifying upstream contribution,
    # then rank canonical parents by their closest eligible pair.
    pairs =
      from p in subquery(query),
        join: child in Incident,
        on: child.id in ^contributor_ids,
        where:
          fragment("? IS NOT DISTINCT FROM ?", p.environment, type(^subject.environment, :string)),
        where: p.type != ^subject_type or p.id != ^subject.id,
        where: p.matched_at <= datetime_add(child.opened_at, ^seconds, "second"),
        distinct: [p.type, p.id, child.id],
        select: %{
          type: p.type,
          id: p.id,
          label: p.label,
          health: p.health,
          opened_at: p.opened_at,
          contributor_id: child.id,
          overlap: p.matched_at <= child.opened_at,
          distance:
            type(
              fragment(
                "(abs(extract(epoch from (? - ?))) * 1000000)::bigint",
                p.matched_at,
                child.opened_at
              ),
              :integer
            )
            |> selected_as(:distance)
        },
        order_by: [asc: selected_as(:distance), asc: p.matched_at]

    Repo.all(
      from pair in subquery(pairs),
        group_by: [pair.type, pair.id, pair.label, pair.health, pair.opened_at],
        order_by: [asc: min(pair.distance), asc: pair.type, asc: pair.id],
        limit: ^(@candidates + 1),
        select: %{
          id: pair.id,
          type: pair.type,
          label: pair.label,
          health: pair.health,
          opened_at: pair.opened_at,
          distance: min(pair.distance),
          overlaps:
            type(
              fragment("jsonb_object_agg(?::text, ?)", pair.contributor_id, pair.overlap),
              :map
            )
        }
    )
  end

  defp parents(%{"type" => "condition", "namespace" => ns, "key" => key}) do
    from g in ConditionIncident,
      where: g.status == "open" and g.namespace == ^ns and g.key == ^key,
      select: %{
        type: "condition",
        id: g.id,
        environment: g.environment,
        label: g.label,
        health: g.health,
        matched_at: g.opened_at,
        opened_at: g.opened_at
      }
  end

  # Placement identity is immutable on a stream. Inventory changes to its target
  # kind/key or environment create a successor with a different stream ID.
  defp parents(%{"type" => "target", "source_id" => source, "kind" => kind, "key" => key}) do
    from i in Incident,
      join: a in Assignment,
      on: a.id == i.assignment_id,
      join: s in ResultStream,
      on: s.id == i.stream_id,
      left_join: g in ConditionIncident,
      on: g.id == i.condition_incident_id,
      where: i.status == "open" and a.source_id == ^source,
      where: is_nil(i.condition_incident_id) or g.status == "open",
      where: fragment("? @> ?", s.target, type(^%{"kind" => kind, "key" => key}, :map)),
      select: %{
        type:
          type(
            fragment("CASE WHEN ? IS NULL THEN 'individual' ELSE 'condition' END", g.id),
            :string
          ),
        id: coalesce(g.id, i.id),
        environment: i.environment,
        label: coalesce(g.label, a.label),
        health: coalesce(g.health, i.health),
        matched_at: i.opened_at,
        opened_at: coalesce(g.opened_at, i.opened_at)
      }
  end
end
