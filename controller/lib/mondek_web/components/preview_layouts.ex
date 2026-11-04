# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewLayouts do
  use MondekWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title suffix=" · Mondek">Overview preview</.live_title>
        <link rel="stylesheet" href={MondekWeb.Endpoint.static_path("/assets/preview.css")} />
        <script defer type="module" src={MondekWeb.Endpoint.static_path("/assets/preview.js")}>
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
