# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ErrorJSON do
  def render(template, assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    conn = assigns[:conn]

    request_id =
      if conn, do: List.first(Plug.Conn.get_resp_header(conn, "x-request-id")), else: "unknown"

    %{
      error: %{code: "http_" <> hd(String.split(template, ".")), message: message},
      request_id: request_id || "unknown"
    }
  end
end

defmodule MondekWeb.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
