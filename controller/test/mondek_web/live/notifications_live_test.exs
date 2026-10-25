# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MondekWeb.Endpoint

  test "same notification keeps its retry draft across return-context patches; another page clears it" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    Monitoring.change(occurrence, %{status: "exhausted"})
    path = "/notifications/#{occurrence.id}"
    {:ok, view, _} = live(build_conn(), path)
    form_id = "#retry-notification-#{occurrence.id}"
    input = "#retry-reason-#{occurrence.id}"

    view |> form(form_id, reason: "Investigating receiver") |> render_change()
    return_to = "/notifications?notification_status=exhausted"
    render_patch(view, path <> "?" <> URI.encode_query(%{"return_to" => return_to}))
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='Investigating receiver']")
    assert has_element?(view, "a[href='#{return_to}']", "Back to notifications")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"

    # Navigating away must not carry a draft back to a different investigation.
    render_patch(view, "/notifications/#{Ecto.UUID.generate()}")
    assert has_element?(view, "h1", "Notification not found")
    render_patch(view, path)
    assert has_element?(view, input <> "[value='']")
  end

  test "delivery filters survive ticks and expose resolved work without unrelated page state" do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    {:ok, view, _} = live(build_conn(), "/notifications?notification_status=delivered")
    assert has_element?(view, "#notification-empty")

    Monitoring.change(occurrence, %{status: "delivered"})
    send(view.pid, :tick)
    assert has_element?(view, "#notification-row-#{occurrence.id}", "Receiver accepted")
    assert has_element?(view, "#notification-status option[value='delivered'][selected]")
    assert has_element?(view, "#incident-navigation", "1")
    refute has_element?(view, "#runner-filters")
    refute has_element?(view, "#configuration-form")
  end

  test "recovered retry text is bounded and scoped to rendered retryable notifications" do
    alias MondekWeb.NotificationRetry
    id = Ecto.UUID.generate()
    visible = [%{"id" => id, "can_retry" => true}]

    assert NotificationRetry.keep_draft(%{}, visible, id, "Investigating") == %{
             id => "Investigating"
           }

    assert NotificationRetry.keep_draft(%{}, visible, Ecto.UUID.generate(), "Other") == %{}
    assert NotificationRetry.keep_draft(%{}, visible, id, String.duplicate("x", 2_001)) == %{}
    assert NotificationRetry.keep_draft(%{}, visible, id, <<255>>) == %{}

    assert NotificationRetry.keep_draft(%{}, [%{"id" => id, "can_retry" => false}], id, "Other") ==
             %{}
  end
end
