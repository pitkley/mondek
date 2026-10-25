# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.AcknowledgementsAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint

  test "acknowledgement API accepts reviewed modes, rejects stale/conflicting edits and rejects unreviewed seconds" do
    connect()
    ingest(measurement("CRIT"))
    row = Repo.one!(Incident)
    path = "/api/v1/incidents/#{row.id}/acknowledge"

    request = %{
      "mode" => "until_incident_ends",
      "revision" => 0,
      "attention_revision" => row.attention_revision,
      "note" => "Investigating"
    }

    assert json_response(post_json(path, request), 200)["acknowledgement_mode"] ==
             "until_incident_ends"

    assert json_response(post_json(path, request), 409)
    assert json_response(post_json(path, Map.delete(request, "revision")), 422)
    assert json_response(post_json(path, Map.put(request, "seconds", 60)), 422)

    for extra <- [%{"expires_at" => "2030-01-01T00:00:00Z"}, %{"revision" => 0}] do
      assert json_response(post_json(path, Map.merge(%{"seconds" => 60}, extra)), 422)
    end

    assert Repo.get!(Incident, row.id).acknowledgement_revision == 1

    assert json_response(post_json(path, %{"seconds" => 60, "note" => "Unreviewed"}), 422)
    assert Repo.get!(Incident, row.id).acknowledgement_revision == 1

    assert json_response(
             post_json(path, %{
               "mode" => "duration",
               "revision" => 1,
               "attention_revision" => row.attention_revision,
               "seconds" => 30 * 86_400,
               "note" => "Long duration"
             }),
             200
           )["acknowledgement_mode"] == "until"

    current = Repo.get!(Incident, row.id)

    cancel = %{
      "mode" => "end",
      "revision" => current.acknowledgement_revision,
      "attention_revision" => current.attention_revision,
      "note" => "Done"
    }

    assert json_response(post_json(path, cancel), 200)["acknowledgement_mode"] == nil
    assert json_response(post_json("/api/v1/incidents/invalid/acknowledge", request), 422)
  end

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
end
