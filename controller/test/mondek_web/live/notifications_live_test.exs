# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint

  defp notice do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    Monitoring.change(occurrence, %{status: "exhausted"})
  end

  test "same persisted notification has the complete shared body in panel and full page" do
    occurrence = notice()

    for {suffix, surface} <- [{"", "#overview-panel"}, {"/full", "#notification-page"}] do
      {:ok, view, _} = live(build_conn(), "/notifications/#{occurrence.id}#{suffix}")

      for heading <- [
            "Delivery status",
            "Delivery attempts",
            "Retry delivery",
            "Recorded notification"
          ] do
        assert has_element?(
                 view,
                 surface <> if(suffix == "/full", do: " h2", else: " h3"),
                 heading
               )
      end

      assert has_element?(view, surface <> " [data-notification-body]")
      assert has_element?(view, surface <> " #retry-notification-#{occurrence.id}")
      assert has_element?(view, surface <> " a", "View health incident")
      assert has_element?(view, surface <> " a", "View current result")
      assert has_element?(view, surface <> " td", "Webhook receiver · address hidden")
    end
  end

  test "retry draft survives related result, page presentation and return; inactive action is rejected" do
    occurrence = notice()
    {:ok, view, _} = live(build_conn(), "/notifications/#{occurrence.id}")
    form_id = "#retry-notification-#{occurrence.id}"
    input = "#retry-reason-#{occurrence.id}"
    view |> form(form_id, reason: "Receiver repaired") |> render_change()
    root = live_path(view, "#overview-panel a", "Open as page")
    render_patch(view, root)
    assert has_element?(view, "#notification-page #{input}[value='Receiver repaired']")
    related = live_path(view, "#notification-page a", "View current result")
    render_patch(view, related)
    assert has_element?(view, "#overview-panel #preview-result-collection")

    view
    |> with_target("#investigation-stack")
    |> render_hook("retry_notification", %{
      "entity" => "notification:#{occurrence.id}",
      "_id" => occurrence.id,
      "reason" => "Forged inactive action"
    })

    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    back = live_path(view, "#overview-panel a[data-overview-close]", "Back one level")
    render_patch(view, back)
    send(view.pid, :tick)
    assert has_element?(view, input <> "[value='Receiver repaired']")
    view |> form(form_id, reason: "Receiver repaired") |> render_submit()
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    assert has_element?(view, "#notification-delivery [role='status']", "requested")
  end

  test "outstanding is a visible removable chip and free text combines with delivery filters" do
    occurrence = notice()
    {:ok, view, _} = live(build_conn(), "/notifications")
    assert has_element?(view, "#preview-chip-notification_status", "Outstanding")
    assert has_element?(view, "#notification-row-#{occurrence.id}")
    view |> element("a[aria-label='Remove Status filter']") |> render_click()
    assert_patch(view, "/notifications?notification_status=all")
    refute has_element?(view, "#preview-chip-notification_status")
    view |> form("#overview-search", search: "not-a-notification") |> render_submit()
    assert_patch(view, "/notifications?notification_status=all&search=not-a-notification")
    assert has_element?(view, "#notification-empty")
    refute has_element?(view, "#notification-row-#{occurrence.id}")
    assert has_element?(view, "#overview-filter-notification_channel", "Channel")
    assert has_element?(view, "#overview-filter-notification_event", "Event")
  end

  test "receiver credentials never appear in list, detail, or original payload disclosure" do
    occurrence = notice()
    secret = "https://hooks.example.invalid/secret-webhook-token"

    occurrence =
      Repo.insert!(%Occurrence{
        incident_id: occurrence.incident_id,
        attention_revision: occurrence.attention_revision + 1,
        kind: "resolved",
        status: "exhausted",
        inserted_at: Monitoring.now(),
        destination: secret,
        payload: Map.put(occurrence.payload, "webhook_delivery", %{"url" => secret})
      })

    for path <- [
          "/notifications",
          "/notifications/#{occurrence.id}",
          "/notifications/#{occurrence.id}/full"
        ] do
      {:ok, view, _} = live(build_conn(), path)
      refute render(view) =~ "secret-webhook-token"
    end
  end

  test "malformed presentation and unknown identity keep a useful view" do
    notice()
    {:ok, view, _} = live(build_conn(), "/notifications?surface=page&page_entity[]=bad")
    assert has_element?(view, "#notifications-heading")
    {:ok, missing, _} = live(build_conn(), "/notifications/#{Ecto.UUID.generate()}/full")
    assert has_element?(missing, "h1", "Notification not found")
  end

  test "notification identity, receiver and longer attempt history remain complete in both surfaces" do
    base = notice()

    for {receiver, label, n} <- [
          {"mailto:operator@example.invalid", "operator@example.invalid", 1},
          {"webhook:teams-ops", "Webhook · teams-ops", 2},
          {"webhook:teams-backup", "Webhook · teams-backup", 3}
        ] do
      item =
        Repo.insert!(%Occurrence{
          incident_id: base.incident_id,
          kind: "update",
          attention_revision: base.attention_revision + n,
          payload:
            base.payload
            |> Map.put("result_key", "result-#{n}")
            |> Map.put("target", %{
              "kind" => "volume",
              "key" => "volume-#{n}",
              "label" => "Volume #{n}"
            }),
          destination: receiver,
          status: "exhausted",
          inserted_at: Monitoring.now()
        })

      for offset <- 1..7 do
        Repo.insert!(%Attempt{
          occurrence_id: item.id,
          status: "failed_or_ambiguous",
          http_status: 503,
          started_at: DateTime.add(Monitoring.now(), -offset),
          finished_at: Monitoring.now()
        })
      end

      for suffix <- ["", "/full"] do
        {:ok, view, _} = live(build_conn(), "/notifications/#{item.id}#{suffix}")
        assert has_element?(view, "[data-notification-body] td", label)
        assert has_element?(view, "[data-notification-body]", "Severity change")
        assert has_element?(view, "[data-notification-body]", "Volume #{n}")
        assert has_element?(view, "[data-notification-body]", "result-#{n}")

        rows =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query("[data-notification-body] .notification-attempt-table tbody tr")
          |> Enum.count()

        assert rows == 7
        if suffix == "", do: assert(has_element?(view, "details", "Earlier attempts (2)"))
      end
    end

    {:ok, view, _} = live(build_conn(), "/notifications?notification_event=update")
    assert has_element?(view, ".notification-matching-count", "3 matching notifications")
    for n <- 1..3, do: assert(has_element?(view, ".notification-table", "Volume #{n}"))
  end

  test "inactive signed retry recovery preserves values but cannot revive remote eligibility" do
    item = notice()
    path = "/notifications/#{item.id}"
    {:ok, view, _} = live(build_conn(), path)
    view |> form("#retry-notification-#{item.id}", reason: "Keep my reason") |> render_change()
    related = live_path(view, "#overview-panel a", "View current result")
    render_patch(view, related)

    snapshot =
      view
      |> element("#investigation-stack-recovery input[name=snapshot]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    Monitoring.change(item, %{status: "delivered"})
    {:ok, recovered, _} = live(build_conn(), related)

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    recovered |> element("#overview-panel a[data-overview-close]") |> render_click()
    assert has_element?(recovered, "[data-notification-body]", "Receiver accepted")
    refute has_element?(recovered, "#retry-notification-#{item.id}")

    signed =
      recovered
      |> element("#investigation-stack-recovery input[name=snapshot]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    assert {:ok, %{states: states}} =
             Phoenix.Token.verify(@endpoint, "investigation-drafts-v1", signed, max_age: 86_400)

    assert states[{"notification", item.id}].retry_drafts[item.id] == "Keep my reason"

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("retry_notification", %{
      "entity" => "notification:#{item.id}",
      "_id" => item.id,
      "reason" => "Forged stale retry"
    })

    assert Repo.get!(Occurrence, item.id).status == "delivered"
    assert has_element?(recovered, "[role=alert]", "no longer eligible")
  end

  test "an exhausted occurrence with active delivery work has no retry action in either surface" do
    item = notice()
    Monitoring.enqueue_notification!(item.id, item.destination)

    for suffix <- ["", "/full"] do
      {:ok, view, _} = live(build_conn(), "/notifications/#{item.id}#{suffix}")
      assert has_element?(view, "[data-notification-body]", "Retries exhausted")
      refute has_element?(view, "#retry-notification-#{item.id}")
    end
  end

  test "recovered retry text is bounded and scoped to eligible notifications" do
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

  defp live_path(view, selector, label) do
    view
    |> element(selector, label)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> hd()
  end
end
