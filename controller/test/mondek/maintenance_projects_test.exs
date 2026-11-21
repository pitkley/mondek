# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceProjectsTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Mondek.{
    Maintenance,
    MaintenanceProjects,
    MaintenanceSchedules,
    MaintenanceSeries,
    MaintenanceWindow
  }

  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  setup do
    publication = F.publication([F.candidate(F.check("service", "production"))])
    assert {:ok, _} = Monitoring.inventory(publication, at())
    %{source: publication["source_id"]}
  end

  test "a finite project can be reviewed through HTTP and reapplied after the first start", %{
    source: source
  } do
    manifest = manifest(source, "count")
    response = request("/api/v1/maintenance-projects/plan", %{"manifest" => manifest})
    assert %{"changes" => [%{"action" => "create", "create" => %{"dates" => dates}}]} = response
    assert length(dates) == 2

    applied =
      request("/api/v1/maintenance-projects/apply", %{
        "manifest" => manifest,
        "review_token" => response["review_token"]
      })

    assert [schedule] = applied["schedules"]

    assert get(build_conn(), "/api/v1/maintenance-projects/deploy")
           |> json_response(200)
           |> Map.fetch!("data") == applied

    later = DateTime.add(DateTime.from_iso8601(hd(dates)["starts_at"]) |> elem(1), 60)
    assert {:ok, unchanged} = MaintenanceProjects.plan(manifest, nil, later)
    assert [%{"action" => "unchanged"}] = unchanged["changes"]
    assert {:ok, _} = MaintenanceProjects.apply(unchanged["review_token"], manifest, later)
    assert Repo.aggregate(MaintenanceSeries, :count) == 1
    assert Repo.get!(MaintenanceSeries, schedule["series_id"]).revision == 1
  end

  test "replacement and removal preserve started windows and reviewed future exceptions", %{
    source: source
  } do
    first = manifest(source, "open")
    applied = apply_manifest(first, nil, at())
    assert [item] = applied["schedules"]
    old_id = item["series_id"]
    assert {:ok, old} = MaintenanceSchedules.get(old_id, %{}, at())
    [started, exception | remaining] = old["occurrences"]
    during = DateTime.add(DateTime.from_iso8601(started["starts_at"]) |> elem(1), 60)
    assert {:ok, _} = Maintenance.cancel(exception["id"], 1, "Do not hold this date", during)

    replacement =
      update_in(first["schedules"], fn [schedule] ->
        [
          update_in(
            schedule["proposal"],
            &Map.merge(&1, %{
              "starts_local" => future_local(16, 9),
              "ends_local" => future_local(16, 10),
              "reason" => "Updated release"
            })
          )
        ]
      end)

    assert {:error, :stale} = MaintenanceProjects.plan(replacement, applied["revision"], during)
    assert {:ok, current} = MaintenanceProjects.export("deploy")
    assert {:ok, preview} = MaintenanceProjects.plan(replacement, current["revision"], during)
    assert [%{"action" => "replace", "retire" => %{"preserve" => protected}}] = preview["changes"]
    assert protected == [started["id"], exception["id"]]
    assert {:ok, saved} = MaintenanceProjects.apply(preview["review_token"], replacement, during)
    assert {:ok, ^saved} = MaintenanceProjects.apply(preview["review_token"], replacement, during)
    assert Repo.get!(MaintenanceWindow, started["id"]).cancelled_at == nil

    assert Repo.get!(MaintenanceWindow, exception["id"]).cancellation_reason ==
             "Do not hold this date"

    assert Enum.all?(remaining, &Repo.get!(MaintenanceWindow, &1["id"]).cancelled_at)
    assert Repo.get!(MaintenanceSeries, old_id).generation_stopped_at == during

    early_replacement =
      update_in(replacement["schedules"], fn [schedule] ->
        [
          update_in(
            schedule["proposal"],
            &Map.merge(&1, %{
              "starts_local" => future_local(3, 9),
              "ends_local" => future_local(3, 10)
            })
          )
        ]
      end)

    assert {:error, {:invalid, message}} =
             MaintenanceProjects.plan(early_replacement, saved["revision"], during)

    assert message =~ "protected windows"

    replacement_id = hd(saved["schedules"])["series_id"]
    removed = apply_manifest(%{replacement | "schedules" => []}, saved["revision"], during)
    assert removed["schedules"] == []
    assert Repo.get!(MaintenanceSeries, replacement_id).generation_stopped_at == during
    assert {:error, :stale} = MaintenanceProjects.plan(first, nil, at())
  end

  defp apply_manifest(manifest, base, at) do
    assert {:ok, review} = MaintenanceProjects.plan(manifest, base, at)
    assert {:ok, result} = MaintenanceProjects.apply(review["review_token"], manifest, at)
    result
  end

  test "an archived key still protects canceled future dates when reused", %{source: source} do
    desired = manifest(source, "count")
    saved = apply_manifest(desired, nil, at())
    id = hd(saved["schedules"])["series_id"]
    assert {:ok, series} = MaintenanceSchedules.get(id, %{}, at())
    [first | _] = series["occurrences"]
    assert {:ok, _} = Maintenance.cancel(first["id"], 1, "Skip first release", at())
    assert {:ok, edited} = MaintenanceProjects.export("deploy")
    removed = apply_manifest(%{desired | "schedules" => []}, edited["revision"], at())

    assert [%{"key" => "weekly", "series_id" => ^id, "active" => false}] =
             removed["archived_keys"]

    assert {:error, {:invalid, message}} =
             MaintenanceProjects.plan(desired, removed["revision"], at())

    assert message =~ "protected windows"
    assert Repo.get!(MaintenanceWindow, first["id"]).cancellation_reason == "Skip first release"
  end

  defp request(path, payload) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
    |> json_response(200)
  end

  defp manifest(source, ending) do
    %{
      "version" => 1,
      "project" => "deploy",
      "schedules" => [
        %{
          "key" => "weekly",
          "proposal" => %{
            "name" => "Release maintenance",
            "reason" => "Release update",
            "timezone" => "UTC",
            "starts_local" => future_local(1, 9),
            "ends_local" => future_local(1, 10),
            "start_fold" => "reject",
            "end_fold" => "reject",
            "recurrence" => %{
              "frequency" => "weekly",
              "interval" => 1,
              "end_mode" => ending,
              "count" => if(ending == "count", do: 2)
            },
            "selections" => [
              %{
                "scope" => "stable_check",
                "source_id" => source,
                "source_key" => "service",
                "environment" => "production"
              }
            ]
          }
        }
      ]
    }
  end

  defp future_local(days, hour) do
    # HTTP routes use the real clock; native variants pass a controlled instant.
    date = Date.utc_today() |> Date.add(days)
    NaiveDateTime.new!(date, Time.new!(hour, 0, 0)) |> NaiveDateTime.to_iso8601()
  end
end
