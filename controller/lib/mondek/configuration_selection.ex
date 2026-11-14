# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationSelection do
  @moduledoc "Small bounded display snapshots for selected checks outside the current inventory page."
  import Ecto.Query
  alias Mondek.{Assignment, Repo, Runner}

  @keys ~w(id label runner_id runner_label source_id environment environment_label)
  def cache(selection, visible, previous) when map_size(selection) <= 512 do
    known =
      Map.merge(previous, Map.new(visible, &{&1["id"], Map.take(&1, @keys)}))
      |> Map.take(Map.keys(selection))

    missing = Map.keys(selection) -- Map.keys(known)

    loaded =
      if missing == [],
        do: [],
        else:
          Repo.all(
            from a in Assignment,
              left_join: r in Runner,
              on: r.id == a.runner_id,
              where: a.id in ^missing,
              select: %{
                "id" => a.id,
                "label" => a.label,
                "runner_id" => a.runner_id,
                "runner_label" => r.label,
                "source_id" => a.source_id,
                "environment" => a.environment,
                "environment_label" => a.environment_label
              }
          )

    Map.merge(known, Map.new(loaded, &{&1["id"], &1}))
  end
end
