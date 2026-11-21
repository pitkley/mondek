# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.ResultsController do
  use MondekWeb.API.Controller
  alias Mondek.Investigation
  alias MondekWeb.API.Read

  for action <- [:checks, :check, :evidence, :observation, :result_inspection] do
    def open_api_operation(unquote(action)), do: MondekWeb.API.Contract.operation(unquote(action))
  end

  def result_inspection(conn, %{"id" => id}),
    do:
      Read.run(conn, fn at ->
        case Mondek.Monitoring.stream_inspection(id, at) do
          nil ->
            nil

          detail ->
            key = detail["stream"]["result_key"]

            detail
            |> Map.take(
              ~w(stream assignment incidents controls occurrences evidence limits measurement_history)
            )
            |> Map.update!("stream", &Investigation.result_summary/1)
            |> Map.update!("assignment", &Investigation.safe_assignment/1)
            |> Map.update!("evidence", fn rows ->
              Enum.map(rows, &Investigation.report_excerpt(&1, key))
            end)
        end
      end)

  def checks(conn, params), do: Read.run(conn, &Investigation.results(params, &1))
  def check(conn, %{"id" => id}), do: Read.run(conn, &Investigation.result(id, &1))

  def evidence(conn, %{"id" => id} = params),
    do:
      Read.run(conn, fn at ->
        case Investigation.evidence(Map.put(params, "result_id", id), at) do
          nil ->
            nil

          data ->
            Map.merge(
              data["evidence"],
              Map.take(
                data,
                ~w(missing_referenced_observation_ids retained_measurement_details latest_execution_details)
              )
            )
        end
      end)

  def observation(conn, %{"id" => id, "observation_id" => observation}),
    do:
      Read.run(conn, fn at ->
        case Investigation.evidence(%{"result_id" => id, "observation_id" => observation}, at) do
          nil -> nil
          data -> List.first(data["evidence"]["items"])
        end
      end)
end
