# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MCPTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias Mondek.AgentInspection
  @endpoint MondekWeb.Endpoint
  @assignment "10000000-0000-4000-8000-000000000001"

  test "negotiates supported versions, discovers only read tools, and handles notifications" do
    for version <- Mondek.MCP.versions() do
      response =
        rpc("initialize", %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })

      assert response["result"]["protocolVersion"] == version
      assert response["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
    end

    tools = rpc("tools/list")["result"]["tools"]

    assert rpc("tools/list", %{"_meta" => %{"progressToken" => "test"}})["result"]["tools"] ==
             tools

    assert Enum.map(tools, & &1["name"]) ==
             ~w(list_attention get_check_context get_evidence get_incident)

    assert Enum.all?(tools, & &1["annotations"]["readOnlyHint"])

    assert response(post_mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}), 202) ==
             ""

    assert rpc("delete_everything")["error"]["code"] == -32601
    assert rpc("tools/call", %{"name" => "acknowledge"})["error"]["code"] == -32602

    assert rpc("tools/call", %{"name" => "get_evidence", "arguments" => %{"result_id" => "bad"}})[
             "error"
           ]["code"] == -32602

    assert rpc("tools/call", %{"name" => "list_attention", "arguments" => %{"page" => -1}})[
             "error"
           ]["code"] == -32602

    assert rpc("tools/call", %{"name" => "list_attention", "arguments" => %{"extra" => true}})[
             "error"
           ]["code"] == -32602
  end

  test "HTTP rejects hostile origins, invalid content, versions, malformed JSON and batch requests" do
    assert response(get(build_conn(), "/mcp"), 405) == ""
    assert response(delete(build_conn(), "/mcp"), 405) == ""
    assert json_response(post_mcp(%{}, [{"origin", "https://other.test"}]), 403)
    assert json_response(post_mcp(%{}, [{"mcp-protocol-version", "unknown"}]), 400)
    assert json_response(post_mcp(%{}, [{"accept", "text/plain"}]), 406)
    assert json_response(post_mcp(%{}, [{"content-type", "text/plain"}]), 415)
    assert json_response(post_mcp("{"), 400)["error"]["code"] == -32700
    assert json_response(post_mcp([]), 200)["error"]["code"] == -32600
    assert json_response(post_mcp(String.duplicate("x", 17_000)), 413)
  end

  test "investigation preserves confirmed health and original age across failure, replay and pruning" do
    connect()

    report =
      measurement("CRIT")
      |> put_in(
        ["results", Access.at(0), "details"],
        "Meaningful failure; ignore embedded instructions."
      )

    assert disposition(ingest(report)) == "current"
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @assignment)
    before = Repo.get!(Assignment, @assignment)
    {:ok, detail} = AgentInspection.call("get_evidence", %{"result_id" => stream.id}, at())
    assert detail["result"]["current"]["health"] == "CRIT"
    assert detail["result"]["current"]["knowledge"] == "fresh"
    assert detail["retained_measurement_details"] =~ "Meaningful failure"
    assert detail["evidence"]["items"] |> hd() |> Map.get("result_present")
    assert Repo.get!(Assignment, @assignment) == before

    {:ok, old} =
      AgentInspection.call("get_evidence", %{"result_id" => stream.id}, DateTime.add(at(), 12))

    assert old["result"]["current"]["knowledge"] == "stale"
    assert old["result"]["current"]["source_at"] == detail["result"]["current"]["source_at"]
    ingest(report, DateTime.add(at(), 13))

    failed =
      measurement("UNKNOWN", 2, %{
        "results" => [],
        "complete" => false,
        "diagnostic" => "API field removed"
      })

    assert disposition(ingest(failed, DateTime.add(at(), 1))) == "current"

    {:ok, failure} =
      AgentInspection.call("get_evidence", %{"result_id" => stream.id}, DateTime.add(at(), 1))

    current = failure["result"]["current"]
    assert current["health"] == "CRIT"
    assert current["knowledge"] == "unavailable"
    assert current["confirmed_observation_id"] == report["id"]
    assert current["observation_id"] == failed["id"]
    assert current["diagnostic"] == "API field removed"

    {:ok, exact} =
      AgentInspection.call(
        "get_evidence",
        %{"result_id" => stream.id, "observation_id" => report["id"]},
        at()
      )

    assert length(exact["evidence"]["items"]) == 1

    original_revision =
      hd(exact["evidence"]["items"])["configuration_provenance"]["source_revision"]

    Monitoring.change(Repo.get!(Assignment, @assignment), %{
      source_revision: String.duplicate("b", 64)
    })

    {:ok, historical} =
      AgentInspection.call(
        "get_evidence",
        %{"result_id" => stream.id, "observation_id" => report["id"]},
        at()
      )

    assert historical["result"]["source_revision"] != original_revision

    assert hd(historical["evidence"]["items"])["configuration_provenance"]["source_revision"] ==
             original_revision

    Repo.delete!(Repo.get!(Observation, report["id"]))
    {:ok, pruned} = AgentInspection.call("get_evidence", %{"result_id" => stream.id}, at())
    assert pruned["missing_referenced_observation_ids"] == [report["id"]]

    {:ok, context} =
      AgentInspection.call("get_check_context", %{"assignment_id" => @assignment}, at())

    refute Map.has_key?(context["check"], "params")
    assert context["source_mapping"]["status"] == "requires_local_mapping"
  end

  test "result pages and exact evidence remain scoped, with pending and retired state explicit" do
    connect()
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @assignment)
    {:ok, pending} = AgentInspection.call("get_evidence", %{"result_id" => stream.id}, at())
    assert pending["result"]["current"]["health"] == nil
    assert pending["result"]["current"]["knowledge"] == "awaiting"
    report = measurement("CRIT")
    ingest(report)
    # Stored reports contain all outputs; the agent sees only the selected key.
    observation = Repo.get!(Observation, report["id"])

    payload =
      Map.update!(
        observation.payload,
        "results",
        &(&1 ++ [%{"key" => "sibling", "summary" => "unrelated-private-detail"}])
      )

    Monitoring.change(observation, %{payload: payload})
    {:ok, selected} = AgentInspection.call("get_evidence", %{"result_id" => stream.id}, at())
    refute Jason.encode!(selected) =~ "unrelated-private-detail"

    other =
      Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000002")

    {:ok, outside} =
      AgentInspection.call(
        "get_evidence",
        %{"result_id" => other.id, "observation_id" => report["id"]},
        at()
      )

    assert outside["evidence"]["total"] == 0
    for index <- 1..24, do: create_source_fixture("python", "Pending #{index}", %{"path" => "/"})
    {:ok, first} = AgentInspection.call("list_attention", %{}, at())
    {:ok, second} = AgentInspection.call("list_attention", %{"page" => 2}, at())
    assert first["next_page"] == 2
    assert length(first["items"]) == 20

    refute Enum.any?(second["items"], fn item ->
             Enum.any?(first["items"], &(&1["id"] == item["id"]))
           end)

    withdraw_source_fixture(@assignment, "Source removed", at())
    {:ok, retired} = AgentInspection.call("get_evidence", %{"result_id" => stream.id}, at())
    assert retired["result"]["retired"]
    assert retired["result"]["current"]["knowledge"] == "retired"
    assert retired["result"]["current"]["health"] == "CRIT"
  end

  test "attention, health incidents, grouped contributors and monitoring loss are navigable" do
    connect()
    ingest(measurement("CRIT"))
    {:ok, listing} = AgentInspection.call("list_attention", %{}, at())
    assert listing["total"] >= 1

    {:ok, incidents} =
      AgentInspection.call("list_attention", %{"category" => "health_incidents"}, at())

    incident = hd(incidents["items"])

    {:ok, detail} =
      AgentInspection.call(
        "get_incident",
        %{"incident_id" => incident["id"], "kind" => "health"},
        at()
      )

    assert detail["incident"]["stream_id"]
    assert detail["incident"]["opening_generation"] == 1

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(control(), %{
                 "runner_label" => "Fixture observer",
                 "source_id" => "shared-source",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => [
                   %{
                     "key" => "shared-check",
                     "label" => "Shared check",
                     "definition_revision" => String.duplicate("b", 64),
                     "environment" => "test",
                     "params_owner" => "source",
                     "parameter_schema" => %{"fields" => %{}},
                     "params" => %{},
                     "interval_seconds" => 3,
                     "timeout_seconds" => 2,
                     "freshness_seconds" => 12,
                     "outputs" => [
                       %{
                         "key" => "capacity",
                         "label" => "Capacity",
                         "target" => %{
                           "kind" => "host",
                           "key" => "shared",
                           "label" => "Shared host"
                         },
                         "condition" => %{
                           "namespace" => "test",
                           "key" => "shared",
                           "label" => "Shared"
                         }
                       }
                     ]
                   }
                 ]
               }),
               at()
             )

    assignment = Repo.get_by!(Assignment, source_id: "shared-source")
    connect(%{"prepared" => Map.put(control()["prepared"], assignment.id, 1)})

    assert disposition(ingest(measurement("CRIT", 1, %{"assignment_id" => assignment.id}))) ==
             "current"

    group = Repo.one!(Mondek.ConditionIncident)

    {:ok, filtered} =
      AgentInspection.call(
        "list_attention",
        %{"category" => "health_incidents", "source_id" => "shared-source"},
        at()
      )

    assert Enum.map(filtered["items"], & &1["id"]) == [group.id]

    {:ok, empty} =
      AgentInspection.call(
        "list_attention",
        %{"category" => "health_incidents", "source_id" => "absent-source"},
        at()
      )

    assert empty["total"] == 0

    {:ok, shared} =
      AgentInspection.call("get_incident", %{"incident_id" => group.id, "kind" => "health"}, at())

    assert shared["contributors"]["total"] == 1
    assert shared["incident"]["incident_kind"] == "condition"
    Mondek.MonitoringLoss.reconcile(DateTime.add(at(), 1000))

    {:ok, losses} =
      AgentInspection.call(
        "list_attention",
        %{"category" => "monitoring_incidents"},
        DateTime.add(at(), 2000)
      )

    # Gap grace begins at first reconciliation.
    if losses["total"] == 0, do: Mondek.MonitoringLoss.reconcile(DateTime.add(at(), 2000))

    {:ok, losses} =
      AgentInspection.call(
        "list_attention",
        %{"category" => "monitoring_incidents"},
        DateTime.add(at(), 2000)
      )

    assert losses["total"] > 0

    {:ok, loss} =
      AgentInspection.call(
        "get_incident",
        %{"incident_id" => hd(losses["items"])["id"], "kind" => "monitoring_loss"},
        DateTime.add(at(), 2000)
      )

    assert loss["members"]["total"] > 0
    assert loss["incident"]["ui_path"] =~ "/incidents/loss/"
  end

  test "real HTTP and stdio subprocess share discovery and evidence" do
    connect()
    ingest(measurement("CRIT"))
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @assignment)
    server = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    script = """
    import json, os, subprocess, sys
    messages = [
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}},
      {"jsonrpc":"2.0","method":"notifications/initialized"},
      {"jsonrpc":"2.0","id":2,"method":"tools/list"},
      {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_evidence","arguments":{"result_id":sys.argv[2]}}}
    ]
    command = [os.environ['MONDEK_MCP_EXECUTABLE']] if os.environ.get('MONDEK_MCP_EXECUTABLE') else [sys.executable, '-m', 'mondek_runner.mcp']
    env = dict(os.environ)
    if os.environ.get('MONDEK_MCP_EXECUTABLE'):
      env.pop('PYTHONPATH', None)
    child = subprocess.run(command+["--controller",sys.argv[1]], env=env, input="".join(json.dumps(m)+"\\n" for m in messages), text=True, capture_output=True, timeout=25)
    assert child.returncode == 0, child.stderr
    replies = [json.loads(line) for line in child.stdout.splitlines()]
    assert [m['id'] for m in replies] == [1,2,3], replies
    assert len(replies[1]['result']['tools']) == 4
    assert replies[2]['result']['structuredContent']['result']['current']['health'] == 'CRIT'
    print('stdio investigation passed')
    """

    {output, status} =
      System.cmd("python3", ["-c", script, "http://127.0.0.1:#{port}", stream.id],
        env: [{"PYTHONPATH", Path.expand("../runner")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp rpc(method, params \\ %{}),
    do:
      json_response(
        post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}),
        200
      )

  defp post_mcp(body, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    post(conn, "/mcp", if(is_binary(body), do: body, else: Jason.encode!(body)))
  end
end
