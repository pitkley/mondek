# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Parsers do
  @moduledoc false
  def init(options), do: Plug.Parsers.init(options)

  def call(conn, options) do
    conn = Plug.Parsers.call(conn, options)

    if raw = conn.private[:consumer_state_body] do
      case Jason.decode(raw, objects: :ordered_objects) do
        {:ok, value} ->
          if unique?(value, 0),
            do: conn,
            else:
              conn
              |> MondekWeb.API.Response.error(
                400,
                "invalid_state_json",
                "State JSON must have unique object keys and bounded nesting."
              )
              |> Plug.Conn.halt()

        _ ->
          conn
          |> MondekWeb.API.Response.error(400, "invalid_state_json", "Invalid state JSON.")
          |> Plug.Conn.halt()
      end
    else
      conn
    end
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

  defp unique?(_, depth) when depth > 35, do: false

  defp unique?(%Jason.OrderedObject{values: values}, depth) do
    keys = Enum.map(values, &elem(&1, 0))

    length(keys) == MapSet.size(MapSet.new(keys)) and
      Enum.all?(values, fn {_, value} -> unique?(value, depth + 1) end)
  end

  defp unique?(values, depth) when is_list(values), do: Enum.all?(values, &unique?(&1, depth + 1))
  defp unique?(_, _), do: true
end
