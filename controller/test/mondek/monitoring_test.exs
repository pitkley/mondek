# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringTest do
  use Mondek.DataCase, async: false

  test "fixed target bindings reject retargeting while thresholds remain editable" do
    for id <- [
          "10000000-0000-4000-8000-000000000001",
          "10000000-0000-4000-8000-000000000002",
          "10000000-0000-4000-8000-000000000003"
        ] do
      saved = Repo.get!(Assignment, id)
      key = if id == "10000000-0000-4000-8000-000000000001", do: "path", else: "url"

      replacement =
        if id == "10000000-0000-4000-8000-000000000001",
          do: "/tmp",
          else: "http://target:8080/other"

      assert {:error, {:invalid, message}} =
               Monitoring.save_assignment(id, 1, Map.put(saved.params, key, replacement))

      assert message =~ "source schema"
      assert Repo.get!(Assignment, id).params == saved.params
      assert {:ok, %{"revision" => 1}} = Monitoring.save_assignment(id, 1, saved.params)
    end

    saved = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000003")

    assert {:ok, %{"revision" => 2}} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000003",
               1,
               Map.put(saved.params, "crit_count", 12)
             )

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000003").params["url"] ==
             saved.params["url"]

    existing = %{"url" => "http://target:8080/existing-readiness"}

    Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000002"), %{
      params: existing,
      parameter_schema: %{
        "fields" => %{"url" => %{"type" => "string", "choices" => [existing["url"]]}}
      }
    })

    configuration =
      Repo.get_by!(Mondek.Configuration,
        assignment_id: "10000000-0000-4000-8000-000000000002",
        generation: 1
      )

    Monitoring.change(configuration, %{params: existing})

    assert {:ok, %{"params" => ^existing, "revision" => 1}} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000002", 1, existing)

    assert {:error, {:invalid, _}} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000002", 1, "invalid")
  end

  test "numerically identical saves preserve policy and still reject a stale reviewed revision" do
    connect()
    ingest(measurement("CRIT"))
    params = %{"path" => "/", "warn_percent" => 80.0, "crit_percent" => 90.0}

    assert {:ok, %{"revision" => 1, "desired_generation" => 1}} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, params)

    assert Repo.aggregate(Mondek.Configuration, :count) == 3
    ingest(measurement("OK", 2))
    assert Repo.one!(Incident).closure_reason == "measured_recovery"

    assert {:ok, %{"revision" => 2}} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000001",
               1,
               Map.put(params, "crit_percent", 95)
             )

    assert {:error, :stale} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000001",
               1,
               Map.put(params, "crit_percent", 95)
             )
  end

  test "returning to the original effective policy permits honest measured recovery" do
    connect()
    ingest(measurement("CRIT"))
    original = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").params

    Monitoring.save_assignment(
      "10000000-0000-4000-8000-000000000001",
      1,
      Map.put(original, "crit_percent", 95)
    )

    Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 2, original)
    connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 3}})
    ingest(measurement("OK", 2, %{"generation" => 3}))
    assert Repo.one!(Incident).closure_reason == "measured_recovery"
  end

  test "the cross-language fixture is admitted and a lost response replays without side effects" do
    assert {:ok, _} = connect()
    r = report()
    assert disposition(ingest(r)) == "current"
    assert disposition(ingest(r, DateTime.add(at(), 5))) == "duplicate"
    assert Repo.aggregate(Observation, :count) == 1
    state = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current
    assert state["received_at"] == DateTime.to_iso8601(at())
    assert state["source_at"] == hd(r["results"])["source_at"]
    changed = put_in(r, ["results", Access.at(0), "summary"], "different payload")
    assert disposition(ingest(changed)) == "conflict"
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current == state
  end

  test "revision saves race using independent database connections and exactly one wins" do
    outcomes =
      for crit <- [92, 93],
          do:
            Task.async(fn ->
              Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
                "path" => "/",
                "warn_percent" => 80,
                "crit_percent" => crit
              })
            end)

    outcomes = Enum.map(outcomes, &Task.await/1)
    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale} in outcomes
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").desired_generation == 2

    assert {:error, {:invalid, _}} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 2, %{
               "path" => "/",
               "warn_percent" => 95,
               "crit_percent" => 90
             })
  end

  test "desired, prepared, active and first observed are distinct; old generation cannot overwrite" do
    connect()
    ingest(measurement("CRIT"))

    assert {:ok, _} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
               "path" => "/",
               "warn_percent" => 95,
               "crit_percent" => 99
             })

    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert a.desired_generation == 2 and a.authorized_generation == 1 and
             is_nil(a.active_generation)

    assert {:ok, response} =
             connect(%{
               "prepared" => %{"10000000-0000-4000-8000-000000000001" => 2},
               "active" => %{"10000000-0000-4000-8000-000000000001" => 1}
             })

    assert response["authorized"]["10000000-0000-4000-8000-000000000001"] == 2
    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert a.prepared_generation == 2 and is_nil(a.active_generation) and
             a.observed_generation == 1

    assert disposition(ingest(measurement("OK", 100))) == "historical"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"

    assert {:ok, _} =
             connect(%{
               "prepared" => %{"10000000-0000-4000-8000-000000000001" => 2},
               "active" => %{"10000000-0000-4000-8000-000000000001" => 2}
             })

    assert disposition(ingest(measurement("OK", 2, %{"generation" => 2}))) == "current"
    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    assert a.active_generation == 2 and a.observed_generation == 2
    assert Repo.one!(Incident).closure_reason == "configuration_changed"
  end

  test "configuration activation serializes with concurrent old evidence" do
    connect()

    Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
      "path" => "/",
      "warn_percent" => 82,
      "crit_percent" => 95
    })

    tasks = [
      Task.async(fn ->
        connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})
      end),
      Task.async(fn -> ingest(measurement("OK", 3)) end)
    ]

    Enum.each(tasks, &Task.await/1)
    # Regardless of which transaction won, no old evidence is authoritative after cutover.
    a =
      Monitoring.snapshot(at())["assignments"]
      |> Enum.find(&(&1["id"] == "10000000-0000-4000-8000-000000000001"))

    assert a["authorized_generation"] == 2
    assert a["current"]["knowledge"] == "awaiting"
  end

  test "session restart fences buffered evidence without poisoning order" do
    connect()
    ingest(measurement("CRIT", 1))
    session = Ecto.UUID.generate()
    assert {:ok, _} = connect(%{"session_id" => session, "boot" => 2})
    assert {:error, :session_conflict} = ingest(measurement("OK", 2))
    buffered = measurement("OK", 100)

    assert disposition(Monitoring.ingest(envelope([buffered], %{"session_id" => session}), at())) ==
             "historical"

    current = measurement("OK", 2, %{"session_id" => session})

    assert disposition(Monitoring.ingest(envelope([current], %{"session_id" => session}), at())) ==
             "current"

    assert Repo.one!(Incident).closure_reason == "measured_recovery"
    assert {:error, :session_conflict} = connect()
    assert {:error, :session_conflict} = connect(%{"boot" => 2})
  end

  test "freshness boundary retains CRIT and stale OK cannot close an episode" do
    connect()
    ingest(measurement("CRIT"))
    before = ~U[2009-09-15 08:00:12.009999Z]
    boundary = ~U[2009-09-15 08:00:12.010000Z]

    assignment = fn at ->
      Monitoring.snapshot(at)["assignments"]
      |> Enum.find(&(&1["id"] == "10000000-0000-4000-8000-000000000001"))
    end

    assert assignment.(before)["current"]["knowledge"] == "fresh"
    assert assignment.(boundary)["current"]["knowledge"] == "stale"
    assert assignment.(boundary)["current"]["health"] == "CRIT"
    assert disposition(ingest(measurement("OK", 2), boundary)) == "current"
    assert Repo.one!(Incident).status == "open"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current["health"] ==
             "CRIT"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current[
             "reported_health"
           ] == "OK"

    assert Repo.aggregate(Occurrence, :count) == 1
  end

  test "partial output retains expected coverage and cannot fabricate recovery" do
    connect()
    ingest(measurement("CRIT"))

    assert disposition(
             ingest(
               measurement("OK", 2, %{
                 "complete" => false,
                 "results" => [],
                 "diagnostic" => "worker timeout"
               })
             )
           ) == "current"

    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    assert a.expected_keys == ["capacity"]
    assert a.current["health"] == "CRIT" and a.current["knowledge"] == "unavailable"
    assert Repo.one!(Incident).status == "open"
    assert disposition(ingest(measurement("OK", 3, %{"results" => []}))) == "rejected"
    future = measurement("OK", 4, %{"evaluated_at" => "2010-01-01T00:00:00.000000Z"})
    assert disposition(ingest(future)) == "rejected"
  end

  test "failed and stale runs retain the confirmed measurement's original configuration and identity" do
    connect()
    confirmed = measurement("OK", 1)
    ingest(confirmed)

    Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 1, %{
      "path" => "/",
      "warn_percent" => 82,
      "crit_percent" => 95
    })

    connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})

    unavailable =
      measurement("UNKNOWN", 2, %{
        "generation" => 2,
        "complete" => false,
        "results" => [],
        "diagnostic" => "worker timeout"
      })

    ingest(unavailable)
    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    assert a.current["health"] == "OK"
    assert a.current["knowledge"] == "unavailable"
    assert a.current["observation_id"] == unavailable["id"]
    assert a.current["generation"] == 2
    assert a.current["confirmed_observation_id"] == confirmed["id"]
    assert a.current["confirmed_generation"] == 1
    assert a.observed_generation == 1

    snapshot =
      Monitoring.snapshot(at())["assignments"]
      |> Enum.find(&(&1["id"] == "10000000-0000-4000-8000-000000000001"))

    assert snapshot["params"]["warn_percent"] == 82
    assert snapshot["current"]["confirmed_params"]["warn_percent"] == 80

    stale = measurement("CRIT", 3, %{"generation" => 2})
    ingest(stale, DateTime.add(at(), 20))
    current = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current
    assert current["knowledge"] == "stale"
    assert current["observation_id"] == stale["id"]
    assert current["confirmed_observation_id"] == confirmed["id"]
    assert current["confirmed_generation"] == 1
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").observed_generation == 1

    later = DateTime.add(at(), 25)
    time = DateTime.to_iso8601(later)

    fresh =
      measurement("OK", 4, %{"generation" => 2, "started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)

    ingest(fresh, later)
    current = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current
    assert current["confirmed_observation_id"] == fresh["id"]
    assert current["confirmed_generation"] == 2
    assert current["confirmed_session_id"] == fresh["session_id"]
    assert current["confirmed_evaluated_at"] == time
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").observed_generation == 2

    snapshot =
      Monitoring.snapshot(later)["assignments"]
      |> Enum.find(&(&1["id"] == "10000000-0000-4000-8000-000000000001"))

    assert snapshot["current"]["confirmed_params"]["warn_percent"] == 82
  end

  test "concurrent duplicate ingestion opens one incident and one durable job" do
    connect()
    report = measurement("CRIT")
    results = for _ <- 1..4, do: Task.async(fn -> ingest(report) |> disposition() end)

    assert Enum.sort(Enum.map(results, &Task.await/1)) == [
             "current",
             "duplicate",
             "duplicate",
             "duplicate"
           ]

    assert Repo.aggregate(Incident, :count) == 1
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "admission progress survives receipt pruning" do
    connect()
    report = measurement("CRIT", 10)
    ingest(report)
    Repo.delete_all(Observation)
    assert disposition(ingest(report)) == "historical"
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 10
  end
end
