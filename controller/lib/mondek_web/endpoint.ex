# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mondek

  @session_options [
    store: :cookie,
    key: "_mondek",
    signing_salt: "local-slice",
    same_site: "Lax"
  ]
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static, at: "/", from: :mondek, gzip: false, only: ~w(assets favicon.ico)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {MondekWeb.BodyReader, :read_body, []},
    length: 4_194_304

  plug Plug.MethodOverride
  plug Plug.Head
  plug MondekWeb.RuntimeSession, @session_options
  plug MondekWeb.Router
end
