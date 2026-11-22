# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CorrelationAutomationPolicyAPITest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias Mondek.CorrelationAutomationPolicy

  @endpoint MondekWeb.Endpoint
  @rules "/api/v1/incidents/correlation/rules"

  test "operator opt-in is exact, revision checked and visible on the wire" do
    id = Ecto.UUID.generate()

    hint = %{
      "dimension" => "network",
      "window_seconds" => 120,
      "depends_on" => %{"type" => "condition", "namespace" => "network", "key" => "uplink"}
    }

    scope = %{
      "source_id" => "services",
      "check_id" => "app",
      "output_key" => "custom health check",
      "hint" => hint
    }

    first =
      Map.merge(scope, %{
        "revision" => 0,
        "enabled" => true,
        "reason" => "Approve network grouping"
      })

    refute CorrelationAutomationPolicy.enabled?()
    assert %{"id" => ^id, "revision" => 1} = put_rule(id, first, 200)

    assert CorrelationAutomationPolicy.approved_rules([scope]) == %{
             scope => %{id: id, revision: 1}
           }

    assert CorrelationAutomationPolicy.approved_rules([
             put_in(scope, ["hint", "window_seconds"], 121)
           ]) == %{}

    assert (build_conn() |> get(@rules) |> json_response(200))["data"] == [
             hd(CorrelationAutomationPolicy.rules())
           ]

    assert put_rule(id, first, 409)["error"]["code"] == "review_changed"

    disabled = %{first | "enabled" => false, "revision" => 1, "reason" => "Revoke grouping"}
    assert %{"id" => ^id, "revision" => 2, "enabled" => false} = put_rule(id, disabled, 200)
    assert CorrelationAutomationPolicy.approved_rules([scope]) == %{}
  end

  test "reviewed keep-standalone and re-enable retain delivery work and reject stale tokens" do
    connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"
    incident = Repo.one!(Incident)
    original = Repo.all(Occurrence)
    subject = %{"type" => "individual", "id" => incident.id}

    keep = %{
      "action" => "keep_standalone",
      "subject" => subject,
      "reason" => "Separate operator investigation",
      "request_id" => Ecto.UUID.generate()
    }

    review = command("preview", keep, 200)
    earlier = command("preview", Map.put(keep, "request_id", Ecto.UUID.generate()), 200)
    reviewed = %{"review_token" => review["review_token"]}

    assert %{"active" => true, "revision" => 1, "replayed" => false} =
             command("apply", reviewed, 200)

    assert %{"active" => true, "revision" => 1, "replayed" => true} =
             command("apply", reviewed, 200)

    assert command("apply", %{"review_token" => earlier["review_token"]}, 409)["error"]["code"] ==
             "review_changed"

    allow = %{keep | "action" => "allow_grouping", "request_id" => Ecto.UUID.generate()}
    reenable = command("preview", allow, 200)

    assert %{"active" => false, "revision" => 2} =
             command("apply", %{"review_token" => reenable["review_token"]}, 200)

    assert Repo.all(Occurrence) == original

    second_keep = %{keep | "request_id" => Ecto.UUID.generate()}
    review = command("preview", second_keep, 200)
    assert command("apply", %{"review_token" => review["review_token"]}, 200)["active"]
    assert disposition(ingest(measurement("OK", 2), DateTime.add(at(), 1))) == "current"

    assert %{"active" => false, "revision" => 3, "reason" => "Separate operator investigation"} =
             CorrelationAutomationPolicy.override(subject)
  end

  defp put_rule(id, input, status) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put(@rules <> "/" <> id, Jason.encode!(input))
    |> json_response(status)
  end

  defp command(action, input, status) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/incidents/correlation/overrides/" <> action, Jason.encode!(input))
    |> json_response(status)
  end
end
