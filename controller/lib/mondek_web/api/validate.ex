# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Validate do
  @moduledoc "Operation validation without changing decoded evidence or domain inputs."
  import Plug.Conn
  def init(options), do: options

  def call(conn, _) do
    action = conn.private.phoenix_action
    operation = conn.private.phoenix_controller.open_api_operation(action)
    if is_nil(operation), do: conn, else: validate(conn, operation)
  end

  defp validate(conn, operation) do
    allowed = for p <- operation.parameters, p.in == :query, do: to_string(p.name)
    conn = fetch_query_params(conn)

    if Enum.any?(Map.keys(conn.query_params), &(&1 not in allowed)) do
      conn
      |> MondekWeb.API.Response.error(400, "unknown_parameter", "Unsupported query parameter.")
      |> halt()
    else
      validated =
        OpenApiSpex.Plug.CastAndValidate.call(
          conn,
          OpenApiSpex.Plug.CastAndValidate.init(
            replace_params: false,
            render_error: MondekWeb.API.ValidationError
          )
        )

      if validated.halted do
        validated
      else
        cast = Map.new(OpenApiSpex.params(validated) || %{}, fn {k, v} -> {to_string(k), v} end)
        raw_body = if is_struct(conn.body_params), do: %{}, else: conn.body_params
        params = Map.merge(raw_body, cast)

        params =
          case params["opened_since"] do
            value when is_binary(value) ->
              {:ok, at, _} = DateTime.from_iso8601(value)
              Map.put(params, "opened_since", at)

            _ ->
              params
          end

        %{validated | params: params}
      end
    end
  end
end

defmodule MondekWeb.API.ValidationError do
  def init(opts), do: opts

  def call(conn, reasons) do
    message =
      if Enum.any?(reasons, &(&1.reason == :unexpected_field)),
        do: "Unknown request field.",
        else: "Request values do not match the operation schema."

    details = %{errors: Enum.map(Enum.take(reasons, 8), &%{reason: to_string(&1.reason)})}

    conn
    |> MondekWeb.API.Response.error(422, "invalid_request", message, details)
    |> Plug.Conn.halt()
  end
end
