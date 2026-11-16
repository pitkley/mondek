# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.CorrelationController do
  use MondekWeb.API.Controller
  def open_api_operation(action), do: MondekWeb.API.Contract.operation(action)

  def correlation_candidates(conn, params),
    do: MondekWeb.API.Read.run(conn, &Mondek.Correlations.candidates(params, &1))

  def correlation_cases(conn, params),
    do: MondekWeb.API.Read.run(conn, fn _ -> Mondek.Correlations.list(params) end)

  def correlation_case(conn, %{"id" => id} = params),
    do: MondekWeb.API.Read.run(conn, fn _ -> Mondek.Correlations.detail(id, params) end)

  def correlation_preview(conn, params), do: respond(conn, Mondek.Correlations.preview(params))

  def correlation_apply(conn, %{"review_token" => token}),
    do: respond(conn, Mondek.Correlations.apply(token))
end
