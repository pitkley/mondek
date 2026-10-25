# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RuntimeSessionTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  @options MondekWeb.RuntimeSession.init(
             store: :cookie,
             key: "_mondek",
             signing_salt: "runtime-test",
             same_site: "Lax"
           )

  setup do
    original = Application.get_env(:mondek, :deployment_mode, false)
    on_exit(fn -> Application.put_env(:mondek, :deployment_mode, original) end)
    :ok
  end

  defp session_response(conn) do
    %{conn | secret_key_base: String.duplicate("test-only-secret-", 6)}
    |> MondekWeb.RuntimeSession.call(@options)
    |> fetch_session()
    |> put_session(:test, "value")
    |> send_resp(200, "ok")
  end

  test "proxied deployment sessions are secure without trusting forwarded host or client IP" do
    Application.put_env(:mondek, :deployment_mode, true)

    conn =
      Plug.Test.conn(:get, "http://monitoring.example.test/checks")
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "untrusted.example")
      |> put_req_header("x-forwarded-for", "192.0.2.100")
      |> session_response()

    assert conn.scheme == :https
    assert conn.host == "monitoring.example.test"
    assert conn.remote_ip == {127, 0, 0, 1}
    assert conn.resp_cookies["_mondek"][:secure] == true
    assert conn.resp_cookies["_mondek"][:same_site] == "Lax"
    assert get_resp_header(conn, "set-cookie") |> hd() =~ "HttpOnly"
  end

  test "internal HTTP remains usable and cannot issue an insecure deployment cookie" do
    Application.put_env(:mondek, :deployment_mode, true)
    conn = Plug.Test.conn(:get, "http://controller:4000/health") |> session_response()
    assert conn.status == 200
    assert conn.scheme == :http
    assert conn.resp_cookies["_mondek"][:secure] == true
    assert get_resp_header(conn, "location") == []
  end

  test "local HTTP sessions keep working and ignore untrusted forwarded headers" do
    Application.put_env(:mondek, :deployment_mode, false)

    conn =
      Plug.Test.conn(:get, "/checks")
      |> put_req_header("x-forwarded-proto", "https")
      |> session_response()

    assert conn.scheme == :http
    refute conn.resp_cookies["_mondek"][:secure]
  end
end
