# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.RunnersController do
  use MondekWeb.API.Controller
  def open_api_operation(:runners), do: MondekWeb.API.Contract.operation(:runners)
  def open_api_operation(:runner), do: MondekWeb.API.Contract.operation(:runner)

  def runners(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.RunnerFleet.list(params, &1))

  def runner(conn, %{"id" => id}) do
    MondekWeb.API.Read.run(conn, &Mondek.RunnerFleet.detail(id, &1))
  end
end
