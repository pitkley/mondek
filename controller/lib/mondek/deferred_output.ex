# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DeferredOutput do
  @moduledoc "Exact, temporary ownership claims that carry no measurement authority."
  import Ecto.Query

  alias Mondek.{Assignment, Monitoring, Repo, ResultStream, Runner}

  @lifetime_seconds 300

  def project(state, %{"deferral" => owner, "summary" => reason}, assignment, stream) do
    claim = Map.merge(owner, %{"reason" => reason, "evaluated_at" => state["evaluated_at"]})

    pinned =
      if assignment.source_id && owner["check_key"] != assignment.source_key do
        Repo.one(
          from s in ResultStream,
            join: a in Assignment,
            on: a.id == s.assignment_id,
            where:
              a.runner_id == ^assignment.runner_id and a.source_id == ^assignment.source_id and
                a.source_key == ^owner["check_key"] and s.result_key == ^owner["output_key"] and
                fragment(
                  "? IS NOT DISTINCT FROM ?",
                  s.environment,
                  type(^stream.environment, :string)
                ) and
                is_nil(a.retired_at) and is_nil(s.retired_at),
            select: %{
              "owner_stream_id" => s.id,
              "owner_assignment_id" => a.id,
              "owner_generation" => a.authorized_generation
            }
        )
      end

    Map.put(state, "deferral", Map.merge(claim, pinned || %{}))
  end

  def project(state, _, _, _), do: state

  def covering_until([], _at), do: %{}

  def covering_until(rows, at) do
    claims = Enum.filter(rows, &get_in(&1, ["deferral", "owner_stream_id"]))
    ids = Enum.map(claims, &get_in(&1, ["deferral", "owner_stream_id"])) |> Enum.uniq()
    owners = if ids == [], do: %{}, else: owners(ids)

    Map.new(claims, fn row ->
      claim = row["deferral"]
      owner = owners[claim["owner_stream_id"]]
      {row["key"], valid_until(row, claim, owner, at)}
    end)
  end

  defp owners(ids) do
    Repo.all(
      from s in ResultStream,
        join: a in Assignment,
        on: a.id == s.assignment_id,
        join: r in Runner,
        on: r.id == a.runner_id,
        where: s.id in ^ids and is_nil(s.retired_at) and is_nil(a.retired_at),
        select:
          {s.id, s.current, a.authorized_generation, a.freshness_seconds, r.session_id,
           r.last_seen_at}
    )
    |> Map.new(fn {id, current, generation, freshness, session, contact} ->
      mapping = %{
        current: current,
        generation: generation,
        freshness: freshness,
        session: session,
        contact: contact
      }

      {id, mapping}
    end)
  end

  defp valid_until(_, _, nil, _), do: nil

  defp valid_until(row, claim, owner, at) do
    current = owner.current

    if owner.generation == claim["owner_generation"] and is_nil(current["deferral"]) and
         current["generation"] == owner.generation and
         current["confirmed_generation"] == owner.generation and
         current["session_id"] == owner.session and
         current["confirmed_session_id"] == owner.session and
         current["knowledge"] == "fresh" and not is_nil(current["confirmed_observation_id"]) and
         not is_nil(current["source_at"]) and not is_nil(owner.contact) do
      until =
        Enum.min(
          [
            row["since_at"] |> Monitoring.parse!() |> DateTime.add(@lifetime_seconds),
            claim["evaluated_at"] |> Monitoring.parse!() |> DateTime.add(@lifetime_seconds),
            current["source_at"]
            |> Monitoring.parse!()
            |> DateTime.add(ceil(owner.freshness * 1_000_000), :microsecond),
            DateTime.add(owner.contact, Mondek.MonitoringLoss.contact_seconds())
          ],
          DateTime
        )

      if DateTime.after?(until, at), do: until
    end
  end
end
