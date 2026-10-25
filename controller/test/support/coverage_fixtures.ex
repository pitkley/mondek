# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CoverageFixtures do
  import Ecto.Query
  alias Mondek.{Repo, Assignment, Monitoring}
  import Mondek.Fixtures

  def check(key \\ "service", environment \\ "production", target \\ "service") do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => environment,
      "environment_label" => environment,
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => "health",
          "label" => "Health",
          "target" => %{"key" => target, "label" => target, "kind" => "service"}
        }
      ]
    }
  end

  def candidate(check, selected \\ true) do
    Map.take(check, ~w(key label environment environment_label outputs))
    |> Map.merge(%{
      "selected" => selected,
      "exclusion_reason" =>
        if(selected, do: nil, else: "Observer lacks service-query capability"),
      "scope_resolved" => true,
      "scope_reason" => nil,
      "definition_revision" => String.duplicate("c", 64)
    })
  end

  def publication(candidates, overrides \\ %{}) do
    checks =
      Enum.filter(candidates, & &1["selected"])
      |> Enum.map(fn c ->
        check(c["key"], c["environment"], hd(c["outputs"])["target"]["key"])
        |> Map.merge(Map.take(c, ~w(key label environment environment_label outputs)))
      end)

    %{
      "version" => 1,
      "installation_id" => Ecto.UUID.generate(),
      "session_id" => Ecto.UUID.generate(),
      "boot" => 1,
      "runner_label" => "Observer",
      "source_id" => "coverage-test",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => checks,
      "coverage" => %{
        "version" => 1,
        "code_revision" => String.duplicate("d", 64),
        "runtime_revision" => String.duplicate("e", 64),
        "runner_context" => %{
          "id" => "observer",
          "label" => "Observer",
          "local_environment" => nil,
          "target" => nil,
          "capabilities" => []
        },
        "candidates" => candidates
      }
    }
    |> Map.merge(overrides)
  end

  def assignments(p),
    do:
      Repo.all(
        from a in Assignment,
          where:
            a.runner_id == ^p["installation_id"] and a.source_id == ^p["source_id"] and
              is_nil(a.retired_at),
          order_by: a.source_key
      )

  def activate(p, at \\ at()) do
    prepared = Map.new(assignments(p), &{&1.id, &1.desired_generation})

    Monitoring.control(
      control(
        Map.merge(Map.take(p, ~w(installation_id session_id boot)), %{
          "prepared" => prepared,
          "active" => %{}
        })
      ),
      at
    )
  end

  def sample(p, health \\ "OK", sequence \\ 1, at \\ at()) do
    [a] = assignments(p)
    output = hd(a.outputs)

    report =
      measurement(health, sequence, %{
        "assignment_id" => a.id,
        "installation_id" => p["installation_id"],
        "session_id" => p["session_id"],
        "generation" => a.desired_generation,
        "started_at" => Monitoring.iso(at),
        "evaluated_at" => Monitoring.iso(at),
        "results" => [
          %{
            "key" => output["key"],
            "health" => health,
            "summary" => "Measured #{health}",
            "value" => 90,
            "source_at" => Monitoring.iso(at)
          }
        ]
      })

    Monitoring.ingest(envelope([report], Map.take(p, ~w(installation_id session_id))), at)
  end
end
