# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.InventorySchemaEvolutionTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Configuration, Control, Inventory, ResultStream, Runner, SourceInventory}

  test "new source fields use defaults once while saved values, identity and incident history survive" do
    initial = inventory([check("delegated")])
    assert {:ok, _} = Monitoring.inventory(initial, at())
    original = assignment("delegated")
    assert {:ok, _} = Monitoring.save_assignment(original.id, 1, %{"limit" => 75})
    original = assignment("delegated")
    activate(original)
    first = result_report(original, 1, "CRIT")
    assert disposition(ingest(first)) == "current"
    original = assignment("delegated")
    stream = Repo.get_by!(ResultStream, assignment_id: original.id)
    incident = Repo.one!(Incident)
    notification = Repo.one!(Occurrence)

    added = inventory([extended_check("delegated")], 2)
    assert {:ok, %{"accepted_checks" => 1}} = Monitoring.inventory(added, at())
    changed = assignment("delegated")
    assert changed.id == original.id
    assert changed.revision == original.revision + 1
    assert changed.desired_generation == original.desired_generation + 1
    assert changed.params == %{"limit" => 75, "ceiling" => 100}
    assert changed.authorized_generation == original.authorized_generation
    assert changed.current == original.current
    assert Repo.get!(ResultStream, stream.id).current == stream.current
    assert Repo.get!(ResultStream, stream.id).retired_at == nil
    assert Repo.get!(Incident, incident.id) == incident
    assert Repo.get!(Occurrence, notification.id).payload == notification.payload
    assert Repo.get!(Observation, first["id"]).payload == first

    assert Repo.get_by!(Configuration,
             assignment_id: changed.id,
             generation: original.desired_generation
           ).params == %{"limit" => 75}

    assert Repo.get_by!(Configuration,
             assignment_id: changed.id,
             generation: changed.desired_generation
           ).params == changed.params

    assert hd(Repo.one!(SourceInventory).payload["checks"])["params"] == %{
             "limit" => 10,
             "ceiling" => 100
           }

    assert {:ok, response} = connect(%{"prepared" => %{}, "active" => %{}})
    wire = Enum.find(response["assignments"], &(&1["id"] == changed.id))
    assert wire["params"] == changed.params
    assert response["authorized"][changed.id] == original.desired_generation
    assert {:ok, _} = Monitoring.inventory(added, DateTime.add(at(), 1))
    assert assignment("delegated").revision == changed.revision

    assert {:error, :stale} =
             Monitoring.save_assignment(changed.id, original.revision, %{"limit" => 60})

    assert assignment("delegated").params == changed.params
    activate(changed)
    assert disposition(ingest(result_report(changed, 2, "CRIT"))) == "current"
    assert Repo.one!(Incident).id == incident.id
    assert Repo.one!(Incident).status == "open"

    assert {:ok, _} =
             Monitoring.save_assignment(changed.id, changed.revision, %{
               "limit" => 75,
               "ceiling" => 110
             })

    edited = assignment("delegated")
    activate(edited)
    recovery = result_report(edited, 3, "OK")
    assert disposition(ingest(recovery)) == "current"
    assert Repo.get!(Incident, incident.id).closure_reason == "configuration_changed"
    assert Repo.get!(Incident, incident.id).closing_observation_id == recovery["id"]
    assert Repo.get!(Incident, incident.id).opening_generation == original.desired_generation
    assert Repo.get!(Occurrence, notification.id).payload["observation_id"] == first["id"]

    new_defaults = put_in(extended_check("delegated"), ["params", "ceiling"], 150)
    assert {:ok, _} = Monitoring.inventory(inventory([new_defaults], 3), at())
    assert assignment("delegated").params == %{"limit" => 75, "ceiling" => 110}
    assert Repo.get_by!(ResultStream, assignment_id: edited.id).id == stream.id

    assert {:error, :stale} =
             Monitoring.save_assignment(edited.id, edited.revision, %{
               "limit" => 60,
               "ceiling" => 120
             })
  end

  test "incompatible merged values or fields roll back all source updates, additions and retirements" do
    assert {:ok, _} =
             Monitoring.inventory(
               inventory([check("delegated"), check("peer"), check("removed")]),
               at()
             )

    original = assignment("delegated")
    assert {:ok, _} = Monitoring.save_assignment(original.id, 1, %{"limit" => 75})
    original = assignment("delegated")
    activate(original)
    assert disposition(ingest(result_report(original, 1, "CRIT"))) == "current"
    removed = assignment("removed")
    activate(removed)
    assert disposition(ingest(result_report(removed, 2, "CRIT"))) == "current"
    baseline = persisted_state()

    valid = extended_check("delegated")

    removed_field = %{
      valid
      | "params" => %{"ceiling" => 100},
        "parameter_schema" => %{
          "fields" => %{"ceiling" => valid["parameter_schema"]["fields"]["ceiling"]}
        }
    }

    incompatible = [
      {"new comparison rejects saved value", put_in(valid, ["params", "ceiling"], 50)},
      {"changed bound rejects saved value",
       put_in(valid, ["parameter_schema", "fields", "limit", "maximum"], 50)},
      {"changed choices reject saved value",
       put_in(valid, ["parameter_schema", "fields", "limit", "choices"], [10, 20])},
      {"saved field removed", removed_field},
      {"type changed even though the saved integer satisfies number",
       put_in(valid, ["parameter_schema", "fields", "limit", "type"], "number")},
      {"unit reinterprets the same saved value",
       put_in(valid, ["parameter_schema", "fields", "limit", "unit"], "seconds")}
    ]

    for {scenario, bad_check} <- incompatible do
      changed_peer = Map.put(check("peer"), "label", "Peer update must roll back")
      # Removal runs before check reconciliation; peer/new updates precede the
      # failing check, proving this is a transaction rollback rather than a no-op.
      rejected = inventory([changed_peer, check("new"), bad_check], 2)
      assert Inventory.validate(rejected) == :ok, scenario
      assert {:error, {:invalid, reason}} = Monitoring.inventory(rejected, DateTime.add(at(), 2))
      assert is_binary(reason) and reason != "", scenario
      assert persisted_state() == baseline, scenario
    end

    # Rejected updates never replace the accepted generation or its raw evidence.
    following = result_report(original, 3, "CRIT")
    assert disposition(ingest(following)) == "current"
    assert assignment("delegated").current["confirmed_observation_id"] == following["id"]
    assert Repo.one!(SourceInventory).revision == 1
  end

  test "a compatible bound or comparison change validates preserved values rather than source defaults" do
    assert {:ok, _} = Monitoring.inventory(inventory([check("delegated")]), at())
    original = assignment("delegated")
    assert {:ok, _} = Monitoring.save_assignment(original.id, 1, %{"limit" => 75})

    compatible =
      extended_check("delegated")
      |> put_in(["parameter_schema", "fields", "limit", "maximum"], 80)
      |> put_in(["parameter_schema", "comparisons"], [
        %{"left" => "limit", "op" => "lte", "right" => "ceiling"}
      ])
      |> put_in(["params", "ceiling"], 75)

    assert {:ok, _} = Monitoring.inventory(inventory([compatible], 2), at())
    assert assignment("delegated").params == %{"limit" => 75, "ceiling" => 75}
  end

  defp persisted_state do
    Map.new(
      [
        Runner,
        Assignment,
        Configuration,
        SourceInventory,
        ResultStream,
        Incident,
        Occurrence,
        Control,
        Observation
      ],
      fn schema -> {schema, Repo.all(from row in schema, order_by: row.id)} end
    )
  end

  defp assignment(key),
    do: Repo.get_by!(Assignment, source_id: "schema-evolution", source_key: key)

  defp activate(a),
    do: connect(%{"prepared" => %{a.id => a.desired_generation}, "active" => %{}})

  defp inventory(checks, revision \\ 1) do
    control()
    |> Map.merge(%{
      "runner_label" => "Schema evolution node",
      "source_id" => "schema-evolution",
      "source_revision" =>
        :crypto.hash(:sha256, Integer.to_string(revision)) |> Base.encode16(case: :lower),
      "inventory_revision" => revision,
      "complete" => true,
      "checks" => checks
    })
  end

  defp check(key) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("a", 64),
      "params_owner" => "ui",
      "params" => %{"limit" => 80},
      "parameter_schema" => %{
        "fields" => %{
          "limit" => %{"type" => "integer", "unit" => "items", "minimum" => 0, "maximum" => 100}
        }
      },
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => "value",
          "label" => key,
          "target" => %{"key" => key, "kind" => "service", "label" => key}
        }
      ]
    }
  end

  defp extended_check(key) do
    check(key)
    |> Map.put("definition_revision", String.duplicate("b", 64))
    |> Map.put("params", %{"limit" => 10, "ceiling" => 100})
    |> put_in(["parameter_schema", "fields", "ceiling"], %{
      "type" => "integer",
      "unit" => "items",
      "minimum" => 1,
      "maximum" => 200
    })
    |> put_in(["parameter_schema", "comparisons"], [
      %{"left" => "limit", "op" => "lt", "right" => "ceiling"}
    ])
  end

  defp result_report(a, sequence, health) do
    measurement(health, sequence, %{
      "assignment_id" => a.id,
      "generation" => a.desired_generation,
      "results" => [
        %{
          "key" => "value",
          "health" => health,
          "summary" => "Schema evolution sample",
          "value" => 1,
          "source_at" => "2009-09-15T08:00:00.010000Z"
        }
      ]
    })
  end
end
