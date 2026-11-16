# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConsumerStateTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  import OpenApiSpex.TestAssertions
  alias Mondek.ConsumerState
  @endpoint MondekWeb.Endpoint

  setup do
    %{request: Mondek.ConsumerStateFixtures.observer()}
  end

  test "state API returns typed receipts, selected values and bounded metadata only", %{
    request: p
  } do
    put =
      Map.merge(p, %{
        "operation" => "put",
        "value" => %{"html" => "<script>private topology</script>", "null" => nil}
      })

    conn = post_json("/api/v1/runner/state", put)
    assert_operation_response(conn)
    assert %{"status" => "stored", "entry" => entry} = json_response(conn, 200)
    conn = get(build_conn(), "/api/v1/consumer-state?source_id=state-test")
    assert_operation_response(conn)
    response = json_response(conn, 200)
    assert [%{"id" => id}] = response["data"]
    refute Map.has_key?(hd(response["data"]), "value")
    assert response["meta"]["usage"]["entries"] == 1
    conn = get(build_conn(), "/api/v1/consumer-state/#{id}")
    assert_operation_response(conn)
    assert json_response(conn, 200)["data"]["value"] == put["value"]

    conn =
      post_json(
        "/api/v1/runner/state",
        Map.merge(put, %{
          "operation" => "compare_and_set",
          "expected_version" => Ecto.UUID.generate()
        })
      )

    assert_operation_response(conn)
    assert json_response(conn, 200)["status"] == "conflict"
    conn = post_json("/api/v1/runner/state", Map.put(put, "generation", 999))
    assert json_response(conn, 409)["error"]["code"] == "state_not_authorized"
    assert_operation_response(conn)
    assert entry["value"] == put["value"]
  end

  test "raw duplicate keys, hostile depth and invalid requests cannot mutate", %{request: p} do
    raw = Jason.encode!(Map.merge(p, %{"operation" => "put", "value" => 1}))

    for invalid <- [
          String.replace(raw, "\"value\":1", "\"value\":1,\"value\":2"),
          String.replace(raw, "\"value\":1", "\"value\":{\"a\":1,\"a\":2}")
        ] do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/runner/state", invalid)

      assert json_response(conn, 400)["error"]["code"] == "invalid_state_json"
    end

    assert {:ok, %{"status" => "missing"}} = ConsumerState.exchange(p)
    assert json_response(post_json("/api/v1/runner/state", Map.put(p, "unknown", true)), 422)
    assert json_response(get(build_conn(), "/api/v1/consumer-state?unknown=1"), 400)
  end

  test "operator page shows escaped current value, source filters and unavailable selection", %{
    request: p
  } do
    assert {:ok, %{"entry" => e}} =
             ConsumerState.exchange(
               Map.merge(p, %{"operation" => "put", "value" => "<script>alert('x')</script>"})
             )

    {:ok, view, html} = live(build_conn(), "/consumer-state?source_id=state-test&id=#{e.id}")
    assert html =~ "Current JSON value"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert"
    assert has_element?(view, "#state-value")

    assert render_click(element(view, "button[phx-click=filter_open][phx-value-field=source_id]")) =~
             "state-test"

    assert {:ok, _} = ConsumerState.exchange(Map.put(p, "operation", "delete"))
    send(view.pid, :tick)
    assert render(view) =~ "Selected key is unavailable"
    refute has_element?(view, "#state-value")
  end

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))
end
