# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceSchedulesTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest

  alias Mondek.{
    Maintenance,
    MaintenanceSchedules,
    MaintenanceSeries,
    MaintenanceSeriesEvent,
    MaintenanceWindow,
    MaintenanceEvent,
    MaintenanceTime,
    Sweeper
  }

  alias Mondek.CoverageFixtures, as: F
  @endpoint MondekWeb.Endpoint

  test "one reviewed save creates finite exact windows and gates only their half-open intervals" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    job = Repo.one!(Oban.Job)
    review = preview(proposal())
    saved = save(review)
    expected_check = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    expected_runner = Repo.get!(Mondek.Runner, expected_check.runner_id)
    assert saved["check_label"] == expected_check.label
    assert saved["runner_label"] == expected_runner.label
    [listed] = Maintenance.list(%{}, at())["windows"]
    assert listed["check_label"] == expected_check.label
    assert listed["runner_label"] == expected_runner.label
    assert saved["occurrence_total"] == 3
    assert saved["upcoming_count"] == 3

    assert Enum.map(saved["occurrences"], & &1["starts_at"]) ==
             Enum.map(review["occurrences"], & &1["starts_at"])

    assert Repo.aggregate(MaintenanceSeries, :count) == 1
    assert Repo.aggregate(MaintenanceWindow, :count) == 3
    assert Repo.aggregate(MaintenanceEvent, :count) == 3
    assert Repo.aggregate(MaintenanceSeriesEvent, :count) == 1
    first = hd(saved["occurrences"])
    incident = Repo.one!(Incident)
    assignment = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    assert Maintenance.active_for(incident, assignment, dt(first["starts_at"])) |> length() == 1
    assert Maintenance.active_for(incident, assignment, dt(first["ends_at"])) == []

    assert Maintenance.active_for(
             incident,
             assignment,
             DateTime.add(dt(first["ends_at"]), 86_400)
           ) == []

    assert Repo.get!(Occurrence, occurrence.id).payload == occurrence.payload
    assert Repo.get!(Oban.Job, job.id).attempt == job.attempt
    assert Repo.get!(Oban.Job, job.id).max_attempts == job.max_attempts

    assert {:error, :review_changed} =
             MaintenanceSchedules.apply(review["review_token"], review["proposal"], at())

    assert Repo.aggregate(MaintenanceWindow, :count) == 3
  end

  test "invalid later civil dates and elapsed first windows leave no partial series" do
    p =
      proposal()
      |> Map.merge(%{
        "timezone" => "Europe/Berlin",
        "starts_local" => "2010-03-21T02:30:00",
        "ends_local" => "2010-03-21T03:30:00"
      })

    assert {:error, {:invalid, gap}} = MaintenanceSchedules.preview(p, 1, 1, at())
    assert gap =~ "2010-03-28"
    review = preview(proposal())

    assert {:error, {:invalid, _}} =
             MaintenanceSchedules.apply(
               review["review_token"],
               review["proposal"],
               dt(hd(review["occurrences"])["starts_at"])
             )

    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    assert Repo.aggregate(MaintenanceSeries, :count) == 0
    assert Repo.aggregate(MaintenanceSeriesEvent, :count) == 0
  end

  test "each child keeps its own civil dates and subsecond duration through ordinary edits" do
    p =
      proposal()
      |> Map.merge(%{
        "starts_local" => "2009-09-20T09:00:00.123456",
        "ends_local" => "2009-09-20T09:00:00.654321"
      })

    review = preview(p)
    assert Enum.all?(review["occurrences"], &(&1["elapsed_seconds"] == 0.530865))
    saved = save(review)
    second = Enum.at(saved["occurrences"], 1)
    assert second["starts_local"] == "2009-09-27T09:00:00.123456"
    assert second["ends_local"] == "2009-09-27T09:00:00.654321"
    assert second["elapsed_seconds"] == 0.530865
    {:ok, detail} = Maintenance.get(second["id"], at())
    assert detail["proposal"]["starts_local"] == second["starts_local"]

    {:ok, edit} =
      Maintenance.preview(
        Map.put(detail["proposal"], "reason", "Clarified second visit"),
        1,
        at()
      )

    {:ok, updated} = Maintenance.apply(edit["review_token"], edit["proposal"], at())
    assert updated["starts_at"] == second["starts_at"]
    assert updated["ends_at"] == second["ends_at"]
  end

  test "series membership constraints reject corrupt history" do
    saved = proposal() |> preview() |> save()
    first = hd(saved["occurrences"])

    for index <- [nil, 0, 53] do
      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(w in MaintenanceWindow, where: w.id == ^first["id"]),
          set: [series_index: index]
        )
      end
    end

    assert Repo.aggregate(MaintenanceWindow, :count) == 3
    assert Repo.aggregate(MaintenanceSeriesEvent, :count) == 1
  end

  test "all dates share one scope review and late overlap drift invalidates the whole save" do
    review = preview(proposal())
    third = List.last(review["occurrences"])

    ordinary =
      proposal()
      |> Map.delete("recurrence")
      |> Map.merge(Map.take(third, ~w(starts_local ends_local)))

    {:ok, other_review} = Maintenance.preview(ordinary, 1, at())
    {:ok, other} = Maintenance.apply(other_review["review_token"], other_review["proposal"], at())

    assert {:error, :review_changed} =
             MaintenanceSchedules.apply(review["review_token"], review["proposal"], at())

    assert Repo.aggregate(MaintenanceSeries, :count) == 0
    new = preview(proposal())
    assert Enum.map(new["occurrences"], & &1["overlap_count"]) == [0, 0, 1]
    assert Enum.map(new["overlaps"], & &1["id"]) == [other["id"]]
    saved = save(new)
    assert Repo.aggregate(MaintenanceWindow, :count) == 4
    assert Maintenance.list(%{}, at())["total"] == 2

    assert Maintenance.list(%{"assignment_id" => "10000000-0000-4000-8000-000000000001"}, at())[
             "total"
           ] == 2

    assert saved["kind"] == "series"
  end

  test "paged timeline is one list entry and ordinary child exceptions retain immutable scope and lineage" do
    saved = proposal(52) |> preview() |> save()
    assert length(saved["occurrences"]) == 25
    assert saved["occurrence_pages"] == 3
    {:ok, last} = MaintenanceSchedules.get(saved["id"], %{"occurrence_page" => "3"}, at())
    assert Enum.map(last["occurrences"], & &1["index"]) == [51, 52]
    assert Maintenance.list(%{}, at())["windows"] |> length() == 1
    child = hd(saved["occurrences"])
    {:ok, window} = Maintenance.get(child["id"], at())
    assert window["series_id"] == saved["id"]
    assert window["series_index"] == 1
    changed = Map.put(window["proposal"], "ends_local", "2009-09-20T11:00:00")
    {:ok, edit} = Maintenance.preview(changed, 1, at())
    {:ok, updated} = Maintenance.apply(edit["review_token"], edit["proposal"], at())
    assert updated["series_id"] == saved["id"]
    assert updated["exception"]
    {:ok, series} = MaintenanceSchedules.get(saved["id"], %{}, at())
    assert series["revision"] == 2
    assert hd(series["occurrences"])["original_ends_at"] == child["ends_at"]
    assert hd(series["occurrences"])["ends_at"] != child["ends_at"]
    assert series["proposal"] == saved["proposal"]
    assert hd(series["history"])["kind"] == "occurrence_updated"

    assert Maintenance.reference(Repo.get!(MaintenanceWindow, child["id"]))["series_id"] ==
             saved["id"]
  end

  test "upcoming cancellation leaves active and unrelated gates and exact retry identities alone" do
    connect()
    ingest(measurement("CRIT"))
    saved = proposal() |> preview() |> save()
    active_at = dt(hd(saved["occurrences"])["starts_at"])
    occurrence = Repo.one!(Occurrence)
    job = Repo.one!(Oban.Job)

    {:ok, review} =
      MaintenanceSchedules.cancel_preview(
        saved["id"],
        1,
        "Remaining work postponed",
        1,
        active_at
      )

    assert review["upcoming_count"] == 2
    assert review["active_count"] == 1

    {:ok, cancelled} =
      MaintenanceSchedules.cancel(
        saved["id"],
        review["review_token"],
        review["reason"],
        active_at
      )

    assert cancelled["active_count"] == 1
    assert cancelled["upcoming_count"] == 0
    assert cancelled["cancelled_count"] == 2
    assert cancelled["status"] == "active"
    assert Repo.get!(Oban.Job, job.id).max_attempts == job.max_attempts
    assert Repo.get!(Oban.Job, job.id).attempt == job.attempt
    assert Repo.get!(Occurrence, occurrence.id).payload == occurrence.payload

    assert Maintenance.active_for(
             Repo.one!(Incident),
             Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"),
             active_at
           )
           |> length() == 1

    for child <- Enum.drop(cancelled["occurrences"], 1) do
      event =
        Repo.one!(
          from e in MaintenanceEvent, where: e.window_id == ^child["id"] and e.revision == 2
        )

      assert event.snapshot["scope"] == "check"
      assert event.snapshot["assignment_id"] == "10000000-0000-4000-8000-000000000001"
      assert event.snapshot["series_id"] == saved["id"]
    end

    assert {:error, :review_changed} =
             MaintenanceSchedules.cancel(
               saved["id"],
               review["review_token"],
               review["reason"],
               active_at
             )
  end

  test "crossing activation or editing any child makes an upcoming cancellation review stale" do
    saved = proposal() |> preview() |> save()

    {:ok, review} =
      MaintenanceSchedules.cancel_preview(saved["id"], 1, "Cancel future dates", 1, at())

    first = hd(saved["occurrences"])

    assert {:error, :review_changed} =
             MaintenanceSchedules.cancel(
               saved["id"],
               review["review_token"],
               review["reason"],
               dt(first["starts_at"])
             )

    assert Enum.all?(Repo.all(MaintenanceWindow), &is_nil(&1.cancelled_at))
    {:ok, _} = Maintenance.cancel(first["id"], 1, "Skip first date", at())

    assert {:error, :review_changed} =
             MaintenanceSchedules.cancel(
               saved["id"],
               review["review_token"],
               review["reason"],
               at()
             )

    {:ok, changed} = MaintenanceSchedules.get(saved["id"], %{}, at())
    assert changed["revision"] == 2
    assert changed["cancelled_count"] == 1
    assert changed["upcoming_count"] == 2
  end

  test "a series is between windows rather than active, and history waits for every member" do
    saved = proposal() |> preview() |> save()
    between = DateTime.add(dt(hd(saved["occurrences"])["ends_at"]), 1)
    {:ok, series} = MaintenanceSchedules.get(saved["id"], %{}, between)
    assert series["status"] == "between"
    assert series["active_count"] == 0
    assert series["upcoming_count"] == 2
    assert Maintenance.list(%{"status" => "history"}, between)["total"] == 0
    ended = dt(List.last(saved["occurrences"])["ends_at"])
    assert Maintenance.list(%{}, ended)["total"] == 0
    assert Maintenance.list(%{"status" => "history"}, ended)["total"] == 1
    {:ok, terminal} = MaintenanceSchedules.get(saved["id"], %{}, ended)
    assert terminal["status"] == "completed"
  end

  test "simultaneous reviewed saves create exactly one complete series" do
    review = preview(proposal())

    tasks =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              MaintenanceSchedules.apply(review["review_token"], review["proposal"], at())
            end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :review_changed} in results
    assert Repo.aggregate(MaintenanceSeries, :count) == 1
    assert Repo.aggregate(MaintenanceWindow, :count) == 3
    assert Repo.aggregate(MaintenanceEvent, :count) == 3
  end

  test "retention keeps the complete series until all dates and relevant incident history are terminal" do
    connect()
    ingest(measurement("CRIT"))
    saved = proposal(10) |> preview() |> save()
    first_end = dt(hd(saved["occurrences"])["ends_at"])
    assert {:ok, _} = Sweeper.sweep(DateTime.add(first_end, 31 * 86_400))
    assert Repo.aggregate(MaintenanceWindow, :count) == 10
    after_last = saved["final_ends_at"] |> dt() |> DateTime.add(31 * 86_400)
    assert {:ok, _} = Sweeper.sweep(after_last)
    assert Repo.get(MaintenanceSeries, saved["id"])
    assert Repo.aggregate(MaintenanceWindow, :count) == 10
    # Explicitly retire the check using the actual lifecycle; administrative end
    # makes its retained history eligible after the normal retention interval.
    {:ok, _} =
      withdraw_source_fixture(
        "10000000-0000-4000-8000-000000000001",
        "Monitoring removed",
        after_last
      )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :notifications)
    assert {:ok, _} = Sweeper.sweep(DateTime.add(after_last, 31 * 86_400))
    assert Repo.get(MaintenanceSeries, saved["id"]) == nil
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    assert Repo.aggregate(MaintenanceEvent, :count) == 0
    assert Repo.aggregate(MaintenanceSeriesEvent, :count) == 0
  end

  test "500 checks across 52 dates stay bounded, while excessive serialized intent is rejected" do
    source = String.duplicate("s", 200)
    environment = String.duplicate("e", 128)

    candidates =
      for n <- 1..500 do
        key = String.pad_leading(to_string(n), 200, "t")
        F.check("check-#{n}", environment, key) |> F.candidate()
      end

    publication = F.publication(candidates, %{"source_id" => source})
    assert {:ok, _} = Monitoring.inventory(publication, at())
    assignments = F.assignments(publication)
    selected = Enum.map(assignments, &%{"scope" => "check", "assignment_id" => &1.id})

    p =
      proposal(52)
      |> Map.merge(%{"scope" => "selection", "assignment_id" => nil, "selections" => selected})

    review = preview(p)
    saved = save(review)
    assert saved["result_total"] == 500
    assert saved["occurrence_total"] == 52
    assert byte_size(Jason.encode!(saved)) < 1_000_000

    {:ok, last} =
      MaintenanceSchedules.get(saved["id"], %{"occurrence_page" => 3, "result_page" => 20}, at())

    assert length(last["rows"]) == 25
    assert Enum.map(last["occurrences"], & &1["index"]) == [51, 52]

    targets =
      Enum.map(candidates, fn c ->
        %{
          "scope" => "target",
          "source_id" => source,
          "environment" => environment,
          "target_kind" => "service",
          "target_key" => hd(c["outputs"])["target"]["key"]
        }
      end)

    assert {:error, {:invalid, message}} =
             MaintenanceSchedules.preview(Map.put(p, "selections", targets), 1, 1, at())

    assert message =~ "8 MiB"
    assert Repo.aggregate(MaintenanceWindow, :count) == 52
  end

  test "API supports preview, save, inspection and reviewed upcoming cancellation with exact errors" do
    now = Monitoring.now()

    p =
      proposal()
      |> Map.merge(%{
        "starts_local" => MaintenanceTime.local(DateTime.add(now, 3600), "UTC"),
        "ends_local" => MaintenanceTime.local(DateTime.add(now, 7200), "UTC")
      })

    preview =
      post_json("/api/v1/maintenance-series/preview", %{"proposal" => p}) |> json_response(200)

    saved =
      post_json("/api/v1/maintenance-series/apply", Map.take(preview, ~w(proposal review_token)))
      |> json_response(200)

    detail =
      build_conn() |> get("/api/v1/maintenance-series/#{saved["id"]}") |> json_response(200)

    assert detail["occurrence_total"] == 3

    bad =
      post_json("/api/v1/maintenance-series/#{saved["id"]}/cancel", %{
        "review_token" => preview["review_token"],
        "reason" => "Wrong token"
      })

    assert json_response(bad, 422)["code"] == "invalid_review"

    cancel =
      post_json("/api/v1/maintenance-series/#{saved["id"]}/cancel-preview", %{
        "revision" => 1,
        "reason" => "Postpone plan"
      })
      |> json_response(200)

    result =
      post_json(
        "/api/v1/maintenance-series/#{saved["id"]}/cancel",
        Map.take(cancel, ~w(review_token reason))
      )
      |> json_response(200)

    assert result["cancelled_count"] == 3

    for id <- [Ecto.UUID.generate(), "not-a-uuid", "0123456789abcdef"] do
      assert {:error, :not_found} = MaintenanceSchedules.get(id, %{}, at())
      assert build_conn() |> get("/api/v1/maintenance-series/#{id}") |> json_response(404)
    end

    assert {:error, :not_found} = MaintenanceSchedules.get(nil, %{}, at())
  end

  defp proposal(count \\ 3) do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, at())

    seed["proposal"]
    |> Map.merge(%{
      "name" => "Sunday patching",
      "reason" => "Reviewed weekly work",
      "start_mode" => "scheduled",
      "timezone" => "UTC",
      "starts_local" => "2009-09-20T09:00:00",
      "ends_local" => "2009-09-20T10:00:00",
      "recurrence" => %{
        "frequency" => "weekly",
        "interval" => 1,
        "end_mode" => "count",
        "count" => count,
        "until_date" => nil
      }
    })
  end

  defp preview(p) do
    assert {:ok, review} = MaintenanceSchedules.preview(p, 1, 1, at())
    review
  end

  defp save(review) do
    assert {:ok, saved} =
             MaintenanceSchedules.apply(review["review_token"], review["proposal"], at())

    saved
  end

  defp dt(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp post_json(path, body),
    do:
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
end
