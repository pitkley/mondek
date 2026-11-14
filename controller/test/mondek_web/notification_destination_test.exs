# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationDestinationTest do
  use ExUnit.Case, async: true
  alias Mondek.{NotificationDelivery, WebhookNotification}
  alias MondekWeb.{BrowserNavigation, Router}

  test "generated health and monitoring-loss destinations reach dedicated operator pages" do
    for kind <- ["health", "monitoring_loss"] do
      id = Ecto.UUID.generate()
      route_kind = if kind == "health", do: "health", else: "loss"
      path = "/incidents/#{route_kind}/#{id}/full"

      payload = %{
        "incident_type" => kind,
        "incident_id" => id,
        "monitoring_incident_id" => if(kind == "monitoring_loss", do: id),
        "kind" => "firing",
        "health" => "CRIT",
        "created_at" => "2026-01-01T00:00:00Z",
        "email" => %{
          "from" => "mondek@example.invalid",
          "public_url" => "https://mondek.example.invalid",
          "label" => "Example condition"
        }
      }

      document =
        WebhookNotification.document(
          payload,
          "Example",
          "Example finding",
          nil,
          "https://mondek.example.invalid"
        )

      assert document["incident"]["url"] == "https://mondek.example.invalid" <> path

      message =
        NotificationDelivery.message(%{
          id: Ecto.UUID.generate(),
          payload: payload,
          destination: "mailto:operator@example.invalid",
          inserted_at: ~U[2026-01-01 00:00:00Z]
        })

      [_, body] = String.split(message, "\r\n\r\n", parts: 2)
      assert Base.decode64!(body, ignore: :whitespace) =~ "https://mondek.example.invalid" <> path
      assert BrowserNavigation.return_path(path) == path
      assert %{plug: Phoenix.LiveView.Plug} = Phoenix.Router.route_info(Router, "GET", path, nil)
    end
  end
end
