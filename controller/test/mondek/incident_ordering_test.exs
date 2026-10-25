# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.IncidentOrderingTest do
  use Mondek.DataCase, async: false

  alias Mondek.{ConditionIncident, ResultStream}

  test "one global page order puts active acknowledgement last, then severity, status, oldest age and ID" do
    acknowledged_critical =
      incident(%{
        health: "CRIT",
        opened_at: tick(-1000),
        acknowledgement_mode: "until_incident_ends"
      })

    warning_closed = incident(%{health: "WARN", status: "closed", opened_at: tick(-1000)})

    critical_tie_second =
      incident(%{
        id: "00000000-0000-4000-8000-000000000002",
        health: "CRIT",
        opened_at: tick(-100)
      })

    healthy = incident(%{health: "OK", opened_at: tick(-1000)})
    critical_recent = incident(%{health: "CRIT", opened_at: tick(-10)})
    critical_closed = incident(%{health: "CRIT", status: "closed", opened_at: tick(-1000)})
    warning_open = incident(%{health: "WARN", opened_at: tick(-500)})
    unknown = incident(%{health: "UNKNOWN", opened_at: tick(-1000)})

    critical_tie_first =
      incident(%{
        id: "00000000-0000-4000-8000-000000000001",
        health: "CRIT",
        opened_at: tick(-100)
      })

    acknowledged_warning =
      incident(%{
        health: "WARN",
        opened_at: tick(-1100),
        acknowledgement_mode: "until",
        acknowledged_until: tick(60)
      })

    expected = [
      critical_tie_first,
      critical_tie_second,
      critical_recent,
      critical_closed,
      warning_open,
      warning_closed,
      unknown,
      healthy,
      acknowledged_critical,
      acknowledged_warning
    ]

    pages =
      for page <- 1..4,
          do: Monitoring.list_incidents(%{status: "all", page_size: 3, page: page}, at())

    assert Enum.flat_map(pages, &Enum.map(&1.items, fn i -> i["id"] end)) ==
             Enum.map(expected, & &1.id)

    assert Enum.all?(
             pages,
             &(&1.total == 10 and &1.acknowledged_total == 2 and &1.unacknowledged_total == 8)
           )

    assert Enum.map(Enum.flat_map(pages, & &1.items), & &1["acknowledgement_active"]) ==
             List.duplicate(false, 8) ++ [true, true]

    assert hd(pages).items ==
             Monitoring.list_incidents(%{status: "all", page_size: 3}, at()).items

    open = Monitoring.list_incidents(%{page_size: 100}, at())
    assert open.total == 8
    assert open.acknowledged_total == 2
    assert Enum.all?(open.items, &(&1["status"] == "open"))
  end

  test "shared parent severity and acknowledgement govern deduplicated rows even when filters match an acknowledged warning contributor" do
    standalone = incident(%{health: "WARN", opened_at: tick(-500)})
    parent = group(%{health: "CRIT", opened_at: tick(-100)})

    incident(
      %{
        health: "WARN",
        condition_incident_id: parent.id,
        acknowledgement_mode: "until_incident_ends"
      },
      "only-warning"
    )

    incident(%{health: "CRIT", condition_incident_id: parent.id}, "critical-contribution")

    first = Monitoring.list_incidents(%{page_size: 1}, at())
    second = Monitoring.list_incidents(%{page_size: 1, page: 2}, at())
    assert first.total == 2 and first.acknowledged_total == 0

    assert [%{"id" => parent_id, "health" => "CRIT", "acknowledgement_active" => false}] =
             first.items

    assert parent_id == parent.id
    assert hd(first.items)["contribution_count"] == 2
    assert hd(second.items)["id"] == standalone.id

    filtered = Monitoring.list_incidents(%{search: "only-warning", page_size: 1}, at())
    assert filtered.total == 1 and filtered.acknowledged_total == 0
    assert hd(filtered.items)["id"] == parent.id
    assert hd(filtered.items)["health"] == "CRIT"
    assert hd(filtered.items)["matching_result_count"] == 1
    assert Monitoring.list_incidents(%{search: "only-warning", health: "WARN"}, at()).total == 0
    assert_counts(2, 0, at())

    Monitoring.change(parent, %{
      acknowledgement_mode: "until",
      acknowledged_until: tick(60),
      acknowledgement_ceiling: "CRIT"
    })

    reordered = Monitoring.list_incidents(%{page_size: 1}, at())
    assert hd(reordered.items)["id"] == standalone.id
    assert reordered.acknowledged_total == 1 and reordered.unacknowledged_total == 1
    acknowledged_page = Monitoring.list_incidents(%{page_size: 1, page: 2}, at())
    assert hd(acknowledged_page.items)["id"] == parent.id
    assert hd(acknowledged_page.items)["acknowledgement_active"]
    filtered = Monitoring.list_incidents(%{search: "only-warning"}, at())
    assert filtered.acknowledged_total == 1 and filtered.unacknowledged_total == 0
    assert_counts(2, 1, at())
  end

  test "listing and overview agree with acknowledgement modes at the exact expiry boundary, after ending and after closure" do
    modes = [
      %{acknowledgement_mode: "until", acknowledged_until: tick(-1)},
      %{acknowledgement_mode: "until", acknowledged_until: at()},
      %{acknowledgement_mode: "until", acknowledged_until: DateTime.add(at(), 1, :microsecond)},
      %{acknowledgement_mode: "until_incident_ends"},
      %{}
    ]

    standalone = Enum.map(modes, &incident/1)

    parents =
      Enum.map(modes, fn attrs ->
        parent = group(attrs)
        incident(%{condition_incident_id: parent.id, acknowledgement_mode: "until_incident_ends"})
        parent
      end)

    closed = incident(%{status: "closed"})
    closed_parent = group(%{status: "closed"})
    incident(%{status: "closed", condition_incident_id: closed_parent.id})
    operator_incidents = standalone ++ parents ++ [closed, closed_parent]

    for instant <- [at(), DateTime.add(at(), 1, :microsecond), tick(86_400)] do
      active = Enum.count(operator_incidents, &Monitoring.acknowledgement_active?(&1, instant))
      listed = Monitoring.list_incidents(%{status: "all", page_size: 100}, instant)
      assert listed.total == 12
      assert listed.acknowledged_total == active
      assert listed.unacknowledged_total == 12 - active

      assert Enum.all?(listed.items, fn item ->
               item["acknowledgement_active"] == Monitoring.acknowledgement_active?(item, instant)
             end)

      assert_counts(10, active, instant)
    end

    assert_counts(10, 4, at())
    boundary = DateTime.add(at(), 1, :microsecond)
    assert_counts(10, 2, boundary)

    # Ending one acknowledgement leaves the independent parent acknowledgement active.
    Monitoring.change(Enum.at(standalone, 3), %{
      acknowledgement_mode: nil,
      acknowledged_until: nil,
      acknowledgement_ceiling: nil
    })

    assert_counts(10, 1, boundary)
    active_parent = Enum.at(parents, 3)

    Monitoring.change(active_parent, %{
      status: "closed",
      closed_at: at(),
      closure_reason: "measured_recovery",
      acknowledgement_mode: nil,
      acknowledged_until: nil,
      acknowledgement_ceiling: nil
    })

    assert_counts(9, 0, boundary)
    # Whole-parent status also governs the row when a retained member still says open.
    listed = Monitoring.list_incidents(%{status: "closed", page_size: 100}, boundary)
    assert listed.total == 3 and listed.acknowledged_total == 0
    assert Enum.all?(listed.items, &(not &1["acknowledgement_active"]))
  end

  test "overview and filtered listing counts remain complete beyond the visible page and deduplicate shared members" do
    for _ <- 1..130, do: incident(%{health: "CRIT"})
    for _ <- 1..80, do: incident(%{acknowledgement_mode: "until_incident_ends"})
    for _ <- 1..5, do: incident(%{status: "closed"})
    acknowledged = group(%{acknowledgement_mode: "until_incident_ends"})
    unacknowledged = group()

    for _ <- 1..5 do
      incident(%{condition_incident_id: acknowledged.id})

      incident(%{
        condition_incident_id: unacknowledged.id,
        acknowledgement_mode: "until_incident_ends"
      })
    end

    assert_counts(212, 81, at())
    page = Monitoring.list_incidents(%{page_size: 3, page: 2}, at())
    assert length(page.items) == 3

    assert page.total == 212 and page.acknowledged_total == 81 and
             page.unacknowledged_total == 131

    assert Enum.all?(page.items, &(not &1["acknowledgement_active"]))
    all = Monitoring.list_incidents(%{status: "all", page_size: 1}, at())
    assert all.total == 217 and all.acknowledged_total == 81 and all.unacknowledged_total == 136
  end

  defp assert_counts(total, acknowledged, instant) do
    overview = Monitoring.overview(instant)
    assert overview["open_incident_count"] == total
    assert overview["acknowledged_incident_count"] == acknowledged
    assert overview["unacknowledged_incident_count"] == total - acknowledged
  end

  defp incident(attrs, label \\ "Ordering result") do
    key = Ecto.UUID.generate()

    stream =
      Repo.insert!(%ResultStream{
        assignment_id: "10000000-0000-4000-8000-000000000001",
        result_key: key,
        label: label,
        target: %{"key" => key, "label" => label},
        environment: "ordering"
      })

    evidence =
      Repo.insert!(%Observation{
        id: Ecto.UUID.generate(),
        assignment_id: "10000000-0000-4000-8000-000000000001",
        installation_id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        generation: 1,
        sequence: 1,
        started_at: at(),
        evaluated_at: at(),
        received_at: at(),
        payload: %{},
        disposition: "current"
      })

    defaults = %{
      assignment_id: "10000000-0000-4000-8000-000000000001",
      stream_id: stream.id,
      result_key: key,
      environment: "ordering",
      environment_label: "Ordering",
      health: "WARN",
      opened_at: tick(-60),
      opening_generation: 1,
      opening_observation_id: evidence.id,
      latest_observation_id: evidence.id
    }

    attrs = Map.merge(defaults, attrs) |> acknowledgement() |> closure()
    Repo.insert!(struct!(Incident, attrs))
  end

  defp group(attrs \\ %{}) do
    defaults = %{
      namespace: "ordering",
      key: Ecto.UUID.generate(),
      environment: "ordering",
      label: "Shared ordering incident",
      health: "WARN",
      opened_at: tick(-60)
    }

    attrs = Map.merge(defaults, attrs) |> acknowledgement() |> closure()
    Repo.insert!(struct!(ConditionIncident, attrs))
  end

  defp acknowledgement(%{acknowledgement_mode: mode} = attrs)
       when mode in ["until", "until_incident_ends"],
       do: Map.put(attrs, :acknowledgement_ceiling, attrs.health)

  defp acknowledgement(attrs), do: attrs

  defp closure(%{status: "closed"} = attrs),
    do: Map.merge(attrs, %{closed_at: tick(-1), closure_reason: "measured_recovery"})

  defp closure(attrs), do: attrs
  defp tick(seconds), do: DateTime.add(at(), seconds)
end
