# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.EnvironmentScopeTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  alias Mondek.{CoverageDeclaration, ResultStream, Runner, SourceInventory, Protocol}
  alias Mondek.CoverageFixtures, as: F
  @endpoint MondekWeb.Endpoint

  test "inventory API rejects output environment fields atomically before any membership or session change" do
    {p, a, now} = setup_publication()
    report = sample(p, a, "CRIT", 1, now)
    assert disposition(send_report(p, report, now)) == "current"
    before = inventory_state(p)
    original = Repo.get!(Observation, report["id"])
    incident = Repo.one!(Incident)

    for field <- ~w(environment environment_label), value <- [nil, "production", "staging"] do
      changed =
        p
        |> Map.merge(%{
          "inventory_revision" => 2,
          "boot" => 2,
          "session_id" => Ecto.UUID.generate()
        })
        |> put_in(["checks", Access.at(0), "outputs", Access.at(0), field], value)

      error = post_json("/api/v1/inventory", changed, 422)
      assert error["error"] =~ "Outputs cannot declare environment or environment_label"
      assert error["error"] =~ "separate environment bindings"
      assert inventory_state(p) == before
      assert Repo.get!(Observation, report["id"]) == original
      assert Repo.get!(Incident, incident.id) == incident
    end

    assert {:ok, _} = Monitoring.inventory(p, now)
    assert disposition(send_report(p, report, now)) == "duplicate"
  end

  test "unsupported environment fields on excluded catalogue outputs reject the complete declaration" do
    p = F.publication([F.candidate(F.check(), false)])
    assert {:ok, _} = Monitoring.inventory(p, at())
    before = inventory_state(p)

    for field <- ~w(environment environment_label), value <- [nil, "staging"] do
      changed =
        p
        |> Map.put("inventory_revision", 2)
        |> put_in(["coverage", "candidates", Access.at(0), "outputs", Access.at(0), field], value)

      assert {:error, {:invalid, message}} = Monitoring.inventory(changed, at())
      assert message =~ "Outputs cannot declare"
      assert post_json("/api/v1/inventory", changed, 422)["error"] == message
      assert inventory_state(p) == before
    end
  end

  test "explicit unscoped assignments and unrelated metadata extensions remain supported" do
    check = F.check("unscoped", nil)

    p =
      F.publication([F.candidate(check)])
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "vendor_extension"], %{
        "environment" => "descriptive data"
      })

    now = Monitoring.now()
    assert post_json("/api/v1/inventory", p, 200)["accepted_checks"] == 1
    assert {:ok, _} = F.activate(p, now)
    [a] = F.assignments(p)

    report =
      sample(p, a, "OK", 1, now)
      |> put_in(["results", Access.at(0), "vendor_extension"], %{
        "environment" => "descriptive data"
      })

    assert Protocol.report(report, now) == :ok
    assert disposition(send_report(p, report, now)) == "current"
    stream = Repo.get_by!(ResultStream, assignment_id: a.id)
    assert stream.environment == nil
    assert stream.current["health"] == "OK"
    assert Repo.get!(Observation, report["id"]).payload == report
  end

  test "runtime environment overrides reject a whole execution without changing sibling evidence or incidents" do
    {p, a, now} = setup_publication(true)
    original = sample(p, a, "CRIT", 1, now)
    assert disposition(send_report(p, original, now)) == "current"
    streams = Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id, order_by: s.id)
    incidents = Repo.all(from i in Incident, order_by: i.id)
    occurrences = Repo.all(from o in Occurrence, order_by: o.id)

    for field <- ~w(environment environment_label), value <- [nil, "production", "staging"] do
      changed =
        sample(p, a, "OK", 9999, now)
        |> put_in(["results", Access.at(1), field], value)

      assert {:error, {:unsupported_result_environment, message}} = Protocol.report(changed, now)
      assert message =~ "accepted scheduled check"

      response =
        post_json(
          "/api/v1/observations",
          envelope([changed], Map.take(p, ~w(installation_id session_id))),
          200
        )

      assert response["dispositions"] == [
               %{
                 "id" => changed["id"],
                 "disposition" => "rejected",
                 "reason" => "unsupported_result_environment",
                 "error" => message
               }
             ]

      assert Repo.get(Observation, changed["id"]) == nil

      assert Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id, order_by: s.id) ==
               streams

      assert Repo.all(from i in Incident, order_by: i.id) == incidents
      assert Repo.all(from o in Occurrence, order_by: o.id) == occurrences
      assert Repo.get!(Assignment, a.id).last_sequence == 1
    end
  end

  test "a rejected environment override cannot poison valid reports or consume sequence authority" do
    {p, a, now} = setup_publication()

    invalid =
      sample(p, a, "CRIT", 9999, now)
      |> put_in(["results", Access.at(0), "environment"], "staging")

    valid = sample(p, a, "OK", 2, now)

    response =
      post_json(
        "/api/v1/observations",
        envelope([invalid, valid], Map.take(p, ~w(installation_id session_id))),
        200
      )

    assert Enum.map(response["dispositions"], & &1["disposition"]) == ["rejected", "current"]
    assert Repo.get!(Assignment, a.id).last_sequence == 2
    assert Repo.get(Observation, invalid["id"]) == nil
    assert Repo.get!(Observation, valid["id"]).payload == valid
    assert Repo.get_by!(ResultStream, assignment_id: a.id).environment == "production"
    assert disposition(send_report(p, valid, now)) == "duplicate"
  end

  test "malformed declaration and result shapes still return normal validation errors" do
    assert {:error, {:invalid, _}} = Mondek.Inventory.validate(%{"checks" => nil})

    assert {:error, {:invalid, _}} =
             Mondek.Inventory.validate(%{
               "checks" => [%{"outputs" => nil}],
               "coverage" => %{"candidates" => [%{"outputs" => nil}]}
             })

    assert {:error, {:invalid, _}} = Protocol.report(%{"results" => nil}, at())

    assert {:error, {:invalid, _}} =
             Protocol.report(%{"results" => [%{"environment" => nil}]}, at())
  end

  test "an exact previously committed unsupported-field report retains only its owned immutable receipt" do
    {p, a, now} = setup_publication()
    accepted = sample(p, a, "CRIT", 1, now)
    assert disposition(send_report(p, accepted, now)) == "current"
    before = inventory_state(p)
    stream = Repo.get_by!(ResultStream, assignment_id: a.id)
    incident = Repo.one!(Incident)
    occurrence = Repo.one!(Occurrence)

    # Model a receipt saved before this validation upgrade. The old controller
    # ignored the extra field; this historical fixture grants no new authority.
    legacy_report =
      sample(p, a, "OK", 9000, now)
      |> put_in(["results", Access.at(0), "environment"], "staging")
      |> put_in(["results", Access.at(0), "value"], 1.0e24)

    legacy =
      Repo.insert!(%Observation{
        id: legacy_report["id"],
        assignment_id: a.id,
        installation_id: p["installation_id"],
        session_id: p["session_id"],
        generation: a.desired_generation,
        sequence: 9000,
        started_at: now,
        evaluated_at: now,
        received_at: now,
        payload: legacy_report,
        disposition: "historical"
      })
      |> Repo.reload!()

    assert {:error, {:unsupported_result_environment, _}} = Protocol.report(legacy_report, now)

    assert {:ok,
            %{
              "dispositions" => [
                %{"disposition" => "duplicate", "original_disposition" => "historical"}
              ]
            }} = send_report(p, legacy_report, now)

    changed = put_in(legacy_report, ["results", Access.at(0), "environment"], "production")
    assert disposition(send_report(p, changed, now)) == "conflict"
    new = Map.put(legacy_report, "id", Ecto.UUID.generate())
    assert disposition(send_report(p, new, now)) == "rejected"

    other = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(other, now)
    assert {:ok, _} = F.activate(other, now)
    assert disposition(send_report(other, legacy_report, now)) == "rejected"
    forged = Map.put(legacy_report, "installation_id", other["installation_id"])
    assert disposition(send_report(other, forged, now)) == "rejected"
    assert Repo.get!(Observation, legacy.id) == legacy
    assert Repo.get(Observation, new["id"]) == nil
    assert inventory_state(p) == before
    assert Repo.get!(ResultStream, stream.id) == stream
    assert Repo.get!(Incident, incident.id) == incident
    assert Repo.get!(Occurrence, occurrence.id) == occurrence
  end

  defp setup_publication(pair? \\ false) do
    check = F.check()

    check =
      if pair?,
        do:
          Map.update!(check, "outputs", fn [output] ->
            [output, %{output | "key" => "sibling"}]
          end),
        else: check

    p = F.publication([F.candidate(check)])
    now = Monitoring.now()
    assert {:ok, _} = Monitoring.inventory(p, now)
    assert {:ok, _} = F.activate(p, now)
    [a] = F.assignments(p)
    {p, a, now}
  end

  defp sample(p, a, health, sequence, now) do
    measurement(health, sequence, %{
      "assignment_id" => a.id,
      "installation_id" => p["installation_id"],
      "session_id" => p["session_id"],
      "generation" => a.desired_generation,
      "started_at" => Monitoring.iso(now),
      "evaluated_at" => Monitoring.iso(now),
      "results" =>
        for(
          output <- a.outputs,
          do: %{
            "key" => output["key"],
            "health" => health,
            "summary" => "Measured #{health}",
            "source_at" => Monitoring.iso(now)
          }
        )
    })
  end

  defp send_report(p, report, now),
    do: Monitoring.ingest(envelope([report], Map.take(p, ~w(installation_id session_id))), now)

  defp inventory_state(p) do
    {Repo.get!(Runner, p["installation_id"]),
     Repo.get_by!(SourceInventory, runner_id: p["installation_id"], source_id: p["source_id"]),
     F.assignments(p),
     Repo.all(
       from d in CoverageDeclaration, where: d.runner_id == ^p["installation_id"], order_by: d.id
     )}
  end

  defp post_json(path, body, status),
    do:
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(path, body)
      |> json_response(status)
end
