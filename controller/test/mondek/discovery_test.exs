# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DiscoveryTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Discovery, ResultStream}

  defp discovery do
    # The controller tests run from controller/.
    Path.expand("../contracts/v1/discovery.json")
    |> File.read!()
    |> Jason.decode!()
    |> hd()
    |> Map.fetch!("value")
  end

  defp publish(value, sequence \\ 1) do
    report = measurement("WARN", sequence)

    report =
      update_in(report["results"], fn [result] -> [Map.put(result, "discovery", value)] end)

    assert disposition(ingest(report)) == "current"

    Repo.get_by!(ResultStream,
      assignment_id: "10000000-0000-4000-8000-000000000001",
      result_key: "capacity"
    ).id
  end

  defp selections,
    do: [%{"candidate_key" => "data", "choice_key" => "monitor", "params" => %{"limit" => 85}}]

  test "shared hostile wire corpus and result admission agree" do
    for example <- File.read!("../contracts/v1/discovery.json") |> Jason.decode!() do
      assert Discovery.valid?(example["value"]) == example["valid"], example["name"]

      report =
        update_in(measurement("WARN")["results"], fn [result] ->
          [Map.put(result, "discovery", example["value"])]
        end)

      assert Mondek.Protocol.report(report, at()) == :ok == example["valid"], example["name"]
    end
  end

  test "review proposes source changes without altering inventory or acknowledging incidents" do
    connect()
    id = publish(discovery())
    snapshot = Discovery.inspect(id, at())
    assert snapshot["reviewable"]
    before = {Repo.all(Assignment), Repo.all(Incident), Repo.all(ResultStream)}
    assert {:ok, review} = Discovery.review(id, snapshot["fingerprint"], selections(), at())
    assert review["prompt"] =~ "Do not deploy"
    assert review["prompt"] =~ snapshot["observation_id"]
    assert review["prompt"] =~ "Mounted at /data"
    assert before == {Repo.all(Assignment), Repo.all(Incident), Repo.all(ResultStream)}

    assert {:error, _} =
             Discovery.review(id, snapshot["fingerprint"], selections() ++ selections(), at())

    assert {:error, _} =
             Discovery.review(
               id,
               snapshot["fingerprint"],
               [Map.put(hd(selections()), "candidate_key", "other")],
               at()
             )

    assert {:error, _} =
             Discovery.review(
               id,
               snapshot["fingerprint"],
               [Map.put(hd(selections()), "params", %{"limit" => 101})],
               at()
             )
  end

  test "identical fresh scans retain drafts but changed evidence invalidates them" do
    connect()
    id = publish(discovery())
    first = Discovery.inspect(id, at())
    publish(discovery(), 2)
    second = Discovery.inspect(id, at())
    assert first["fingerprint"] == second["fingerprint"]
    refute first["observation_id"] == second["observation_id"]
    assert {:ok, _} = Discovery.review(id, first["fingerprint"], selections(), at())
    publish(Map.put(discovery(), "instructions", "Changed source guidance"), 3)
    assert {:error, message} = Discovery.review(id, first["fingerprint"], selections(), at())
    assert message =~ "changed"
  end

  test "retained stale, unavailable, retired and old-configuration evidence cannot produce proposals" do
    connect()
    id = publish(discovery())
    fingerprint = Discovery.inspect(id, at())["fingerprint"]
    assert {:error, _} = Discovery.review(id, fingerprint, selections(), DateTime.add(at(), 3600))

    assert disposition(ingest(measurement("WARN", 2, %{"results" => [], "complete" => false}))) ==
             "current"

    assert Discovery.inspect(id, at())["discovery"] == discovery()
    assert {:error, _} = Discovery.review(id, fingerprint, selections(), at())
    publish(discovery(), 3)
    assignment = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    Monitoring.change(assignment, %{desired_generation: 2})
    assert {:error, _} = Discovery.review(id, fingerprint, selections(), at())
    Monitoring.change(assignment, %{desired_generation: 1})
    Monitoring.change(Repo.get!(ResultStream, id), %{retired_at: at()})
    assert {:error, _} = Discovery.review(id, fingerprint, selections(), at())
  end

  test "a new measurement without discovery removes previous candidates" do
    connect()
    id = publish(discovery())
    assert Discovery.inspect(id, at())
    ingest(measurement("OK", 2))
    assert Discovery.inspect(id, at()) == nil
  end

  test "source identity changes invalidate a saved review even with identical candidate data" do
    connect()
    id = publish(discovery())
    first = Discovery.inspect(id, at())

    Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"), %{
      source_revision: "changed-source"
    })

    assert {:error, message} = Discovery.review(id, first["fingerprint"], selections(), at())
    assert message =~ "changed"
  end

  test "foreign observation references cannot expose another assignment's discoveries" do
    connect()
    id = publish(discovery())
    observation = Repo.get!(Observation, Discovery.inspect(id, at())["observation_id"])
    Monitoring.change(observation, %{assignment_id: "10000000-0000-4000-8000-000000000002"})
    assert Discovery.inspect(id, at()) == nil
    assert {:error, _} = Discovery.review(id, "invented", selections(), at())
  end
end
