# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BodyReader do
  def read_body(conn, options) do
    limit =
      case conn.request_path do
        path
        when path in [
               "/api/v1/runner/inventory",
               "/api/v1/configuration/schema-migration/preview"
             ] ->
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

    case Plug.Conn.read_body(conn, Keyword.put(options, :length, limit)) do
      {status, body, updated} when status in [:ok, :more] ->
        updated =
          if conn.request_path == "/api/v1/runner/state",
            do:
              Plug.Conn.put_private(
                updated,
                :consumer_state_body,
                (conn.private[:consumer_state_body] || "") <> body
              ),
            else: updated

        {status, body, updated}

      other ->
        other
    end
  end
end
