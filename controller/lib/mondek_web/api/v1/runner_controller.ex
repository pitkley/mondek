# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.RunnerController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:inventory), do: MondekWeb.API.Contract.operation(:inventory)
  def open_api_operation(:observations), do: MondekWeb.API.Contract.operation(:observations)
  def open_api_operation(:control), do: MondekWeb.API.Contract.operation(:control)

  def inventory(conn, params), do: respond(conn, Monitoring.inventory(params))

  def observations(conn, params) do
    result =
      case Monitoring.ingest(params) do
        {:ok, receipt} ->
          {:ok,
           Map.update!(receipt, "dispositions", fn rows ->
             Enum.map(rows, fn row ->
               if is_binary(row["id"]) and byte_size(row["id"]) == 36 and
                    match?({:ok, _}, Ecto.UUID.cast(row["id"])),
                  do: row,
                  else: Map.put(row, "id", nil)
             end)
           end)}

        other ->
          other
      end

    respond(conn, result)
  end

  def control(conn, params) do
    case Mondek.Protocol.control(params) do
      :ok ->
        # Subscribe before the durable read, then wait outside its transaction.
        # Heartbeats and observations update the UI topic only: waking every peer
        # on recurring traffic creates a self-sustaining fleet polling storm.
        topics = [
          Monitoring.control_topic(nil),
          Monitoring.control_topic(params["installation_id"])
        ]

        for topic <- topics, do: Phoenix.PubSub.subscribe(Mondek.PubSub, topic)

        try do
          result = Monitoring.control(params)
          wait = control_wait_seconds(params, result)

          if match?({:ok, _}, result) and wait > 0 do
            receive do
              :control_changed -> :ok
            after
              wait * 1000 -> :ok
            end

            respond(conn, Monitoring.control(Map.put(params, "wait_seconds", 0)))
          else
            respond(conn, result)
          end
        after
          for topic <- topics, do: Phoenix.PubSub.unsubscribe(Mondek.PubSub, topic)
        end

      error ->
        respond(conn, error)
    end
  end

  defp control_wait_seconds(params, {:ok, response}) do
    desired = Map.new(response["assignments"], &{&1["id"], &1["generation"]})

    actionable =
      response["assignments_authoritative"] != true ||
        desired != (params["active"] || %{}) ||
        desired != (params["prepared"] || %{}) ||
        map_size(response["inventory_refresh"] || %{}) > 0

    if actionable && (params["wait_seconds"] || 0) > 2,
      do: 0,
      else: min(params["wait_seconds"] || 0, div(Mondek.MonitoringLoss.contact_seconds(), 2))
  end

  defp control_wait_seconds(_params, _result), do: 0
end
