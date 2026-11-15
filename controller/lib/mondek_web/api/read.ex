# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Read do
  @moduledoc false
  import MondekWeb.API.Response

  def run(conn, fun) do
    at = Mondek.Monitoring.now()
    conn = Plug.Conn.assign(conn, :api_at, at)
    respond(conn, Mondek.Investigation.read(fn -> fun.(at) end))
  end
end
