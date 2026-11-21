# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Response do
  import Plug.Conn

  def reply(conn, value) do
    if (conn.status || 200) >= 400 do
      code = value[:code] || value["code"] || "request_rejected"
      message = value[:error] || value["error"] || "Request rejected."
      error(conn, conn.status, code, message, Map.take(value, [:stale_ids, "stale_ids"]))
    else
      body =
        if conn.method in ["GET", "HEAD"] and String.starts_with?(conn.request_path, "/api/v1/") do
          MondekWeb.API.JSON.envelope(value, conn.assigns[:api_at] || Mondek.Monitoring.now())
        else
          value
        end

      body = MondekWeb.API.JSON.normalize(body)

      body =
        if conn.private[:open_api_spex] do
          {spec, operations} = OpenApiSpex.Plug.PutApiSpec.get_spec_and_operation_lookup(conn)
          operation = operations[conn.private.open_api_spex[:operation_id]]

          if operation do
            schema = operation.responses[200].content["application/json"].schema
            MondekWeb.API.JSON.project(body, schema, spec.components.schemas)
          else
            body
          end
        else
          body
        end

      encoded = Jason.encode!(body)

      if conn.method in ["GET", "HEAD"] and
           byte_size(encoded) >
             if(conn.private.phoenix_action == :snapshot, do: 8_388_608, else: 1_048_576) do
        error(conn, 422, "response_too_large", "Narrow the request or fetch exact evidence.")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(conn.status || 200, encoded)
      end
    end
  end

  def error(conn, status, code, message, details \\ %{}) do
    error = %{code: to_string(code), message: to_string(message)}
    error = if map_size(details) > 0, do: Map.put(error, :details, details), else: error

    body = %{
      error: error,
      request_id:
        Logger.metadata()[:request_id] || List.first(get_resp_header(conn, "x-request-id")) ||
          "unknown"
    }

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  def integer(n) when is_integer(n), do: n

  def integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def integer(_), do: nil
  def respond(conn, {:ok, value}), do: reply(conn, value)

  def respond(conn, {:error, {:invalid, reason}}),
    do: conn |> put_status(422) |> reply(%{error: reason})

  def respond(conn, {:error, {:conflict, reason}}),
    do: conn |> put_status(409) |> reply(%{code: "configuration_conflict", error: reason})

  def respond(conn, {:error, :delivery_disabled}),
    do:
      error(conn, 409, "delivery_disabled", "Notification delivery is off for this installation.")

  def respond(conn, {:error, :unavailable}),
    do: error(conn, 503, "unavailable", "Investigation temporarily unavailable.")

  def respond(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> reply(%{error: "Not found"})

  def respond(conn, {:error, :publisher_retired}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: "publisher_retired",
        error:
          "This source publication was retired by the operator. Its inventory remains fenced until explicitly restored."
      })

  def respond(conn, {:error, :publication_refresh_required}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: "publication_refresh_required",
        error:
          "Restoration requires successful discovery for the controller's current restoration request and a newer complete inventory. Upgrade to a runner supporting this request and refresh discovery before publishing again."
      })

  def respond(conn, {:error, {:stale, ids}}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: "stale_selection",
        stale_ids: ids,
        error:
          "Selected checks changed. Keep the draft, refresh the selection and review it again."
      })

  def respond(conn, {:error, :review_expired}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: "review_expired",
        error: "This review expired after 15 minutes. Keep the draft and review it again."
      })

  def respond(conn, {:error, :review_changed}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: "review_changed",
        error:
          "The draft or matching records changed after review. Review the current draft before applying it."
      })

  def respond(conn, {:error, :invalid_review}),
    do:
      conn
      |> put_status(422)
      |> reply(%{
        code: "invalid_review",
        error: "Supply a valid review before applying changes."
      })

  def respond(conn, {:error, reason}),
    do:
      conn
      |> put_status(409)
      |> reply(%{
        code: if(is_atom(reason), do: Atom.to_string(reason), else: "conflict"),
        error: to_string(reason)
      })
end
