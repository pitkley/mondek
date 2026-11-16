# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationTransport do
  @moduledoc "Renders batch bodies from compatible frozen native transport snapshots."
  def freeze!(payload, title, original) do
    basis = %{
      "destination" => original.destination,
      "email" => original.payload["email"] && Map.drop(original.payload["email"], ~w(message)),
      "webhook" => original.payload["webhook_delivery"],
      "title" => title
    }

    {render(payload, basis), basis}
  end

  def terminal!(payload, basis), do: {render(payload, basis), basis}

  defp render(payload, basis) do
    cond do
      basis["email"] ->
        email =
          Map.merge(basis["email"], %{
            "label" => basis["title"],
            "summary" => payload["scope"],
            "measured_health" => payload["health"]
          })

        p = Map.put(payload, "email", email)

        message =
          Mondek.NotificationDelivery.message(%{
            id: payload["occurrence_id"],
            payload: p,
            destination: basis["destination"],
            inserted_at: DateTime.utc_now()
          })

        put_in(p, ["email", "message"], message)

      basis["webhook"] ->
        old = basis["webhook"]

        document =
          Mondek.WebhookNotification.document(
            payload,
            basis["title"],
            payload["scope"],
            payload["health"],
            (basis["email"] && basis["email"]["public_url"]) || old["public_url"]
          )

        document =
          Map.put(document, "batch", %{
            "scope" => payload["scope"],
            "members" => payload["members"],
            "failure_batch_id" => payload["failure_batch_id"]
          })

        body = Mondek.WebhookNotification.render!(old["template"], document)

        Map.put(
          payload,
          "webhook_delivery",
          Map.merge(old, %{"document" => document, "body" => body, "render_error" => false})
        )

      true ->
        payload
    end
  end
end
