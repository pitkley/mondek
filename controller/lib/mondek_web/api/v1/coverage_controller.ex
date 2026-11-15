# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.CoverageController do
  use MondekWeb.API.Controller
  def open_api_operation(:coverage), do: MondekWeb.API.Contract.operation(:coverage)

  def open_api_operation(:coverage_publishers),
    do: MondekWeb.API.Contract.operation(:coverage_publishers)

  def open_api_operation(:coverage_diagnostics),
    do: MondekWeb.API.Contract.operation(:coverage_diagnostics)

  def open_api_operation(:coverage_observers),
    do: MondekWeb.API.Contract.operation(:coverage_observers)

  def open_api_operation(:coverage_scope), do: MondekWeb.API.Contract.operation(:coverage_scope)

  def coverage(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Coverage.scopes(params, &1))

  def coverage_publishers(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Coverage.publishers(params, &1))

  def coverage_diagnostics(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Coverage.diagnostics(params, &1))

  def coverage_observers(conn, %{"id" => id} = params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Coverage.observers(id, params, &1))

  def coverage_scope(conn, %{"id" => id}) do
    MondekWeb.API.Read.run(conn, &Mondek.Coverage.scope(id, &1))
  end
end
