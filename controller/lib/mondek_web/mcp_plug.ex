# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MCPPlug do
  @moduledoc "Stateless JSON-response Streamable HTTP endpoint, before general body parsing."
  import Plug.Conn
  @max_response 1_048_576
  def init(options), do: options

  def call(%{request_path: "/mcp"} = conn, _) do
    cond do
      get_req_header(conn, "origin") != [] ->
        reply(conn, 403, Mondek.MCP.error(nil, -32600, "Browser origins are not supported."))

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "") |> halt()

      not json_content?(conn) ->
        reply(conn, 415, Mondek.MCP.error(nil, -32600, "Use application/json."))

      not accepts_json?(conn) ->
        reply(
          conn,
          406,
          Mondek.MCP.error(nil, -32600, "Accept application/json and text/event-stream.")
        )

      not valid_version?(conn) ->
        reply(conn, 400, Mondek.MCP.error(nil, -32600, "Unsupported MCP-Protocol-Version."))

      true ->
        read(conn)
    end
  end

  def call(conn, _), do: conn

  defp read(conn) do
    case read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5_000) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, message} ->
            case Mondek.MCP.handle(message) do
              :notification -> conn |> send_resp(202, "") |> halt()
              response -> reply(conn, 200, response)
            end

          _ ->
            reply(conn, 400, Mondek.MCP.error(nil, -32700, "Invalid JSON."))
        end

      {:more, _, conn} ->
        reply(conn, 413, Mondek.MCP.error(nil, -32600, "Request exceeds 16 KiB."))

      {:error, _} ->
        reply(conn, 400, Mondek.MCP.error(nil, -32600, "Could not read request."))
    end
  end

  defp reply(conn, status, response) do
    encoded = Jason.encode!(response)

    encoded =
      if byte_size(encoded) > @max_response,
        do:
          Jason.encode!(
            Mondek.MCP.error(
              response["id"],
              -32603,
              "Response exceeds 1 MiB; request an exact observation or narrower scope."
            )
          ),
        else: encoded

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, encoded)
    |> halt()
  end

  defp json_content?(conn),
    do:
      Enum.any?(
        get_req_header(conn, "content-type"),
        &match?({:ok, "application", "json", _}, Plug.Conn.Utils.media_type(&1))
      )

  defp accepts_json?(conn) do
    accept = Enum.join(get_req_header(conn, "accept"), ",")
    String.contains?(accept, "application/json") and String.contains?(accept, "text/event-stream")
  end

  defp valid_version?(conn),
    do:
      get_req_header(conn, "mcp-protocol-version") in [
        [],
        ["2025-03-26"],
        ["2025-06-18"],
        ["2025-11-25"]
      ]
end
