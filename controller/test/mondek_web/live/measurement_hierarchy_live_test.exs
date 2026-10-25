# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MeasurementHierarchyLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.ResultStream

  @endpoint MondekWeb.Endpoint

  test "the first failed execution explains collection without claiming a confirmed Unknown measurement" do
    now = DateTime.utc_now()
    assert {:ok, _} = Monitoring.control(control(), now)

    failure =
      measured_report("UNKNOWN", 1, now, %{
        "complete" => false,
        "results" => [],
        "diagnostic" => "Worker failed before producing its first result"
      })

    assert disposition(ingest(failure, now)) == "current"

    stream =
      Repo.get_by!(ResultStream,
        assignment_id: "10000000-0000-4000-8000-000000000001",
        result_key: "capacity"
      )

    refute stream.current["confirmed_observation_id"]
    assert stream.current["health"] == "UNKNOWN"

    {:ok, view, _} = live(build_conn(), "/checks/" <> stream.id)
    assert has_element?(view, "#result-measurement", "Not measured")
    assert has_element?(view, "#result-measurement", "No confirmed measurement yet")
    refute has_element?(view, "#result-measurement .badge.unknown")
    refute has_element?(view, "#confirmed-result-details")

    assert has_element?(
             view,
             "#measurement-notice-10000000-0000-4000-8000-000000000001",
             "Measurement unavailable"
           )

    assert has_element?(
             view,
             "#measurement-notice-10000000-0000-4000-8000-000000000001",
             "Worker failed before producing its first result"
           )

    assert has_element?(view, "details#check-execution-history")
    refute has_element?(view, "details#check-execution-history[open]")
    assert has_element?(view, "#check-execution-history", failure["id"])
  end

  test "a valid result in an incomplete shared execution keeps its own confirmed evidence and freshness" do
    now = DateTime.utc_now()
    assignment = publish_pair(now)

    sample =
      measured_report("WARN", 1, now, %{
        "assignment_id" => assignment.id,
        "complete" => false,
        "diagnostic" => "Right datasource failed; its expected output is missing",
        "results" => [
          %{
            "key" => "left",
            "health" => "WARN",
            "value" => 8,
            "summary" => "Left queue has eight waiting items",
            "details" => "Left queue was inspected successfully.\nWarning starts at five items.",
            "source_at" => DateTime.to_iso8601(now)
          }
        ]
      })

    assert disposition(ingest(sample, now)) == "current"
    left = Repo.get_by!(ResultStream, assignment_id: assignment.id, result_key: "left")
    right = Repo.get_by!(ResultStream, assignment_id: assignment.id, result_key: "right")
    assert left.current["confirmed_observation_id"] == sample["id"]
    assert left.current["knowledge"] == "fresh"
    refute right.current["confirmed_observation_id"]

    {:ok, view, _} = live(build_conn(), "/checks/" <> left.id)
    assert has_element?(view, "#result-measurement .badge.warn", "Warning")
    assert has_element?(view, "#result-measurement .badge.fresh", "Fresh")
    assert has_element?(view, "#result-measurement", "Left queue has eight waiting items")
    assert has_element?(view, "#confirmed-result-details pre", "Warning starts at five items")
    refute has_element?(view, "details#confirmed-result-details")
    refute has_element?(view, "#measurement-notice-#{assignment.id}")
    refute has_element?(view, "#result-measurement", "Right datasource failed")
    assert has_element?(view, "#check-execution-history", "Right datasource failed")
    refute has_element?(view, "#check-execution-history[open]")

    incident = Repo.get_by!(Incident, stream_id: left.id)
    {:ok, incident_view, _} = live(build_conn(), "/incidents/" <> incident.id)
    assert has_element?(incident_view, "#incident-check-now .badge.warn", "Warning")

    assert has_element?(
             incident_view,
             "#incident-current-details pre",
             "Left queue was inspected"
           )

    refute has_element?(incident_view, "details#incident-current-details")
    refute has_element?(incident_view, "#incident-check-now", "Right datasource failed")

    {:ok, missing_view, _} = live(build_conn(), "/checks/" <> right.id)
    assert has_element?(missing_view, "#result-measurement", "Not measured")

    assert has_element?(
             missing_view,
             "#measurement-notice-#{assignment.id}",
             "Measurement unavailable"
           )
  end

  test "a later historical receipt stays in execution history and cannot replace the accepted collection diagnosis" do
    now = DateTime.utc_now()
    assert {:ok, _} = Monitoring.control(control(), now)

    confirmed =
      measured_report("CRIT", 2, DateTime.add(now, -2), %{
        "results" => [
          %{
            "key" => "capacity",
            "health" => "CRIT",
            "value" => 96,
            "summary" => "Confirmed disk pressure",
            "details" => "Measured root usage is 96 percent.\nInvestigate large files.",
            "source_at" => DateTime.to_iso8601(DateTime.add(now, -2))
          }
        ]
      })

    assert disposition(ingest(confirmed, DateTime.add(now, -2))) == "current"

    current =
      measured_report("UNKNOWN", 3, DateTime.add(now, -1), %{
        "complete" => false,
        "results" => [],
        "diagnostic" => "Accepted current worker failed to read filesystem"
      })

    assert disposition(ingest(current, DateTime.add(now, -1))) == "current"

    historical =
      measured_report("OK", 1, DateTime.add(now, -30), %{
        "diagnostic" => "Delayed historical report from an older execution",
        "results" => [
          %{
            "key" => "capacity",
            "health" => "OK",
            "value" => 10,
            "summary" => "Old disk measurement looked healthy",
            "source_at" => DateTime.to_iso8601(DateTime.add(now, -30))
          }
        ]
      })

    assert disposition(ingest(historical, now)) == "historical"

    stream =
      Repo.get_by!(ResultStream,
        assignment_id: "10000000-0000-4000-8000-000000000001",
        result_key: "capacity"
      )

    assert stream.current["observation_id"] == current["id"]
    assert stream.current["confirmed_observation_id"] == confirmed["id"]
    assert hd(Monitoring.stream_inspection(stream.id, now)["evidence"])["id"] == historical["id"]

    {:ok, view, _} = live(build_conn(), "/checks/" <> stream.id)
    assert has_element?(view, "#result-measurement .badge.crit", "Critical")

    assert has_element?(
             view,
             "#confirmed-result-details pre",
             "Measured root usage is 96 percent"
           )

    assert has_element?(
             view,
             "#measurement-notice-10000000-0000-4000-8000-000000000001",
             "Accepted current worker failed to read filesystem"
           )

    refute has_element?(view, "#result-measurement", "Old disk measurement looked healthy")
    refute has_element?(view, "#result-measurement", "Delayed historical report")
    assert has_element?(view, "#check-execution-history > summary", "Execution evidence")
    assert has_element?(view, "#check-execution-history", "Old disk measurement looked healthy")
    refute has_element?(view, "#check-execution-history[open]")
    refute has_element?(view, "h2", "Latest execution")
  end

  defp measured_report(health, sequence, now, overrides) do
    measurement(health, sequence)
    |> Map.merge(%{
      "started_at" => DateTime.to_iso8601(now),
      "evaluated_at" => DateTime.to_iso8601(now)
    })
    |> put_in(["results", Access.at(0), "source_at"], DateTime.to_iso8601(now))
    |> Map.merge(overrides)
  end

  defp publish_pair(now) do
    definition = %{
      "key" => "hierarchy-pair",
      "label" => "Independent datasource outputs",
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "params" => %{},
      "parameter_schema" => %{"fields" => %{}},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60,
      "outputs" =>
        for key <- ["left", "right"] do
          %{
            "key" => key,
            "label" => "#{key} queue",
            "target" => %{"kind" => "queue", "key" => key, "label" => "#{key} queue"}
          }
        end
    }

    inventory =
      control(%{
        "runner_label" => "Hierarchy observer",
        "source_id" => "measurement-hierarchy",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => [definition]
      })

    assert {:ok, _} = Monitoring.inventory(inventory, now)
    assignment = Repo.get_by!(Assignment, source_key: "hierarchy-pair")

    assert {:ok, _} =
             Monitoring.control(
               control(%{"prepared" => %{assignment.id => 1}, "active" => %{}}),
               now
             )

    assignment
  end
end
