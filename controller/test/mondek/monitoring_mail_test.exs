# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MonitoringMailTest do
  use ExUnit.Case, async: false
  alias Mondek.NotificationDelivery

  defp render(kind, reason \\ nil) do
    at = ~U[2009-09-17 12:00:00.000000Z]
    id = Ecto.UUID.generate()
    incident = Ecto.UUID.generate()

    payload = %{
      "incident_type" => "monitoring_loss",
      "monitoring_incident_id" => incident,
      "kind" => kind,
      "closure_reason" => reason,
      "member_count" => 1,
      "member_snapshot" => [
        %{
          "label" => "Disk usage",
          "knowledge" => "stale",
          "environment" => "Production",
          "target" => %{"label" => "Node A"}
        }
      ],
      "created_at" => DateTime.to_iso8601(at),
      "email" => %{
        "from" => "mondek@example.invalid",
        "public_url" => "https://mondek.example.invalid",
        "label" => "Node observer",
        "summary" => "Monitoring stopped producing current measurements"
      }
    }

    raw =
      NotificationDelivery.message(%{
        id: id,
        payload: payload,
        destination: "mailto:operator@example.invalid",
        inserted_at: at
      })

    [headers, body] = String.split(raw, "\r\n\r\n", parts: 2)

    subject =
      Regex.scan(~r/=\?UTF-8\?B\?([^?]+)\?=/, headers)
      |> Enum.map_join(fn [_, encoded] -> Base.decode64!(encoded) end)

    {subject, Base.decode64!(body, ignore: :whitespace), incident, raw, payload}
  end

  test "loss mail has source scope and useful members without inventing unknown health severity" do
    {subject, body, id, _, _} = render("firing")
    assert subject == "[Mondek] MONITORING LOST: Node observer"
    assert body =~ "Disk usage: Overdue · Node A · Production"
    assert body =~ "/monitoring-incidents/#{id}"
    assert body =~ "not a measured target-health failure"
    refute body =~ "Incident severity"
    refute body =~ "Recovery measurement"
  end

  test "restoration and administrative closure are different and neither invents recovery OK" do
    {subject, body, _, _, _} = render("resolved", "monitoring_restored")
    assert subject == "[Mondek] MONITORING RESTORED: Node observer"
    assert body =~ "Fresh measurements restored monitoring"
    refute body =~ "Recovery measurement: OK"
    {subject, body, _, _, _} = render("resolved", "scope_withdrawn")
    assert subject == "[Mondek] CLOSED: Node observer"
    assert body =~ "administrative closure"
    refute subject =~ "RESTORED"
  end

  test "a frozen monitoring notification keeps its original bytes on retry" do
    {_, _, _, raw, payload} = render("firing")
    frozen = put_in(payload, ["email", "message"], raw)
    assert NotificationDelivery.message(%{payload: Map.put(frozen, "kind", "resolved")}) == raw
  end
end
