# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.PublishersController do
  use MondekWeb.API.Controller
  def open_api_operation(:publisher), do: MondekWeb.API.Contract.operation(:publisher)

  def open_api_operation(:publisher_successors),
    do: MondekWeb.API.Contract.operation(:publisher_successors)

  def open_api_operation(:publisher_event), do: MondekWeb.API.Contract.operation(:publisher_event)

  def open_api_operation(:publisher_evidence),
    do: MondekWeb.API.Contract.operation(:publisher_evidence)

  def open_api_operation(:publisher_preview),
    do: MondekWeb.API.Contract.operation(:publisher_preview)

  def open_api_operation(:publisher_apply), do: MondekWeb.API.Contract.operation(:publisher_apply)

  def publisher(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.get(id, p["page"] || 1))

  def publisher_successors(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.successors(id, p))

  def publisher_event(conn, %{"id" => id, "event_id" => event_id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.event(id, event_id, p["page"] || 1))

  def publisher_evidence(conn, %{
        "id" => id,
        "event_id" => event_id,
        "observation_id" => observation_id
      }),
      do: respond(conn, Mondek.PublisherLifecycle.evidence(id, event_id, observation_id))

  def publisher_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.PublisherLifecycle.preview(
          p["proposal"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def publisher_apply(conn, p),
    do: respond(conn, Mondek.PublisherLifecycle.apply(p["review_token"], p["proposal"]))
end
