# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ResultDetailsTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Protocol, ResultStream}

  test "optional plain text is bounded by UTF-8 bytes and rejects invalid values before persistence" do
    connect()
    assert :ok = Protocol.report(measurement("OK"), at())

    for {details, sequence} <-
          Enum.with_index(
            [nil, "", "Line one\nLine two\t<plain text>", String.duplicate("é", 8192)],
            1
          ) do
      sample = with_details(measurement("OK", sequence), details)
      assert :ok = Protocol.report(sample, at())
      assert disposition(ingest(sample)) == "current"
      assert hd(Repo.get!(Observation, sample["id"]).payload["results"])["details"] == details
    end

    count = Repo.aggregate(Observation, :count)

    for details <- [String.duplicate("é", 8192) <> "x", 42, [], %{}, true, "text\0tail", <<255>>] do
      sample = with_details(measurement("CRIT", 2), details)
      assert {:error, {:invalid, _}} = Protocol.report(sample, at())
      assert disposition(ingest(sample)) == "rejected"
    end

    assert Repo.aggregate(Observation, :count) == count
    assert Repo.aggregate(Incident, :count) == 0
  end

  test "actual HTTP preserves multiline details, exact retry identity and ordinary report bounds" do
    pid = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}"
    assert {200, _} = post(url, "/api/v1/control", control())
    time = DateTime.to_iso8601(Monitoring.now())

    sample =
      measurement("CRIT", 1, %{"started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)
      |> with_details("Backup completed with errors.\nElapsed: 3 seconds\n<untrusted> & text")

    assert {200, %{"dispositions" => [%{"disposition" => "current"}]}} =
             post(url, "/api/v1/observations", envelope([sample]))

    assert {200, %{"dispositions" => [%{"disposition" => "duplicate"}]}} =
             post(url, "/api/v1/observations", envelope([sample]))

    assert {200, %{"dispositions" => [%{"disposition" => "conflict"}]}} =
             post(
               url,
               "/api/v1/observations",
               envelope([with_details(sample, "Changed details")])
             )

    assert Repo.get!(Observation, sample["id"]).payload == sample
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.aggregate(Occurrence, :count) == 1
    refute Jason.encode!(Repo.one!(Occurrence).payload) =~ "untrusted"

    large_report = with_details(sample, String.duplicate("x", 16_384))

    assert {413, _} =
             post(url, "/api/v1/observations", envelope(List.duplicate(large_report, 17)))
  end

  test "retained details keep confirmed provenance through changed configuration, failure and stale collection" do
    connect()

    opening =
      with_details(measurement("CRIT"), "Original measured failure\nCollected before edit")

    assert disposition(ingest(opening)) == "current"
    incident = Repo.one!(Incident)

    stream =
      Repo.one!(
        from s in ResultStream, where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
      )

    assignment = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert {:ok, _} =
             Monitoring.save_assignment(
               assignment.id,
               1,
               Map.put(assignment.params, "crit_percent", 95)
             )

    connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})

    failed =
      measurement("UNKNOWN", 2, %{"generation" => 2, "complete" => false})
      |> put_in(["results", Access.at(0), "source_at"], nil)
      |> with_details("New execution could not reach the source")

    assert disposition(ingest(failed)) == "current"
    current = Monitoring.stream_inspection(stream.id, at())["stream"]["current"]
    assert current["details"] == hd(opening["results"])["details"]
    assert current["execution_details"] == hd(failed["results"])["details"]
    assert current["confirmed_observation_id"] == opening["id"]
    assert current["confirmed_generation"] == 1
    assert current["generation"] == 2
    assert current["knowledge"] == "unavailable"

    stale =
      with_details(measurement("OK", 3, %{"generation" => 2}), "Old source data is not recovery")

    assert disposition(ingest(stale, DateTime.add(at(), 1000))) == "current"

    current =
      Monitoring.stream_inspection(stream.id, DateTime.add(at(), 1000))["stream"]["current"]

    assert current["knowledge"] == "stale"
    assert current["details"] == hd(opening["results"])["details"]
    assert current["execution_details"] == hd(stale["results"])["details"]
    assert current["confirmed_generation"] == 1

    # A new measurement without details clears the old text, while its incident
    # continues to reference the exact original evidence.
    recovered_at = DateTime.add(at(), 1001)
    recovered_time = DateTime.to_iso8601(recovered_at)

    recovery =
      measurement("OK", 4, %{
        "generation" => 2,
        "started_at" => recovered_time,
        "evaluated_at" => recovered_time
      })
      |> put_in(["results", Access.at(0), "source_at"], recovered_time)

    assert disposition(ingest(recovery, recovered_at)) == "current"
    current = Monitoring.stream_inspection(stream.id, recovered_at)["stream"]["current"]
    assert current["details"] == nil
    assert current["execution_details"] == nil
    assert current["confirmed_generation"] == 2
    detail = Monitoring.incident_detail(incident.id, recovered_at)
    assert detail["incident"]["closure_reason"] == "configuration_changed"
    assert Enum.find(detail["evidence"], &(&1["id"] == opening["id"]))["payload"] == opening
  end

  defp with_details(sample, details),
    do: put_in(sample, ["results", Access.at(0), "details"], details)

  defp post(url, path, body) do
    {:ok, {{_, code, _}, _, json}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> path), [], ~c"application/json", Jason.encode!(body)},
        [timeout: 5000],
        body_format: :binary
      )

    {code,
     case Jason.decode(json) do
       {:ok, value} -> value
       {:error, _} -> %{"error" => json}
     end}
  end
end
