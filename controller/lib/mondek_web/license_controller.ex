# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LicenseController do
  use MondekWeb, :controller

  def notices(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition", ~s(attachment; filename="THIRD_PARTY_LICENSES.md"))
    |> send_resp(200, Mondek.Licenses.third_party_notices())
  end
end
