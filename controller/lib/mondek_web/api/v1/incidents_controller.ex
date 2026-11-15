# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.IncidentsController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:incidents), do: MondekWeb.API.Contract.operation(:incidents)

  def open_api_operation(:monitoring_incidents),
    do: MondekWeb.API.Contract.operation(:monitoring_incidents)

  def open_api_operation(:monitoring_incident),
    do: MondekWeb.API.Contract.operation(:monitoring_incident)

  def open_api_operation(:incident), do: MondekWeb.API.Contract.operation(:incident)
  def open_api_operation(:acknowledge), do: MondekWeb.API.Contract.operation(:acknowledge)

  def incidents(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Investigation.health_incidents(params, &1))

  def monitoring_incidents(conn, params),
    do:
      MondekWeb.API.Read.run(conn, fn at ->
        Mondek.MonitoringLoss.list(Map.put(params, "unclamped", true), at)
      end)

  def monitoring_incident(conn, %{"id" => id} = params) do
    MondekWeb.API.Read.run(conn, fn at ->
      detail =
        Mondek.MonitoringLoss.detail(
          id,
          at,
          params
          |> Map.put("members_page", params["page"] || params["members_page"] || 1)
          |> Map.put("unclamped", true)
        )

      if detail do
        mode = if detail["status"] == "open", do: "live", else: "retained_snapshot"
        Map.update!(detail, "members", &Map.put(&1, "mode", mode))
      end
    end)
  end

  def incident(conn, %{"id" => id} = params),
    do:
      MondekWeb.API.Read.run(
        conn,
        &Mondek.Investigation.health_detail(id, Map.drop(params, ["id"]), &1)
      )

  def acknowledge(conn, %{"id" => id} = p) do
    at = Monitoring.now()

    result =
      case Monitoring.acknowledge(
             id,
             Map.drop(p, ["id", "note"]),
             p["note"] || "Acknowledged locally",
             at
           ) do
        {:ok, incident} ->
          {:ok,
           incident
           |> Mondek.Inspection.incident_identity(at)
           |> Mondek.Investigation.health_summary()}

        other ->
          other
      end

    respond(conn, result)
  end
end
