# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.APIResponse do
  @moduledoc "Decode API envelopes for existing domain-oriented HTTP assertions."
  def json_response(conn, status) do
    body = Phoenix.ConnTest.json_response(conn, status)

    if conn.private[:open_api_spex] do
      OpenApiSpex.TestAssertions.assert_operation_response(conn)
    end

    unpack(body)
  end

  def unpack(body) do
    case body do
      %{"data" => data, "meta" => meta} when is_list(data) ->
        Map.put(meta, "items", data)

      %{"data" => data, "meta" => _} ->
        data

      %{"error" => %{"code" => code, "message" => message} = error} ->
        body
        |> Map.merge(error["details"] || %{})
        |> Map.merge(%{"code" => code, "error" => message})

      _ ->
        body
    end
  end
end
