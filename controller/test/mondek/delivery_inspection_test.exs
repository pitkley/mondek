# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DeliveryInspectionTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MondekWeb.Endpoint

  test "all retained notifications are paged with independent totals and page-scoped attempts" do
    {retry, entries} = delivery_history()
    first = Monitoring.delivery_inspection(%{}, at())

    assert first["notification_page"] == %{
             "status" => "unresolved",
             "page" => 1,
             "page_size" => 25,
             "total" => 126
           }

    assert first["notification_backlog"]["total"] == 126
    assert length(first["occurrences"]) == 25

    pages =
      for page <- 1..6, do: Monitoring.delivery_inspection(%{"notification_page" => page}, at())

    ids = for page <- pages, occurrence <- page["occurrences"], do: occurrence["id"]
    assert length(ids) == 126
    assert length(Enum.uniq(ids)) == 126
    assert List.last(ids) == retry.id
    assert length(List.last(pages)["occurrences"]) == 1

    visible = MapSet.new(Enum.map(first["occurrences"], & &1["id"]))
    assert Enum.all?(first["attempts"], &MapSet.member?(visible, &1["occurrence_id"]))
    assert first["notification_attempts"]["total"] == 125
    assert first["notification_attempts"]["returned"] == 100
    assert first["notification_attempts"]["omitted"] == 25

    accepted =
      Monitoring.delivery_inspection(
        %{"notification_status" => "delivered", "notification_page" => "999"},
        at()
      )

    assert accepted["notification_page"] == %{
             "status" => "delivered",
             "page" => 1,
             "page_size" => 25,
             "total" => 2
           }

    assert accepted["notification_backlog"]["total"] == 126

    assert Enum.map(accepted["occurrences"], & &1["id"]) ==
             Enum.map(Enum.reverse(Enum.take(entries, -2)), & &1.id)

    invalid =
      Monitoring.delivery_inspection(
        %{"notification_status" => "invented", "notification_page" => "-1"},
        at()
      )

    assert invalid["notification_page"] == first["notification_page"]

    assert Monitoring.delivery_inspection(%{"notification_status" => "all"}, at())[
             "notification_page"
           ]["total"] == 128
  end

  test "an exhausted notification beyond the old backlog limit has stable detail, retry and return context" do
    {retry, _} = delivery_history()
    path = "/notifications?notification_page=6&notification_status=exhausted"
    detail_path = MondekWeb.NotificationNavigation.detail_path(retry.id, path)
    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, "#notification-pagination", "Page 6 of 6")
    assert has_element?(view, "#notifications .badge", "126 outstanding")
    assert has_element?(view, "#notification-row-#{retry.id} a[href='#{detail_path}']")
    refute has_element?(view, "#retry-notification-#{retry.id}")

    # Recovered unchanged form state must keep the selected page.
    view |> form("#notification-filters", notification_status: "exhausted") |> render_change()
    assert has_element?(view, "#notification-pagination", "Page 6 of 6")

    {:ok, detail, _} = live(build_conn(), detail_path)
    assert has_element?(detail, "a[href='#{path}']", "Back to notifications")

    detail
    |> form("#retry-notification-#{retry.id}", reason: "Receiver repaired")
    |> render_change()

    send(detail.pid, :tick)
    assert has_element?(detail, "#retry-reason-#{retry.id}[value='Receiver repaired']")

    detail |> element("#notification-#{retry.id} a", "incident") |> render_click()

    incident_path =
      "/incidents/#{retry.incident_id}?" <> URI.encode_query(%{"return_to" => detail_path})

    assert_redirect(detail, incident_path)
    {:ok, incident_view, _} = live(build_conn(), incident_path)
    assert has_element?(incident_view, "a[href='#{detail_path}']", "Back to notification")

    {:ok, detail, _} = live(build_conn(), detail_path)

    detail
    |> form("#retry-notification-#{retry.id}", reason: "Receiver repaired")
    |> render_submit()

    assert Repo.get!(Occurrence, retry.id).status == "pending"
    assert Repo.get!(Occurrence, retry.id).payload == retry.payload
    assert has_element?(detail, "#notification-#{retry.id}")
    refute has_element?(detail, "#retry-notification-#{retry.id}")

    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, "#notification-pagination", "Page 5 of 5")
    refute has_element?(view, "#notification-row-#{retry.id}")
    view |> form("#notification-filters", notification_status: "delivered") |> render_change()
    assert_patch(view, "/notifications?notification_status=delivered")
    assert has_element?(view, "#notification-pagination", "2 matching notifications")
    assert has_element?(view, "#notifications .badge", "126 outstanding")
    view |> form("#notification-filters", notification_status: "superseded") |> render_change()
    assert has_element?(view, "#notification-empty", "No notifications match this status")
  end

  test "notification navigation rejects nested inputs and details expose only the exact occurrence" do
    {retry, _} = delivery_history()
    detail = Mondek.Inspection.notification_detail(retry.id, at())
    assert detail["occurrence"]["id"] == retry.id
    assert detail["attempts"] == []
    assert Enum.all?(detail["jobs"], &(&1["args"]["occurrence_id"] == retry.id))
    assert Mondek.Inspection.notification_detail("invalid", at()) == nil
    assert Mondek.Inspection.notification_detail(Ecto.UUID.generate(), at()) == nil
    api_detail = get(build_conn(), "/api/v1/notifications/#{retry.id}") |> json_response(200)
    assert api_detail["occurrence"]["id"] == retry.id
    assert get(build_conn(), "/api/v1/notifications/invalid") |> json_response(404)

    api_page =
      get(build_conn(), "/api/v1/notifications", %{notification_status: "delivered"})
      |> json_response(200)

    assert api_page["notification_page"]["total"] == 2
    {:ok, view, _} = live(build_conn(), "/notifications?notification_page[x]=1")
    assert has_element?(view, "#notification-pagination", "Page 1 of 6")
    {:ok, missing, _} = live(build_conn(), "/notifications/invalid")
    assert has_element?(missing, "h1", "Notification not found")

    assert MondekWeb.NotificationNavigation.return_path("https://other.invalid/notifications") ==
             nil

    assert MondekWeb.NotificationNavigation.return_path("/notifications?notification_page[x]=1") ==
             "/notifications"
  end

  defp delivery_history do
    connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)
    retry = Repo.one!(Occurrence)
    Repo.update_all(Oban.Job, set: [state: "discarded"])

    retry =
      Monitoring.change(retry, %{status: "exhausted", inserted_at: DateTime.add(at(), 1000)})

    entries =
      for index <- 1..127 do
        %{
          id: Ecto.UUID.generate(),
          incident_id: incident.id,
          kind: "update",
          attention_revision: index + 1,
          payload: %{},
          destination: retry.destination,
          inserted_at: DateTime.add(at(), index),
          status: if(index <= 125, do: "exhausted", else: "delivered")
        }
      end

    Repo.insert_all(Occurrence, entries)

    Repo.insert_all(
      Attempt,
      for entry <- entries, offset <- 1..5 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: entry.id,
          status: "failed_or_ambiguous",
          started_at: DateTime.add(entry.inserted_at, offset),
          http_status: 503
        }
      end
    )

    {retry, entries}
  end
end
