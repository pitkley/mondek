# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.IncidentEvidence do
  @moduledoc "Bounded historical failure selection, independent of current result state."
  import Ecto.Query
  alias Mondek.{Repo, Observation, Occurrence, ResultStream, Configuration, Monitoring}

  def resolve_many([]), do: %{}

  def resolve_many(incidents) do
    ids = Enum.map(incidents, & &1.id)
    # One retained notification reference per incident is an honest legacy fallback,
    # not proof of latest failure: unchanged failures historically created no notice.
    notices =
      Repo.all(
        from o in Occurrence,
          where: o.incident_id in ^ids and o.kind in ["firing", "update"],
          distinct: o.incident_id,
          order_by: [asc: o.incident_id, desc: o.inserted_at, desc: o.id]
      )
      |> Map.new(&{&1.incident_id, &1.payload["observation_id"]})

    candidates =
      Map.new(incidents, fn i ->
        {i.id,
         [
           {"latest_failure", i.latest_failure_observation_id},
           {"opening_failure", i.opening_observation_id},
           {"notification_reference", notices[i.id]}
         ]}
      end)

    requested_keys =
      Enum.flat_map(incidents, fn incident ->
        for {_role, id} <- candidates[incident.id], not is_nil(id), do: {id, incident.result_key}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {id, keys} -> {id, Enum.uniq(keys)} end)

    observation_ids = Map.keys(requested_keys)

    # Select only requested outputs in PostgreSQL; sibling payloads can be large
    # and are outside an incident reader's evidence scope.
    observations =
      Repo.all(
        from o in Observation,
          where: o.id in ^observation_ids,
          select: %Observation{
            id: o.id,
            assignment_id: o.assignment_id,
            installation_id: o.installation_id,
            session_id: o.session_id,
            generation: o.generation,
            sequence: o.sequence,
            started_at: o.started_at,
            evaluated_at: o.evaluated_at,
            received_at: o.received_at,
            disposition: o.disposition,
            payload:
              fragment(
                "jsonb_build_object('results', (SELECT coalesce(jsonb_agg(result), '[]'::jsonb) FROM jsonb_array_elements(?->'results') AS result WHERE result->>'key' IN (SELECT jsonb_array_elements_text(?->(?::text)))))",
                o.payload,
                type(^requested_keys, :map),
                o.id
              )
          }
      )
      |> Map.new(&{&1.id, &1})

    stream_ids = Enum.map(incidents, & &1.stream_id) |> Enum.reject(&is_nil/1)

    streams =
      Repo.all(from s in ResultStream, where: s.id in ^stream_ids) |> Map.new(&{&1.id, &1})

    assignment_ids = Enum.map(incidents, & &1.assignment_id) |> Enum.uniq()
    generations = Enum.map(Map.values(observations), & &1.generation) |> Enum.uniq()

    configurations =
      Repo.all(
        from c in Configuration,
          where: c.assignment_id in ^assignment_ids and c.generation in ^generations,
          select: %{
            assignment_id: c.assignment_id,
            generation: c.generation,
            definition:
              fragment(
                "jsonb_build_object('source_revision', ?->'source_revision', 'definition_revision', ?->'definition_revision')",
                c.definition,
                c.definition
              )
          }
      )
      |> Map.new(&{{&1.assignment_id, &1.generation}, &1.definition})

    Map.new(incidents, fn incident ->
      {incident.id,
       select(
         candidates[incident.id],
         incident,
         streams[incident.stream_id],
         observations,
         configurations
       )}
    end)
  end

  defp select(candidates, incident, stream, observations, configurations) do
    Enum.reduce_while(
      candidates,
      %{"status" => "unavailable", "basis" => nil, "measurement" => nil, "gaps" => []},
      fn {role, id}, state ->
        observation = observations[id]

        result =
          observation &&
            Enum.find(observation.payload["results"] || [], &(&1["key"] == incident.result_key))

        reason =
          cond do
            is_nil(id) -> "missing_reference"
            is_nil(observation) -> "observation_unavailable"
            not in_scope?(observation, incident, stream) -> "out_of_scope"
            is_nil(result) -> "result_not_in_observation"
            result["health"] not in ["WARN", "CRIT"] -> "not_a_failure"
            true -> nil
          end

        if reason do
          gap = %{"role" => role, "observation_id" => id, "reason" => reason}
          {:cont, Map.update!(state, "gaps", &(&1 ++ [gap]))}
        else
          definition = configurations[{observation.assignment_id, observation.generation}] || %{}

          measurement =
            result
            |> Map.take(~w(health summary details value source_at impacts))
            |> Map.merge(%{
              "result_key" => incident.result_key,
              "details" => result["details"],
              "source_at" => result["source_at"],
              "observation_id" => id,
              "evaluated_at" => Monitoring.iso(observation.evaluated_at),
              "received_at" => Monitoring.iso(observation.received_at),
              "provenance" => %{
                "assignment_id" => observation.assignment_id,
                "stream_id" => incident.stream_id,
                "installation_id" => observation.installation_id,
                "session_id" => observation.session_id,
                "generation" => observation.generation,
                "sequence" => observation.sequence,
                "disposition" => observation.disposition,
                "source_revision" => definition["source_revision"],
                "definition_revision" => definition["definition_revision"]
              }
            })

          {:halt,
           %{state | "status" => "available", "basis" => role, "measurement" => measurement}}
        end
      end
    )
  end

  defp in_scope?(o, i, s) do
    (not is_nil(s) and o.assignment_id == i.assignment_id) && s.assignment_id == i.assignment_id &&
      s.result_key == i.result_key &&
      o.generation >= s.admission_generation &&
      (is_nil(s.retirement_generation) or o.generation < s.retirement_generation) &&
      o.generation >= i.opening_generation && o.disposition == "current" &&
      DateTime.compare(o.received_at, i.opened_at) != :lt &&
      (is_nil(i.closed_at) or DateTime.compare(o.received_at, i.closed_at) != :gt)
  end
end
