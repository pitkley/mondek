# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.MaintenanceController do
  use MondekWeb.API.Controller
  alias Mondek.MaintenanceProjects

  def open_api_operation(action)
      when action in [:maintenance_project, :maintenance_project_plan, :maintenance_project_apply],
      do: MondekWeb.API.Contract.operation(action)

  def open_api_operation(:maintenance_windows),
    do: MondekWeb.API.Contract.operation(:maintenance_windows)

  def open_api_operation(:maintenance_seed),
    do: MondekWeb.API.Contract.operation(:maintenance_seed)

  def open_api_operation(:maintenance_window),
    do: MondekWeb.API.Contract.operation(:maintenance_window)

  def open_api_operation(:maintenance_preview),
    do: MondekWeb.API.Contract.operation(:maintenance_preview)

  def open_api_operation(:maintenance_apply),
    do: MondekWeb.API.Contract.operation(:maintenance_apply)

  def open_api_operation(:maintenance_cancel),
    do: MondekWeb.API.Contract.operation(:maintenance_cancel)

  def open_api_operation(:maintenance_series),
    do: MondekWeb.API.Contract.operation(:maintenance_series)

  def open_api_operation(:maintenance_series_preview),
    do: MondekWeb.API.Contract.operation(:maintenance_series_preview)

  def open_api_operation(:maintenance_series_apply),
    do: MondekWeb.API.Contract.operation(:maintenance_series_apply)

  def open_api_operation(:maintenance_series_cancel_preview),
    do: MondekWeb.API.Contract.operation(:maintenance_series_cancel_preview)

  def open_api_operation(:maintenance_series_cancel),
    do: MondekWeb.API.Contract.operation(:maintenance_series_cancel)

  def maintenance_project(conn, %{"project" => project}),
    do: respond(conn, MaintenanceProjects.export(project))

  def maintenance_project_plan(conn, params),
    do: respond(conn, MaintenanceProjects.plan(params["manifest"], params["base_revision"]))

  def maintenance_project_apply(conn, params),
    do: respond(conn, MaintenanceProjects.apply(params["review_token"], params["manifest"]))

  def maintenance_windows(conn, p), do: reply(conn, Mondek.Maintenance.list(p))

  def maintenance_seed(conn, %{"assignment_id" => id} = p),
    do: respond(conn, Mondek.Maintenance.seed(id, p["stream_id"]))

  def maintenance_window(conn, %{"id" => id}), do: respond(conn, Mondek.Maintenance.get(id))

  def maintenance_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.Maintenance.preview(
          p["proposal"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_apply(conn, p),
    do: respond(conn, Mondek.Maintenance.apply(p["review_token"], p["proposal"]))

  def maintenance_cancel(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.Maintenance.cancel(id, integer(p["revision"]), p["reason"]))

  def maintenance_series(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.MaintenanceSchedules.get(id, p))

  def maintenance_series_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.MaintenanceSchedules.preview(
          p["proposal"],
          p["occurrence_page"] || 1,
          p["result_page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_series_apply(conn, p),
    do: respond(conn, Mondek.MaintenanceSchedules.apply(p["review_token"], p["proposal"]))

  def maintenance_series_cancel_preview(conn, %{"id" => id} = p),
    do:
      respond(
        conn,
        Mondek.MaintenanceSchedules.cancel_preview(
          id,
          integer(p["revision"]),
          p["reason"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_series_cancel(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.MaintenanceSchedules.cancel(id, p["review_token"], p["reason"]))
end
