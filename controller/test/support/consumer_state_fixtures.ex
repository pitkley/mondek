# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConsumerStateFixtures do
  alias Mondek.CoverageFixtures, as: F

  def observer do
    p = F.publication([F.candidate(F.check())], %{"source_id" => "state-test"})
    {:ok, _} = Mondek.Monitoring.inventory(p)
    {:ok, _} = F.activate(p, Mondek.Monitoring.now())
    [a] = F.assignments(p)

    Map.merge(Map.take(p, ~w(version installation_id session_id boot source_id)), %{
      "assignment_id" => a.id,
      "generation" => a.desired_generation,
      "operation" => "get",
      "scope" => "source",
      "key" => "peers"
    })
  end
end
