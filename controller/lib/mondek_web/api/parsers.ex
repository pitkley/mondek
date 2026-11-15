# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Parsers do
  @moduledoc false
  def init(options), do: Plug.Parsers.init(options)

  def call(conn, options) do
    Plug.Parsers.call(conn, options)
  rescue
    error in [
      Plug.Parsers.ParseError,
      Plug.Parsers.RequestTooLargeError,
      Plug.Parsers.UnsupportedMediaTypeError
    ] ->
      if String.starts_with?(conn.request_path, "/api/v1/") do
        status = Plug.Exception.status(error)

        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> MondekWeb.API.Response.error(
          status,
          "http_#{status}",
          Plug.Conn.Status.reason_phrase(status)
        )
        |> Plug.Conn.halt()
      else
        reraise error, __STACKTRACE__
      end
  end
end
