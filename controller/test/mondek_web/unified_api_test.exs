# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.UnifiedAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  import OpenApiSpex.TestAssertions
  @endpoint MondekWeb.Endpoint
  @assignment "10000000-0000-4000-8000-000000000001"

  test "all resource operations are described and generated without application startup" do
    spec = MondekWeb.API.ApiSpec.spec()
    assert spec.paths["/api/v1/runner/control"].post.operationId == "exchangeRunnerControl"
    assert spec.paths["/api/v1/results/{id}/evidence/{observation_id}"].get
    assert get(build_conn(), "/api/v1/openapi.json") |> json_response(200) |> Map.get("openapi")
    assert get(build_conn(), "/api/docs") |> html_response(200) =~ "Mondek HTTP API"
    refute Map.has_key?(spec.paths, "/api/v1/control")
  end

  test "read envelopes, typed queries, empty pages and unknown inputs" do
    conn = get(build_conn(), "/api/v1/results?page=2")
    assert %{"data" => [], "meta" => %{"page" => 2, "as_of" => _}} = json_response(conn, 200)
    assert_operation_response(conn)
    conn = get(build_conn(), "/api/v1/assignments/#{@assignment}?page=2")
    assert json_response(conn, 200)["data"]["results"]["items"] == []
    assert_operation_response(conn)

    for path <- ["/api/v1/results?page=0", "/api/v1/results?attention=invalid"] do
      conn = get(build_conn(), path)
      assert json_response(conn, 422)["error"]["code"] == "invalid_request"
      assert_operation_response(conn)
    end

    assert json_response(get(build_conn(), "/api/v1/results?unrecognized=yes"), 400)["error"][
             "code"
           ] == "unknown_parameter"
  end

  test "result evidence has exact incarnation scope and never leaks siblings or extensions" do
    connect()
    report = measurement("CRIT") |> Map.put("private_extension", "do-not-expose")
    assert disposition(ingest(report)) == "current"
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @assignment)
    conn = get(build_conn(), "/api/v1/results/#{stream.id}")
    data = json_response(conn, 200)["data"]
    assert data["current"]["health"] == "CRIT"
    refute Map.has_key?(data, "params")
    assert_operation_response(conn)
    conn = get(build_conn(), "/api/v1/results/#{stream.id}/evidence/#{report["id"]}")
    evidence = json_response(conn, 200)["data"]
    assert evidence["result"]["key"] == "capacity"
    refute Jason.encode!(evidence) =~ "do-not-expose"
    assert_operation_response(conn)

    assert json_response(get(build_conn(), "/api/v1/results/#{stream.id}/evidence?page=2"), 200)[
             "data"
           ] == []

    assert json_response(
             get(build_conn(), "/api/v1/results/#{stream.id}/evidence/#{report["id"]}?page=2"),
             400
           )

    other =
      Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000002")

    assert json_response(
             get(build_conn(), "/api/v1/results/#{other.id}/evidence/#{report["id"]}"),
             404
           )
  end

  test "accepted report envelopes preserve per-report admission and normalize bad identities" do
    connect()
    good = measurement("CRIT")

    bad =
      for id <- [nil, 7, %{"private" => "value"}, "malformed", "0123456789abcdef"],
          do: %{"id" => id}

    body =
      control()
      |> Map.take(~w(version installation_id session_id))
      |> Map.put("reports", [good | bad])

    conn = post_json("/api/v1/runner/observations", body)
    receipt = json_response(conn, 200)
    assert hd(receipt["dispositions"])["disposition"] == "current"
    assert Enum.map(tl(receipt["dispositions"]), & &1["id"]) == [nil, nil, nil, nil, nil]
    assert Enum.all?(tl(receipt["dispositions"]), &(&1["disposition"] == "rejected"))
    assert_operation_response(conn)
    replay = post_json("/api/v1/runner/observations", Map.put(body, "reports", [good]))
    assert hd(json_response(replay, 200)["dispositions"])["disposition"] == "duplicate"
    assert Repo.aggregate(Mondek.Observation, :count) == 1
  end

  test "errors before the controller use the common JSON shape" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/runner/control", "{")

    assert json_response(conn, 400)["error"]["code"] == "http_400"

    conn =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> post("/api/v1/runner/control", "bad")

    assert json_response(conn, 415)["error"]["code"] == "unsupported_media_type"
  end

  test "generated read client preserves large numeric evidence over real HTTP" do
    connect()
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @assignment)
    values = [1.0e24, Integer.pow(10, 24) + 1, Integer.pow(10, 4096) - 1]

    ids =
      for {value, sequence} <- Enum.with_index(values, 1) do
        report =
          measurement("CRIT")
          |> Map.put("sequence", sequence)
          |> put_in(["results", Access.at(0), "value"], value)

        assert disposition(ingest(report)) == "current"
        report["id"]
      end

    server = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    spec =
      MondekWeb.API.ApiSpec.spec()
      |> OpenApiSpex.OpenApi.to_map(vendor_extensions: false)
      |> Jason.encode!()

    directory = Path.join(System.tmp_dir!(), "mondek-api-client-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.write!(Path.join(directory, "openapi.json"), spec)

    {output, status} =
      System.cmd(
        "python3",
        [
          Path.expand("../tests/api_client.py"),
          Path.join(directory, "openapi.json"),
          Path.join(directory, "client.py")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    script = """
    import sys
    sys.path.insert(0, sys.argv[1])
    from client import Client
    client = Client(sys.argv[2])
    values = [client.getResultObservation(id=sys.argv[3], observation_id=id)['data']['result']['value'] for id in sys.argv[4:]]
    assert values == [10**24, 10**24 + 1, 10**4096 - 1], [type(value).__name__ for value in values]
    assert all(isinstance(value, int) for value in values)
    assert client.listResults(page=2)['data'] == []
    print('Generated read client and exact integer evidence passed')
    """

    {output, status} =
      System.cmd(
        "python3",
        ["-c", script, directory, "http://127.0.0.1:#{port}", stream.id | ids],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "declared source and page-size filters change the HTTP selection" do
    other = "10000000-0000-4000-8000-000000000002"

    Repo.update_all(from(a in Assignment, where: a.id == ^other),
      set: [source_id: "other-source"]
    )

    conn = get(build_conn(), "/api/v1/assignments?source_id=other-source")
    assert [%{"id" => ^other}] = json_response(conn, 200)["data"]
    assert_operation_response(conn)
    assert json_response(conn, 200)["meta"]["configuration_summary"]["scope_total"] == 1
    refute Map.has_key?(hd(json_response(conn, 200)["data"]), "params")
    conn = get(build_conn(), "/api/v1/configuration/assignments?source_id=other-source")
    assert [%{"id" => ^other, "params" => params}] = json_response(conn, 200)["data"]
    assert is_map(params)
    assert_operation_response(conn)
    conn = get(build_conn(), "/api/v1/results?page_size=1")
    assert length(json_response(conn, 200)["data"]) == 1
    assert json_response(conn, 200)["meta"]["page_size"] == 1
    assert json_response(get(build_conn(), "/api/v1/results?target_id=ignored"), 400)
  end

  @tag empty_source_fixture: true
  test "configuration identity initializes before HTTP and revision reads do not write" do
    assert {:error, :unavailable} = Mondek.ConfigurationRepository.read_state()
    assert :ignore = Mondek.ConfigurationRepositoryBootstrap.start_link([])
    before = Mondek.ConfigurationRepository.history()
    conn = get(build_conn(), "/api/v1/configuration/revision")
    assert json_response(conn, 200)["data"]["head"] == hd(before).head
    assert Mondek.ConfigurationRepository.history() == before
    assert_operation_response(conn)
  end

  test "a canceled read rolls back and returns a bounded unavailable response" do
    conn =
      MondekWeb.API.Read.run(build_conn(), fn _ ->
        Repo.query!("SET LOCAL statement_timeout = '1ms'")
        Repo.query!("SELECT pg_sleep(0.05)")
      end)

    assert json_response(conn, 503)["error"]["code"] == "unavailable"
    assert Repo.aggregate(Assignment, :count) == 3
  end

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
end
