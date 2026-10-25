# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LicensesLiveTest do
  use Mondek.DataCase, async: false
  import Plug.Conn, only: [get_resp_header: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint

  test "credits render embedded runtime notices and preserve additional attribution" do
    {:ok, view, html} = live(build_conn(), "/licenses")
    assert has_element?(view, "h1", "Licenses and credits")
    assert has_element?(view, "#credit-telemetry h3", "NOTICE")
    assert has_element?(view, "#credit-phoenix")
    refute has_element?(view, "#credit-lazy_html")
    assert html =~ "Apache License"
    assert html =~ "Copyright"
    assert has_element?(view, "a[href='/licenses/notices']")
  end

  test "plain-text download includes all controller attribution and serves embedded bytes" do
    conn = get(build_conn(), "/licenses/notices")
    assert response(conn, 200) == Mondek.Licenses.third_party_notices()
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert response(conn, 200) =~ "telemetry"
    assert response(conn, 200) =~ "NOTICE"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="THIRD_PARTY_LICENSES.md")
           ]
  end
end
