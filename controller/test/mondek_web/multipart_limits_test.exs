# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MultipartLimitsTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  test "multipart framing consumes the aggregate request budget" do
    body = String.duplicate("--test-boundary\r\n\r\n\r\n", 50) <> "--test-boundary--\r\n"
    conn = parse(body, 128)
    assert conn.halted
    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "http_413"
  end

  test "ordinary multipart form fields still parse inside the budget" do
    body =
      "--test-boundary\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nHello\r\n--test-boundary--\r\n"

    conn = parse(body, 256)
    refute conn.halted
    assert conn.body_params == %{"note" => "Hello"}
  end

  defp parse(body, limit) do
    options = MondekWeb.API.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: limit)

    conn(:post, "/api/v1/runner/control", body)
    |> put_req_header("content-type", "multipart/form-data; boundary=test-boundary")
    |> MondekWeb.API.Parsers.call(options)
  end
end
