# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.AssignmentsController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:configuration), do: MondekWeb.API.Contract.operation(:configuration)
  def open_api_operation(:assignment), do: MondekWeb.API.Contract.operation(:assignment)

  def open_api_operation(:assignment_inspection),
    do: MondekWeb.API.Contract.operation(:assignment_inspection)

  def open_api_operation(:save), do: MondekWeb.API.Contract.operation(:save)

  def open_api_operation(:assignment_configurations),
    do: MondekWeb.API.Contract.operation(:assignment_configurations)

  def assignment_configurations(conn, params),
    do:
      MondekWeb.API.Read.run(
        conn,
        &Monitoring.list_checks(Mondek.Investigation.http_filters(params), &1)
      )

  def configuration(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Investigation.assignments(params, &1))

  def assignment(conn, %{"id" => id} = params),
    do:
      MondekWeb.API.Read.run(
        conn,
        &Mondek.Investigation.assignment(Map.put(params, "assignment_id", id), &1)
      )

  def assignment_inspection(conn, %{"id" => id}),
    do: MondekWeb.API.Read.run(conn, &Monitoring.assignment_detail(id, &1))

  def save(conn, %{"id" => id} = p),
    do: respond(conn, Monitoring.save_assignment(id, integer(p["revision"]), p["params"]))
end
