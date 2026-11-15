# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.SystemController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:health), do: MondekWeb.API.Contract.operation(:health)
  def open_api_operation(:snapshot), do: MondekWeb.API.Contract.operation(:snapshot)
  def open_api_operation(:overview), do: MondekWeb.API.Contract.operation(:overview)

  def health(conn, _), do: reply(conn, %{status: "ok"})
  def snapshot(conn, _), do: MondekWeb.API.Read.run(conn, &Monitoring.snapshot/1)
  def overview(conn, _), do: MondekWeb.API.Read.run(conn, &Monitoring.overview/1)
end
