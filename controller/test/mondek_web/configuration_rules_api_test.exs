# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationRulesAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint

  test "HTTP rule reviews bind exact values and expose saved provenance" do
    assignment = publish()
    proposal = request(:get, "/configuration/rules/seed/#{assignment.id}", nil, 200)

    proposal =
      Map.merge(proposal, %{"name" => "Production volumes", "params" => %{"limit" => 40}})

    preview = request(:post, "/configuration/rules/preview", %{"proposal" => proposal}, 200)
    assert preview["counts"]["matched"] == 1
    assert is_binary(preview["review_token"])

    altered = put_in(proposal, ["params", "limit"], 30)

    assert %{"code" => "review_changed"} =
             request(
               :post,
               "/configuration/rules/apply",
               %{
                 "proposal" => altered,
                 "review_token" => preview["review_token"]
               },
               409
             )

    saved =
      request(
        :post,
        "/configuration/rules/apply",
        %{
          "proposal" => proposal,
          "review_token" => preview["review_token"]
        },
        200
      )

    rule_id = saved["rule"]["id"]
    assert is_binary(rule_id)
    detail = request(:get, "/assignments/#{assignment.id}", nil, 200)
    assert detail["params"] == %{"limit" => 40}
    assert detail["configuration_origin"]["rule_id"] == rule_id
    assert request(:get, "/configuration/rules", nil, 200)["total"] == 1
    assert request(:get, "/configuration/rules/#{rule_id}", nil, 200)["id"] == rule_id

    exception =
      request(
        :put,
        "/assignments/#{assignment.id}",
        %{
          "revision" => detail["revision"],
          "params" => %{"limit" => 70}
        },
        200
      )

    reset =
      request(
        :post,
        "/assignments/#{assignment.id}/exception/preview",
        %{
          "revision" => exception["revision"]
        },
        200
      )

    request(
      :post,
      "/configuration/exception/reset",
      %{"review_token" => reset["review_token"]},
      200
    )

    restored = request(:get, "/assignments/#{assignment.id}", nil, 200)
    assert restored["params"] == %{"limit" => 40}
    assert restored["instance_exception"] == nil
  end

  test "rule endpoints reject malformed identifiers and writes without JSON" do
    request(:get, "/configuration/rules/not-a-uuid", nil, 404)
    request(:get, "/configuration/rules/seed/not-a-check", nil, 404)
    request(:post, "/configuration/rules/preview", %{"proposal" => nil}, 422)

    request(
      :post,
      "/configuration/rules/apply",
      %{"proposal" => %{}, "review_token" => "bogus"},
      422
    )

    conn = post(build_conn(), "/api/v1/configuration/rules/preview", %{"proposal" => %{}})
    assert json_response(conn, 415)["error"] =~ "application/json"
  end

  defp request(method, path, body, status) do
    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn =
      dispatch(
        conn,
        @endpoint,
        method,
        "/api/v1" <> path,
        if(body, do: Jason.encode!(body), else: nil)
      )

    json_response(conn, status)
  end

  defp publish do
    check = %{
      "key" => "volume",
      "label" => "Orders volume",
      "environment" => "production",
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => "ui",
      "parameter_contract" => "volume.limit.v1",
      "parameter_schema" => %{
        "fields" => %{"limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
      },
      "params" => %{"limit" => 80},
      "interval_seconds" => 10,
      "timeout_seconds" => 2,
      "freshness_seconds" => 30,
      "outputs" => [
        %{
          "key" => "value",
          "label" => "Pending items",
          "target" => %{"key" => "volume:orders", "kind" => "volume", "label" => "Orders"}
        }
      ]
    }

    payload =
      Map.merge(control(), %{
        "runner_label" => "API volume observer",
        "source_id" => "rules-api",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => [check]
      })

    assert {:ok, _} = Monitoring.inventory(payload, at())
    Repo.get_by!(Assignment, source_id: "rules-api")
  end
end
