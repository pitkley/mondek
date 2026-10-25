# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.InventoryConditionLockTest do
  use Mondek.DataCase, async: false

  alias Mondek.{ConditionIncident, Conditions, Maintenance, MaintenanceWindow}

  @condition %{
    "namespace" => "shared-infrastructure",
    "key" => "storage-pressure",
    "label" => "Storage pressure"
  }

  test "source update locks assignments before conditions while bulk maintenance holds a check" do
    assert {:ok, _} = connect()
    legacy = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    peer_control =
      control(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "prepared" => %{}
      })

    assert {:ok, _} =
             Monitoring.inventory(inventory(peer_control, "peer-source", check("peer")), at())

    peer = Repo.get_by!(Assignment, source_id: "peer-source")

    assert {:ok, _} =
             Monitoring.control(Map.put(peer_control, "prepared", %{peer.id => 1}), at())

    sample =
      measurement("CRIT", 1, %{
        "assignment_id" => peer.id,
        "installation_id" => peer_control["installation_id"],
        "session_id" => peer_control["session_id"]
      })

    assert disposition(
             Monitoring.ingest(
               envelope([sample], Map.take(peer_control, ~w(installation_id session_id))),
               at()
             )
           ) == "current"

    group = Repo.one!(ConditionIncident)
    [stripe] = Conditions.lock_stripes([group])
    {:ok, seed} = Maintenance.seed(legacy.id, nil, at())

    proposal =
      Map.merge(seed["proposal"], %{
        "scope" => "selection",
        "assignment_id" => nil,
        "source_id" => nil,
        "environment" => nil,
        "target_kind" => nil,
        "target_key" => nil,
        "selections" =>
          Enum.map([legacy.id, peer.id], &%{"scope" => "check", "assignment_id" => &1}),
        "reason" => "Coordinated storage maintenance"
      })

    assert {:ok, review} = Maintenance.preview(proposal, 1, at())

    adoption =
      check("adopted-disk")
      |> Map.merge(%{
        "key" => legacy.source_key,
        "params_owner" => legacy.params_owner,
        "params" => legacy.params,
        "parameter_schema" => %{
          "fields" => %{
            "path" => %{"type" => "string", "choices" => [legacy.params["path"]]},
            "warn_percent" => %{"type" => "number", "minimum" => 0, "maximum" => 100},
            "crit_percent" => %{"type" => "number", "minimum" => 0, "maximum" => 100}
          }
        }
      })

    owner = self()

    maintenance_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Maintenance.lock!()

          Enum.each(
            Enum.sort([legacy.source_id, peer.source_id]),
            &Mondek.ConfigurationRules.lock_source!/1
          )

          Monitoring.lock_assignment(legacy.id)
          send(owner, {:maintenance_holds_legacy, backend_pid()})

          receive do
            :save -> Maintenance.apply(review["review_token"], proposal, at())
          after
            5000 -> raise "Maintenance save was not released"
          end
        end)
      end)

    assert_receive {:maintenance_holds_legacy, maintenance_pid}, 1000

    inventory_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          send(owner, {:inventory_backend, backend_pid()})
          Monitoring.inventory(inventory(control(), legacy.source_id, adoption), at())
        end)
      end)

    try do
      assert_receive {:inventory_backend, inventory_pid}, 1000
      await_blocked(inventory_pid, maintenance_pid, System.monotonic_time(:millisecond) + 2000)

      # This is the decisive lock-order assertion. The previous implementation
      # held this stripe while waiting for the legacy row, creating the other
      # half of a deadlock when the real maintenance save reached wake!.
      %{rows: [[false]]} =
        Repo.query!(
          """
          SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='advisory'
            AND classid=931741 AND objid=$2 AND objsubid=2 AND granted)
          """,
          [inventory_pid, stripe]
        )

      send(maintenance_task.pid, :save)
      assert {:ok, {:ok, saved}} = Task.await(maintenance_task, 5000)
      assert {:ok, {:ok, _}} = Task.await(inventory_task, 5000)
      assert Repo.get!(MaintenanceWindow, saved["id"]).scope == "selection"
      assert Repo.get!(Assignment, legacy.id).source_id == legacy.source_id
      assert Repo.get!(ConditionIncident, group.id).status == "open"
      assert Repo.aggregate(ConditionIncident, :count) == 1
    after
      send(maintenance_task.pid, :save)
      Task.shutdown(inventory_task, :brutal_kill)
      Task.shutdown(maintenance_task, :brutal_kill)
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocked(waiter, blocker, deadline) do
    %{rows: [[blocked]]} =
      Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [blocker, waiter])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "Inventory must reach the assignment row held by maintenance"

      await_blocked(waiter, blocker, deadline)
    end
  end

  defp inventory(connection, source, check) do
    Map.merge(connection, %{
      "runner_label" => source,
      "source_id" => source,
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [check]
    })
  end

  defp check(key) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => "capacity",
          "label" => key,
          "target" => %{"kind" => "volume", "key" => key, "label" => key},
          "condition" => @condition
        }
      ]
    }
  end
end
