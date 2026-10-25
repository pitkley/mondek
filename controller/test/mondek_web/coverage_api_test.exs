# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  alias Mondek.CoverageFixtures, as: F
  @endpoint MondekWeb.Endpoint

  test "coverage endpoints serialize exact ownership, bounded pages and retained publication time" do
    now = Monitoring.now()
    p = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(p, now)
    assert {:ok, _} = F.activate(p, now)
    assert disposition(F.sample(p, "CRIT", 1, now)) == "current"
    body = build_conn() |> get("/api/v1/coverage") |> json_response(200)
    [scope] = body["items"]
    assert body["summary"]["observed"] == 1
    assert scope["counts"]["fresh"] == 1
    assert build_conn() |> get("/api/v1/coverage/#{scope["id"]}") |> json_response(200) == scope

    detail =
      build_conn() |> get("/api/v1/coverage/#{scope["id"]}/observers") |> json_response(200)

    [observer] = detail["items"]
    assert observer["runner_id"] == p["installation_id"]
    assert observer["measurement_state"] == "fresh"
    assert {:ok, _, 0} = DateTime.from_iso8601(observer["coverage_received_at"])
    assert observer["current"]["health"] == "CRIT"
    assert observer["configuration"]["desired_generation"] == 1

    [publisher] =
      (build_conn() |> get("/api/v1/coverage/publishers") |> json_response(200))["items"]

    assert publisher["runner_id"] == p["installation_id"]
    assert publisher["audit_status"] == "confirmed"

    assert (build_conn() |> get("/api/v1/coverage/diagnostics") |> json_response(200))["items"] ==
             []

    assert build_conn() |> get("/api/v1/coverage/not-an-identity") |> json_response(404)
  end

  test "malformed public catalogues are rejected rather than admitted as missing coverage" do
    p = F.publication([F.candidate(F.check(), false)])
    malformed = p |> put_in(["coverage", "version"], 2)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/v1/inventory", malformed)

    assert conn.status == 422
    assert json_response(conn, 422)["error"]
    assert Repo.aggregate(Mondek.SourceInventory, :count) == 0
    assert Repo.aggregate(Mondek.CoverageDeclaration, :count) == 0
  end

  test "explicit and omitted executable environments share the exact resolved null scope" do
    now = Monitoring.now()

    for omit? <- [false, true] do
      p = F.publication([F.candidate(F.check("service", nil, "concrete-target"))])

      p =
        if omit?,
          do:
            Map.update!(p, "checks", fn checks ->
              Enum.map(checks, &Map.drop(&1, ~w(environment environment_label)))
            end),
          else: p

      response =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/v1/inventory", p)
        |> json_response(200)

      assert response["accepted_checks"] == 1
      assert {:ok, _} = F.activate(p, now)
      assert disposition(F.sample(p, "OK", 1, now)) == "current"
    end

    listing = build_conn() |> get("/api/v1/coverage") |> json_response(200)
    [scope] = listing["items"]
    assert scope["environment"] == nil
    assert scope["status"] == "observed"
    assert scope["counts"]["fresh"] == 2
    assert scope["target"]["key"] == "concrete-target"
  end
end
