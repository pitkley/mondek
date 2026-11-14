# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ChecksPresentationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}
  @endpoint MondekWeb.Endpoint

  test "one result table keeps measured health and collection gaps independent" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    assert length(rows(view)) == 6

    for {key, health, collection} <- [
          {"critical", "Critical", "Fresh"},
          {"retained", "Critical", "Overdue"},
          {"healthy", "Healthy", "Fresh"},
          {"pending-a", "Not measured", "Awaiting"}
        ] do
      assert has_element?(view, "#result-row-#{stream(key).id}", health)
      assert has_element?(view, "#result-row-#{stream(key).id}", collection)
    end

    retained = Repo.get!(ResultStream, stream("retained").id).current
    send(view.pid, :tick)
    assert Repo.get!(ResultStream, stream("retained").id).current == retained
  end

  test "health and measurement chips compose instead of task-specific tabs" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    choose(view, "health", "CRIT")
    assert length(rows(view)) == 2
    choose(view, "freshness", "stale")
    assert rows(view) == ["result-row-" <> stream("retained").id]
    assert has_element?(view, ".preview-filter-chip", "Critical")
    assert has_element?(view, ".preview-filter-chip", "Overdue")
  end

  test "search and clearing text preserve the selected health filter" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?health=CRIT&search=presentation-")
    render_change(view, "search", %{"search" => "absent"})
    assert has_element?(view, ".preview-empty", "No check results match")
    assert has_element?(view, ".preview-filter-chip", "Critical")
    render_change(view, "search", %{"search" => ""})
    assert length(rows(view)) == 2
    assert has_element?(view, ".preview-filter-chip", "Critical")
  end

  test "target filtering and reopening preserve exact target scope" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?target_kind=host&target_key=b")

    assert Enum.sort(rows(view)) ==
             Enum.sort(Enum.map(["retained", "pending-b"], &("result-row-" <> stream(&1).id)))

    view |> element("#open-result-#{stream("retained").id}") |> render_click()
    path = assert_patch(view)
    assert has_element?(view, "#overview-panel")
    {:ok, reopened, _} = live(build_conn(), path)
    assert has_element?(reopened, "#overview-panel")
    assert rows(reopened) == rows(view)
  end

  test "text recovery cannot replay stale incidental dropdown controls" do
    mixed_inventory()
    {:ok, view, _} = live(build_conn(), "/checks?health=CRIT")

    render_change(view, "search", %{
      "search" => "presentation-retained",
      "health" => "OK",
      "freshness" => "fresh"
    })

    assert rows(view) == ["result-row-" <> stream("retained").id]
    assert has_element?(view, ".preview-filter-chip", "Critical")
  end

  test "priority ordering changes with evidence while group identity stays stable" do
    mixed_inventory()
    options = Mondek.ChecksFilters.options("group", "")
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    [first | _] = rows(view)
    assert first in Enum.map(["critical", "retained"], &("result-row-" <> stream(&1).id))
    measure("healthy", "CRIT", "fresh")
    send(view.pid, :tick)
    assert Mondek.ChecksFilters.options("group", "") == options
    assert has_element?(view, "#result-row-#{stream("healthy").id}", "Critical")
  end

  test "same-named result labels still expose their scheduled check identity" do
    checks =
      for key <- ["first", "second"],
          do:
            check(key, "a")
            |> Map.put("outputs", [
              %{
                "key" => "capacity",
                "label" => "Disk capacity",
                "target" => %{"key" => "a", "kind" => "host", "label" => "Target a"}
              }
            ])

    publish(checks)
    {:ok, view, _} = live(build_conn(), "/checks?search=presentation-")
    assert length(rows(view)) == 2
    assert has_element?(view, "#preview-check-results", "presentation-first")
    assert has_element?(view, "#preview-check-results", "presentation-second")
  end

  defp choose(view, field, key) do
    render_click(view, "filter_open", %{"field" => field})
    render_click(view, "filter_select", %{"key" => key, "kind" => ""})
  end

  defp rows(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#preview-check-results tbody > tr")
      |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

  defp mixed_inventory do
    publish([
      check("critical", "a"),
      check("warning", "a"),
      check("healthy", "a"),
      check("pending-a", "a"),
      check("retained", "b"),
      check("pending-b", "b")
    ])

    measure("critical", "CRIT", "fresh")
    measure("warning", "WARN", "fresh")
    measure("healthy", "OK", "fresh")
    measure("retained", "CRIT", "stale")
  end

  defp stream(key), do: Repo.one!(from s in ResultStream, where: s.result_key == ^key)

  defp measure(key, health, knowledge) do
    stream = stream(key)
    assignment = Repo.get!(Assignment, stream.assignment_id)
    runner = Repo.get!(Mondek.Runner, assignment.runner_id)
    now = DateTime.utc_now()
    measured_at = if knowledge == "stale", do: DateTime.add(now, -120), else: now
    iso = DateTime.to_iso8601(measured_at)
    observation_id = Ecto.UUID.generate()
    Monitoring.change(assignment, %{authorized_generation: 1})

    payload =
      measurement(health, 1, %{
        "id" => observation_id,
        "assignment_id" => assignment.id,
        "installation_id" => runner.id,
        "session_id" => runner.session_id,
        "started_at" => iso,
        "evaluated_at" => iso
      })
      |> put_in(["results", Access.at(0), "key"], key)
      |> put_in(["results", Access.at(0), "source_at"], iso)

    Repo.insert!(%Observation{
      id: observation_id,
      assignment_id: assignment.id,
      installation_id: runner.id,
      session_id: runner.session_id,
      generation: 1,
      sequence: 1,
      started_at: measured_at,
      evaluated_at: measured_at,
      received_at: now,
      payload: payload,
      disposition: "current"
    })

    current = %{
      "health" => health,
      "knowledge" => knowledge,
      "summary" => "Independent #{key} evidence",
      "generation" => 1,
      "session_id" => runner.session_id,
      "source_at" => iso,
      "confirmed_observation_id" => observation_id,
      "confirmed_generation" => 1
    }

    Repo.update_all(from(s in ResultStream, where: s.id == ^stream.id), set: [current: current])
  end

  defp publish(checks) do
    assert {:ok, _} =
             Inventory.reconcile(
               control(%{
                 "installation_id" => Ecto.UUID.generate(),
                 "session_id" => Ecto.UUID.generate(),
                 "runner_label" => "Presentation observer",
                 "source_id" => "presentation.source",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               DateTime.utc_now()
             )
  end

  defp check(key, target) do
    %{
      "key" => key,
      "label" => "presentation-" <> key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" => [
        %{
          "key" => key,
          "label" => "presentation-" <> key <> " result",
          "target" => %{"key" => target, "kind" => "host", "label" => "Target " <> target}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60
    }
  end
end
