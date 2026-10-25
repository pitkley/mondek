# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint

  test "unreviewed duration maintenance route is absent" do
    assert response(
             post_json("/api/v1/assignments/10000000-0000-4000-8000-000000000002/maintenance", %{
               "seconds" => 60,
               "reason" => "Unreviewed"
             }),
             404
           )

    assert Repo.aggregate(Mondek.MaintenanceWindow, :count) == 0
  end

  test "HTTP maintenance lifecycle is reviewed, revision checked and keeps scoped history" do
    seed =
      json_response(
        get(build_conn(), "/api/v1/maintenance/seed/10000000-0000-4000-8000-000000000001"),
        200
      )

    p = Map.put(seed["proposal"], "reason", "Local API maintenance")

    assert json_response(
             post_json("/api/v1/maintenance/apply", %{
               "proposal" => p,
               "review_token" => "invalid"
             }),
             422
           )

    preview = json_response(post_json("/api/v1/maintenance/preview", %{"proposal" => p}), 200)

    second =
      json_response(
        post_json("/api/v1/maintenance/preview", %{
          "proposal" => p,
          "page" => 2,
          "review_token" => preview["review_token"]
        }),
        200
      )

    assert second["starts_at"] == preview["starts_at"]

    assert json_response(
             post_json("/api/v1/maintenance/apply", %{
               "proposal" => Map.put(p, "reason", "Unreviewed"),
               "review_token" => preview["review_token"]
             }),
             409
           )

    window =
      json_response(
        post_json("/api/v1/maintenance/apply", %{
          "proposal" => p,
          "review_token" => preview["review_token"]
        }),
        200
      )

    assert window["status"] == "active"

    assert json_response(
             post_json("/api/v1/maintenance/apply", %{
               "proposal" => p,
               "review_token" => preview["review_token"]
             }),
             409
           )

    detail = json_response(get(build_conn(), "/api/v1/maintenance/" <> window["id"]), 200)
    edit = Map.put(detail["proposal"], "reason", "Amended reason")
    review = json_response(post_json("/api/v1/maintenance/preview", %{"proposal" => edit}), 200)

    updated =
      json_response(
        post_json("/api/v1/maintenance/apply", %{
          "proposal" => edit,
          "review_token" => review["review_token"]
        }),
        200
      )

    assert updated["revision"] == 2
    assert updated["starts_at"] == window["starts_at"]
    cancel_path = "/api/v1/maintenance/" <> window["id"] <> "/cancel"
    assert json_response(post_json(cancel_path, %{"revision" => 1, "reason" => "Outdated"}), 409)
    assert json_response(post_json(cancel_path, %{"revision" => 2, "reason" => ""}), 422)

    assert json_response(post_json(cancel_path, %{"revision" => 2, "reason" => "Finished"}), 200)[
             "status"
           ] == "cancelled"

    history =
      json_response(
        get(
          build_conn(),
          "/api/v1/maintenance?status=history&assignment_id=10000000-0000-4000-8000-000000000001"
        ),
        200
      )

    assert history["total"] == 1
    assert hd(history["windows"])["id"] == window["id"]

    assert json_response(
             post_json("/api/v1/maintenance/apply", %{
               "proposal" => p,
               "review_token" => preview["review_token"]
             }),
             409
           )

    assert json_response(get(build_conn(), "/api/v1/maintenance/invalid"), 404)
    assert json_response(post_json("/api/v1/maintenance/preview", %{"proposal" => %{}}), 422)
  end

  test "HTTP selection preview deduplicates checks and saves and cancels one reviewed window" do
    seed =
      json_response(
        get(build_conn(), "/api/v1/maintenance/seed/10000000-0000-4000-8000-000000000001"),
        200
      )

    filesystem = %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000001"}
    http = %{"scope" => "check", "assignment_id" => "10000000-0000-4000-8000-000000000002"}

    p =
      seed["proposal"]
      |> Map.merge(%{
        "scope" => "selection",
        "assignment_id" => nil,
        "selections" => [http, filesystem, http],
        "reason" => "Both checks during deployment"
      })

    review = json_response(post_json("/api/v1/maintenance/preview", %{"proposal" => p}), 200)
    assert review["counts"]["matched_checks"] == 2
    assert length(review["selection_summary"]) == 2
    assert Enum.all?(review["selection_summary"], &(&1["matched_results"] == 1))

    saved =
      json_response(
        post_json("/api/v1/maintenance/apply", %{
          "proposal" => p,
          "review_token" => review["review_token"]
        }),
        200
      )

    assert saved["scope"] == "selection"
    assert length(saved["selections"]) == 2

    assert json_response(
             get(
               build_conn(),
               "/api/v1/maintenance?assignment_id=10000000-0000-4000-8000-000000000002"
             ),
             200
           )[
             "total"
           ] == 1

    detail = json_response(get(build_conn(), "/api/v1/maintenance/" <> saved["id"]), 200)
    assert detail["match_count"] == 2
    assert length(detail["history"]) == 1

    invalid =
      Map.put(p, "selections", [
        %{
          "scope" => "target",
          "source_id" => "bad\u0000source",
          "target_kind" => "host",
          "target_key" => "one"
        }
      ])

    assert json_response(post_json("/api/v1/maintenance/preview", %{"proposal" => invalid}), 422)

    cancelled =
      json_response(
        post_json("/api/v1/maintenance/" <> saved["id"] <> "/cancel", %{
          "revision" => 1,
          "reason" => "Deployment completed"
        }),
        200
      )

    assert cancelled["status"] == "cancelled"

    assert json_response(
             get(
               build_conn(),
               "/api/v1/maintenance?status=history&assignment_id=10000000-0000-4000-8000-000000000001"
             ),
             200
           )["total"] == 1
  end

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
end
