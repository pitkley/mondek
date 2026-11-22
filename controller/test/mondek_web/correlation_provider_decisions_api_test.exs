# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CorrelationProviderDecisionsAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture
  @settings :correlation_decisions_config

  test "review request is operator-initiated, replayed by identity and visible without configuration" do
    directory = Path.join(System.tmp_dir!(), "mondek-decisions-#{Ecto.UUID.generate()}")
    File.mkdir!(directory)
    file = Path.join(directory, "provider.json")
    previous = Application.fetch_env(:mondek, @settings)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mondek, @settings, value)
        :error -> Application.delete_env(:mondek, @settings)
      end

      File.rm_rf!(directory)
    end)

    Application.delete_env(:mondek, @settings)
    subject = episode_pair()
    id = Ecto.UUID.generate()
    payload = %{"request_id" => id, "subject" => %{"type" => "individual", "id" => subject}}

    assert decision_request(payload, 503)["error"]["code"] == "unavailable"

    File.write!(
      file,
      Jason.encode!(%{
        "id" => "local-fixture-adapter",
        "url" => "https://private-decision-destination.example",
        "evidence" => ["dimensions"],
        "binding_key" => String.duplicate("x", 32),
        "bearer_token" => "secret-test-marker"
      })
    )

    File.chmod!(file, 0o600)
    Application.put_env(:mondek, @settings, file)
    delivery = Repo.all(Occurrence)

    result = decision_request(payload, 200)

    assert %{"request_id" => ^id, "provider_id" => "local-fixture-adapter", "status" => "pending"} =
             result

    assert decision_request(payload, 200) == result

    body =
      get(build_conn(), "/api/v1/incidents/health/#{subject}?decisions_page=1")
      |> json_response(200)

    assert body["data"]["correlation_decisions"]["items"] == [result]
    refute Jason.encode!(body) =~ "secret-test-marker"
    refute Jason.encode!(body) =~ "private-decision-destination.example"

    rpc = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "get_incident",
        "arguments" => %{"incident_id" => subject, "kind" => "health", "decisions_page" => 1}
      }
    }

    mcp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(rpc))
      |> json_response(200)

    assert get_in(mcp, ["result", "structuredContent", "correlation_decisions"]) ==
             body["data"]["correlation_decisions"]

    assert Repo.all(Occurrence) == delivery
    assert Repo.aggregate(Mondek.CorrelationCase, :count) == 0
  end

  defp decision_request(payload, status) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/incidents/decisions/request", Jason.encode!(payload))
    |> json_response(status)
  end

  defp episode_pair do
    upstream = F.publication([F.candidate(F.check("edge", "production", "edge"))])
    application = F.publication([F.candidate(F.check("application"))])
    now = Monitoring.now()

    hint = %{
      "dimension" => "network",
      "depends_on" => %{
        "type" => "target",
        "source_id" => upstream["source_id"],
        "kind" => "service",
        "key" => "edge"
      },
      "window_seconds" => 120
    }

    application =
      put_in(
        application,
        ["checks", Access.at(0), "outputs", Access.at(0), "correlation_hints"],
        [
          hint
        ]
      )

    for publication <- [upstream, application] do
      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = F.activate(publication, now)
      assert disposition(F.sample(publication, "CRIT", 1, now)) == "current"
    end

    [assignment] = F.assignments(application)
    Repo.get_by!(Incident, assignment_id: assignment.id).id
  end
end
