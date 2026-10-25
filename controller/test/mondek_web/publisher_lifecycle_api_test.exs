# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PublisherLifecycleAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  alias Mondek.{PublisherLifecycle, SourceInventory}
  alias Mondek.CoverageFixtures, as: F
  @endpoint MondekWeb.Endpoint

  test "reviewed API lifecycle keeps receipts, returns precise fences and authorizes a new restoration epoch" do
    p = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(p, Monitoring.now())
    id = Repo.get_by!(SourceInventory, runner_id: p["installation_id"]).id
    proposal = %{"publisher_id" => id, "action" => "retire", "reason" => "Decommission observer"}
    review = request("/api/v1/publishers/preview", %{"proposal" => proposal}, 200)
    assert review["can_apply"]
    assert review["summary"]["assignments"] == 1
    apply = %{"proposal" => proposal, "review_token" => review["review_token"]}
    result = request("/api/v1/publishers/apply", apply, 200)
    assert result["publisher"]["lifecycle_status"] == "retired"

    assert request("/api/v1/inventory", Map.put(p, "inventory_revision", 50), 409)["code"] ==
             "publisher_retired"

    assert (build_conn()
            |> get("/api/v1/publishers/#{id}")
            |> json_response(200))["history"]["total"] == 1

    event =
      build_conn()
      |> get("/api/v1/publishers/#{id}/events/#{result["receipt"]["id"]}")
      |> json_response(200)

    assert event["total"] == 1 and length(event["items"]) == 1
    assert build_conn() |> get("/api/v1/publishers/#{id}/events/not-an-id") |> json_response(404)

    restore = %{proposal | "action" => "restore", "reason" => "Reinstall observer"}
    review = request("/api/v1/publishers/preview", %{"proposal" => restore}, 200)

    waiting =
      request(
        "/api/v1/publishers/apply",
        %{"proposal" => restore, "review_token" => review["review_token"]},
        200
      )

    epoch = waiting["publisher"]["lifecycle_revision"]

    for inventory <- [
          p,
          Map.put(p, "inventory_revision", 50),
          Map.merge(p, %{"inventory_revision" => 50, "restoration_revision" => epoch - 1})
        ] do
      assert request("/api/v1/inventory", inventory, 409)["code"] ==
               "publication_refresh_required"
    end

    for marker <- [nil, "3", 0, -1, 9_223_372_036_854_775_807] do
      assert request("/api/v1/inventory", Map.put(p, "restoration_revision", marker), 422)[
               "error"
             ]
    end

    assert request(
             "/api/v1/inventory",
             Map.merge(p, %{"inventory_revision" => 51, "restoration_revision" => epoch}),
             200
           )["accepted_checks"] == 1

    assert request("/api/v1/publishers/apply", apply, 200)["receipt"] == result["receipt"]
  end

  test "successor choices are source-scoped, searchable and exclude retired publications" do
    p = F.publication([F.candidate(F.check())])
    peer = F.publication([F.candidate(F.check())], %{"runner_label" => "Spare observer"})
    unrelated = F.publication([], %{"source_id" => "unrelated"})

    for publication <- [p, peer, unrelated],
        do: assert({:ok, _} = Monitoring.inventory(publication, Monitoring.now()))

    id = Repo.get_by!(SourceInventory, runner_id: p["installation_id"]).id
    peer_id = Repo.get_by!(SourceInventory, runner_id: peer["installation_id"]).id

    choices =
      build_conn()
      |> get("/api/v1/publishers/#{id}/successors?search=Spare")
      |> json_response(200)

    assert Enum.map(choices["items"], & &1["id"]) == [peer_id]

    proposal = %{
      "publisher_id" => id,
      "successor_id" => peer_id,
      "action" => "replace",
      "reason" => "Switch observers"
    }

    blocked = request("/api/v1/publishers/preview", %{"proposal" => proposal}, 200)
    refute blocked["can_apply"]

    assert request(
             "/api/v1/publishers/apply",
             %{"proposal" => proposal, "review_token" => blocked["review_token"]},
             422
           )["error"]

    retire = %{"publisher_id" => peer_id, "action" => "retire", "reason" => "Remove spare"}
    assert {:ok, review} = PublisherLifecycle.preview(retire)
    assert {:ok, _} = PublisherLifecycle.apply(review["review_token"], retire)

    assert (build_conn()
            |> get("/api/v1/publishers/#{id}/successors")
            |> json_response(200))["total"] == 0

    assert request(
             "/api/v1/publishers/preview",
             %{"proposal" => Map.put(proposal, "publisher_id", "invalid")},
             422
           )["error"]
  end

  test "saved replacement evidence API returns one original report only through its exact decision reference" do
    now = Monitoring.now()
    p = F.publication([F.candidate(F.check())])
    peer = F.publication([F.candidate(F.check())])
    for publication <- [p, peer], do: assert({:ok, _} = Monitoring.inventory(publication, now))
    assert {:ok, _} = F.activate(peer, now)
    assert disposition(F.sample(peer, "OK", 1, now)) == "current"
    id = Repo.get_by!(SourceInventory, runner_id: p["installation_id"]).id
    peer_id = Repo.get_by!(SourceInventory, runner_id: peer["installation_id"]).id

    proposal = %{
      "publisher_id" => id,
      "successor_id" => peer_id,
      "action" => "replace",
      "reason" => "Reviewed fresh replacement"
    }

    review = request("/api/v1/publishers/preview", %{"proposal" => proposal}, 200)

    result =
      request(
        "/api/v1/publishers/apply",
        %{"proposal" => proposal, "review_token" => review["review_token"]},
        200
      )

    observation = hd(review["items"])["successor_observation_id"]
    event = result["receipt"]["id"]
    path = "/api/v1/publishers/#{id}/events/#{event}/evidence/#{observation}"
    proof = build_conn() |> get(path) |> json_response(200)
    assert proof["observation"]["id"] == observation
    assert proof["observation"]["payload"]["installation_id"] == peer["installation_id"]
    assert proof["referenced_result_keys"] == ["health"]
    assert proof["configuration"]["generation"] == 1

    for invalid <- [
          "/api/v1/publishers/#{peer_id}/events/#{event}/evidence/#{observation}",
          path <> "bad",
          "/api/v1/publishers/#{id}/events/#{event}/evidence/#{Ecto.UUID.generate()}"
        ] do
      assert build_conn() |> get(invalid) |> json_response(404)
    end
  end

  defp request(path, body, status),
    do:
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(path, body)
      |> json_response(status)
end
