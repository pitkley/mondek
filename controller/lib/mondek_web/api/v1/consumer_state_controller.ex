# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.ConsumerStateController do
  use MondekWeb.API.Controller
  alias Mondek.ConsumerState
  def open_api_operation(action), do: MondekWeb.API.Contract.operation(action)

  def consumer_state(conn, params),
    do: MondekWeb.API.Read.run(conn, fn _ -> ConsumerState.list(params) end)

  def consumer_state_entry(conn, %{"id" => id}),
    do:
      MondekWeb.API.Read.run(conn, fn _ ->
        case ConsumerState.get(id) do
          {:ok, entry} -> entry
          _ -> nil
        end
      end)

  def runner_state(conn, params), do: respond(conn, ConsumerState.exchange(params))
end
