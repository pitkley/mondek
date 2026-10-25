# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BodyReader do
  def read_body(conn, options) do
    limit =
      case conn.request_path do
        "/api/v1/inventory" ->
          4_194_304

        path
        when path in [
               "/api/v1/maintenance/preview",
               "/api/v1/maintenance/apply",
               "/api/v1/maintenance-series/preview",
               "/api/v1/maintenance-series/apply"
             ] ->
          2_097_152

        _ ->
          262_144
      end

    Plug.Conn.read_body(conn, Keyword.put(options, :length, limit))
  end
end
