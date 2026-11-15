# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.NotificationsController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:notifications), do: MondekWeb.API.Contract.operation(:notifications)
  def open_api_operation(:notification), do: MondekWeb.API.Contract.operation(:notification)

  def open_api_operation(:retry_notification),
    do: MondekWeb.API.Contract.operation(:retry_notification)

  def notifications(conn, params),
    do:
      reply(
        conn,
        Monitoring.delivery_inspection(Map.put(params, "notification_page", params["page"] || 1))
      )

  def notification(conn, %{"id" => id}) do
    case Mondek.Inspection.notification_detail(id, Monitoring.now()) do
      nil -> conn |> put_status(:not_found) |> reply(%{error: "Notification not found."})
      notification -> reply(conn, notification)
    end
  end

  def retry_notification(conn, %{"id" => id} = p),
    do: respond(conn, Monitoring.retry_notification(id, p["reason"]))
end
