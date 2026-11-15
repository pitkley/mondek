# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.IncidentContractTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import OpenApiSpex.TestAssertions
  alias Mondek.{IncidentEvidence, Investigation, ResultStream}
  @endpoint MondekWeb.Endpoint
  @assignment "10000000-0000-4000-8000-000000000001"

  test "list and detail carry canonical identity and UI page/panel share the recorded finding" do
    connect()
    stream = Repo.get_by!(ResultStream, assignment_id: @assignment)
    Monitoring.change(stream, %{label: "Root filesystem"})
    report = failure(1, "**Disk full** on root")
    assert disposition(ingest(report)) == "current"
    incident = Repo.one!(Incident)
    Monitoring.change(incident, %{environment_label: "Old friendly environment"})

    Monitoring.change(Repo.get!(ResultStream, stream.id), %{
      environment_label: "New friendly environment"
    })

    [summary] = read("/api/v1/incidents/health")["data"]
    detail = read("/api/v1/incidents/health/#{incident.id}")["data"]
    assert summary["display_title"] == "Linux filesystem — Root filesystem"

    for key <-
          ~w(display_title check_label result_label environment_label runner_label acknowledgement_active) do
      assert Map.has_key?(summary, key)
      assert summary[key] == detail["incident"][key]
    end

    assert summary["runner_label"] == "Fixture observer"
    assert summary["environment_label"] == "New friendly environment"
    assert detail["recorded_measurement"]["measurement"]["details"] == "**Disk full** on root"

    for path <- ["/incidents/health/#{incident.id}", "/incidents/health/#{incident.id}/full"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#incident-page, #overview-panel, #incidents-panel")
      assert render(view) =~ summary["display_title"]
      assert has_element?(view, "table[aria-label='Recorded failure'] strong", "Disk full")

      assert has_element?(
               view,
               "table[aria-label='Recorded failure']",
               "New friendly environment"
             )

      assert has_element?(view, "form[id$='incident-ack-form']")
      assert has_element?(view, "a", "View latest check result")
      GenServer.stop(view.pid)
    end
  end

  test "unchanged failures advance durable references; recovery and later episodes cannot replace the finding" do
    connect()
    first = failure(1, "Opening")
    latest = failure(2, "Latest")
    assert disposition(ingest(first)) == "current"
    assert disposition(ingest(latest, DateTime.add(at(), 1))) == "current"
    i = Repo.one!(Incident)
    assert i.opening_observation_id == first["id"]
    assert i.latest_failure_observation_id == latest["id"]
    assert Repo.aggregate(Occurrence, :count) == 1
    assert disposition(ingest(measurement("OK", 3), DateTime.add(at(), 2))) == "current"
    assert disposition(ingest(failure(4, "New episode"), DateTime.add(at(), 3))) == "current"
    historical = read("/api/v1/incidents/health/#{i.id}")["data"]
    finding = historical["recorded_measurement"]
    assert finding["basis"] == "latest_failure"
    assert finding["measurement"]["observation_id"] == latest["id"]
    assert finding["measurement"]["details"] == "Latest"
    assert historical["stream"]["current"]["observation_id"] != latest["id"]
    closed = Repo.get!(Incident, i.id)
    assert closed.latest_failure_observation_id == latest["id"]
    refute historical["incident"]["acknowledgement_active"]
    # Re-reading durable rows, including after receipt retention, needs no in-memory state.
    Repo.update_all(Occurrence, set: [status: "delivered"])
    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(at(), 8 * 86_400))
    assert Repo.get!(Observation, latest["id"])
    assert IncidentEvidence.resolve_many([Repo.get!(Incident, i.id)])[i.id] == finding
  end

  test "legacy and missing references resolve only retained, selected failure evidence with explicit gaps" do
    connect()
    first = failure(1, "Historical failure")
    assert disposition(ingest(first)) == "current"
    i = Repo.one!(Incident)
    missing = Ecto.UUID.generate()
    i = %{i | latest_failure_observation_id: missing}
    finding = IncidentEvidence.resolve_many([i])[i.id]
    assert finding["basis"] == "opening_failure"
    assert hd(finding["gaps"])["reason"] == "observation_unavailable"
    assert hd(finding["gaps"])["observation_id"] == missing
    i = %{i | latest_failure_observation_id: nil, opening_observation_id: nil}
    legacy = IncidentEvidence.resolve_many([i])[i.id]
    assert legacy["basis"] == "notification_reference"
    assert legacy["measurement"]["observation_id"] == first["id"]
    assert hd(legacy["gaps"])["reason"] == "missing_reference"
    assert disposition(ingest(measurement("OK", 2), DateTime.add(at(), 1))) == "current"

    i =
      Repo.get!(Incident, i.id)
      |> Monitoring.change(%{
        latest_failure_observation_id:
          Repo.get_by!(ResultStream, assignment_id: @assignment).current["observation_id"]
      })

    finding = IncidentEvidence.resolve_many([i])[i.id]
    assert hd(finding["gaps"])["reason"] == "not_a_failure"
    assert finding["measurement"]["health"] == "CRIT"
  end

  test "a missing selected output, another incarnation and missing stream never supply fallback evidence" do
    connect()
    first = failure(1, "Old")
    ingest(first)
    i = Repo.one!(Incident)

    incomplete =
      measurement("UNKNOWN", 2, %{
        "complete" => false,
        "results" => [],
        "diagnostic" => "No result"
      })

    assert disposition(ingest(incomplete, DateTime.add(at(), 1))) == "current"
    i = Monitoring.change(i, %{latest_failure_observation_id: incomplete["id"]})

    assert hd(IncidentEvidence.resolve_many([i])[i.id]["gaps"])["reason"] ==
             "result_not_in_observation"

    stream = Repo.get!(ResultStream, i.stream_id)
    Monitoring.change(stream, %{admission_generation: 2})
    result = IncidentEvidence.resolve_many([i])[i.id]
    assert result["status"] == "unavailable"
    assert result["measurement"] == nil
    assert Enum.all?(result["gaps"], &(&1["reason"] == "out_of_scope"))
    # Defensive handling of a legacy row without a result incarnation.
    i = %{i | stream_id: nil}
    assert IncidentEvidence.resolve_many([i])[i.id]["status"] == "unavailable"
  end

  test "individual evidence stays keyed when a retained stream reference is missing" do
    # Establish the two-output fixture declaration before either output executes.
    assignment = Repo.get!(Assignment, @assignment)

    output = %{
      "key" => "private-sibling",
      "label" => "Private sibling",
      "target" => %{"kind" => "host", "key" => "private-sibling"}
    }

    outputs = assignment.outputs ++ [output]

    Monitoring.change(assignment, %{
      expected_keys: ["capacity", "private-sibling"],
      outputs: outputs
    })

    configuration = Repo.get_by!(Mondek.Configuration, assignment_id: @assignment, generation: 1)

    Monitoring.change(configuration, %{
      definition: Map.put(configuration.definition, "outputs", outputs)
    })

    Repo.insert!(%ResultStream{
      assignment_id: @assignment,
      result_key: "private-sibling",
      label: "Private sibling",
      target: output["target"]
    })

    connect()
    report = failure(1, "Selected output")

    sibling = %{
      "key" => "private-sibling",
      "health" => "CRIT",
      "summary" => "must-not-leak",
      "source_at" => "2009-09-15T08:00:00.010000Z"
    }

    report = Map.update!(report, "results", &(&1 ++ [sibling]))
    assert disposition(ingest(report)) == "current"
    incident = Repo.get_by!(Incident, result_key: "capacity")
    Monitoring.change(incident, %{stream_id: nil})
    data = read("/api/v1/incidents/health/#{incident.id}")["data"]
    refute Jason.encode!(data) =~ "must-not-leak"

    assert Enum.flat_map(data["evidence"], & &1["payload"]["results"])
           |> Enum.all?(&(&1["key"] == "capacity"))

    assert data["recorded_measurement"]["status"] == "unavailable"
  end

  test "legal measurements without source time or details serialize explicit nulls" do
    connect()

    report =
      measurement("CRIT")
      |> update_in(["results", Access.at(0)], &Map.drop(&1, ["source_at", "details"]))

    assert disposition(ingest(report)) == "current"
    stream = Repo.get_by!(ResultStream, assignment_id: @assignment)

    i =
      Repo.insert!(%Incident{
        assignment_id: @assignment,
        stream_id: stream.id,
        result_key: stream.result_key,
        health: "CRIT",
        opened_at: at(),
        opening_generation: 1,
        opening_observation_id: report["id"],
        latest_failure_observation_id: report["id"]
      })

    measurement =
      read("/api/v1/incidents/health/#{i.id}")["data"]["recorded_measurement"]["measurement"]

    assert Map.has_key?(measurement, "source_at")
    assert measurement["source_at"] == nil
    assert measurement["details"] == nil
    assert measurement["provenance"]["generation"] == 1
  end

  test "OpenAPI rejects incomplete incident findings and summaries" do
    connect()
    ingest(failure(1, "Evidence"))
    i = Repo.one!(Incident)
    detail = read("/api/v1/incidents/health/#{i.id}")
    spec = MondekWeb.API.ApiSpec.spec()

    schema =
      spec.paths["/api/v1/incidents/health/{id}"].get.responses[200].content["application/json"].schema

    assert {:ok, _} = OpenApiSpex.cast_value(detail, schema, spec)

    for malformed <- [
          update_in(detail, ["data"], &Map.delete(&1, "recorded_measurement")),
          update_in(
            detail,
            ["data", "recorded_measurement", "measurement", "provenance"],
            &Map.delete(&1, "generation")
          ),
          update_in(detail, ["data", "incident"], &Map.delete(&1, "acknowledgement_active")),
          put_in(detail, ["data", "incident", "display_title"], nil)
        ] do
      assert {:error, _} = OpenApiSpex.cast_value(malformed, schema, spec)
    end
  end

  test "acknowledgements agree at exact expiry and command receipts retain canonical identity" do
    connect()
    ingest(failure(1, "Failure"))
    i = Repo.one!(Incident)
    until = DateTime.add(at(), 10)
    Monitoring.change(i, %{acknowledgement_mode: "until", acknowledged_until: until})

    for {clock, active} <- [{DateTime.add(until, -1, :microsecond), true}, {until, false}] do
      [summary] = Investigation.health_incidents(%{}, clock)["items"]
      detail = Investigation.health_detail(i.id, %{}, clock)
      assert summary["acknowledgement_active"] == active
      assert detail["incident"]["acknowledgement_active"] == active
    end

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/incidents/health/#{i.id}/acknowledge",
        Jason.encode!(%{
          "mode" => "until_incident_ends",
          "revision" => 0,
          "attention_revision" => i.attention_revision
        })
      )

    assert_operation_response(conn)
    receipt = json_response(conn, 200)
    assert receipt["display_title"] == "Linux filesystem"
    assert receipt["acknowledgement_active"]
    assert receipt["check_label"] == "Linux filesystem"
  end

  test "monitoring-loss list/detail share required title and acknowledgement state without a health measurement" do
    loss =
      Repo.insert!(%Mondek.MonitoringIncident{
        scope_kind: "coverage",
        scope_key: "coverage:test",
        source_id: "test",
        label: "Absent declaration",
        opened_at: at(),
        member_count: 1,
        acknowledgement_mode: "until_incident_ends"
      })

    [summary] = read("/api/v1/incidents/monitoring-loss")["data"]
    detail = read("/api/v1/incidents/monitoring-loss/#{loss.id}")["data"]
    assert summary["display_title"] == "No runner selected"
    assert summary["acknowledgement_active"]

    for key <-
          ~w(display_title check_label result_label environment_label runner_label acknowledgement_active),
        do: assert(summary[key] == detail[key])

    refute Map.has_key?(detail, "recorded_measurement")
  end

  defmodule IncidentOnlyGateway do
    def init(opts), do: opts

    def call(conn, _) do
      if String.starts_with?(conn.request_path, "/api/v1/incidents/") do
        MondekWeb.Endpoint.call(conn, MondekWeb.Endpoint.init([]))
      else
        Plug.Conn.send_resp(conn, 403, "Incident access only")
      end
    end
  end

  test "incident-only access over real HTTP identifies and explains the failure without result permission" do
    connect()
    report = failure(1, "**Historical details**")
    ingest(report)
    i = Repo.one!(Incident)
    {:ok, _} = Application.ensure_all_started(:inets)
    server = start_supervised!({Bandit, plug: IncidentOnlyGateway, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    origin = "http://127.0.0.1:#{port}"

    assert {:ok, {{_, 403, _}, _, _}} =
             :httpc.request(String.to_charlist(origin <> "/api/v1/results/#{i.stream_id}"))

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(String.to_charlist(origin <> "/api/v1/incidents/health/#{i.id}"))

    data = Jason.decode!(body)["data"]
    assert data["incident"]["check_label"] == "Linux filesystem"
    assert data["recorded_measurement"]["measurement"]["details"] == "**Historical details**"
    assert data["recorded_measurement"]["measurement"]["observation_id"] == report["id"]
  end

  test "additive migration preserves legacy identities and does not invent a latest failure" do
    connect()
    report = failure(1, "Retained")
    ingest(report)
    i = Repo.one!(Incident)
    version = 20_261_115_150_000
    migration = Mondek.Repo.Migrations.AddLatestFailureReference

    unless Code.ensure_loaded?(migration),
      do:
        Code.require_file(
          Path.expand(
            "../../priv/repo/migrations/20261115150000_add_latest_failure_reference.exs",
            __DIR__
          )
        )

    on_exit(fn -> Ecto.Migrator.up(Repo, version, migration, log: false) end)
    assert :ok == Ecto.Migrator.down(Repo, version, migration, log: false)
    assert :ok == Ecto.Migrator.up(Repo, version, migration, log: false)
    retained = Repo.get!(Incident, i.id)
    assert retained.opening_observation_id == report["id"]
    assert retained.latest_failure_observation_id == nil
    finding = IncidentEvidence.resolve_many([retained])[i.id]
    assert finding["basis"] == "opening_failure"
    assert hd(finding["gaps"])["reason"] == "missing_reference"
  end

  defp failure(sequence, details) do
    measurement("CRIT", sequence) |> put_in(["results", Access.at(0), "details"], details)
  end

  defp read(path) do
    conn = get(build_conn(), path)
    result = json_response(conn, 200)
    assert_operation_response(conn)
    result
  end
end
