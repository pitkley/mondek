# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CorrelationHintAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  test "runner HTTP inventory and control preserve both hint selectors in their declared order" do
    publication = F.publication([F.candidate(F.check())])

    first = %{
      "dimension" => "network",
      "depends_on" => %{"type" => "condition", "namespace" => "network", "key" => "uplink"},
      "window_seconds" => 120
    }

    second = %{
      "dimension" => "database",
      "depends_on" => %{
        "type" => "target",
        "source_id" => "db",
        "kind" => "service",
        "key" => "db"
      },
      "window_seconds" => 60
    }

    publication =
      put_in(
        publication,
        ["checks", Access.at(0), "outputs", Access.at(0), "correlation_hints"],
        [
          first,
          second
        ]
      )

    assert request("/api/v1/runner/inventory", publication, 200)["accepted_checks"] == 1

    payload = control(Map.take(publication, ~w(installation_id session_id boot)))

    assert [%{"outputs" => [%{"correlation_hints" => [^first, ^second]}]}] =
             request("/api/v1/runner/control", payload, 200)["assignments"]

    malformed =
      publication
      |> Map.put("inventory_revision", 2)
      |> put_in(
        [
          "checks",
          Access.at(0),
          "outputs",
          Access.at(0),
          "correlation_hints",
          Access.at(0),
          "window_seconds"
        ],
        120.0
      )

    assert request("/api/v1/runner/inventory", malformed, 422)["error"]

    assert [%{"outputs" => [%{"correlation_hints" => [^first, ^second]}]}] =
             request("/api/v1/runner/control", payload, 200)["assignments"]
  end

  defp request(path, payload, status) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
    |> json_response(status)
  end
end
