# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationInventoryTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Inspection, NotificationFilters}

  test "notification filters and text search apply before paging without searching secret destinations" do
    connect()
    ingest(measurement("CRIT"))
    original = Repo.one!(Occurrence)
    now = Monitoring.now()

    for n <- 1..30 do
      payload =
        if n == 30,
          do: Map.put(original.payload, "email", %{"label" => "Historic ledger receiver"}),
          else: original.payload

      Repo.insert!(%Occurrence{
        incident_id: original.incident_id,
        attention_revision: original.attention_revision + n,
        kind: "resolved",
        payload: payload,
        destination:
          if(n == 30,
            do: "mailto:operator@example.invalid",
            else: "https://receiver.invalid/private-destination-token"
          ),
        status: "delivered",
        inserted_at: DateTime.add(now, n)
      })
    end

    result =
      Inspection.delivery_inspection(
        %{"notification_status" => "all", "search" => "historic ledger"},
        now
      )

    assert result["notification_page"]["total"] == 1
    assert length(result["occurrences"]) == 1
    assert hd(result["occurrences"])["destination"] == "mailto:operator@example.invalid"

    assert Inspection.delivery_inspection(
             %{"notification_status" => "all", "notification_channel" => "email"},
             now
           )["notification_page"]["total"] == 1

    assert Inspection.delivery_inspection(
             %{
               "notification_status" => "all",
               "notification_event" => "resolved",
               "notification_channel" => "webhook",
               "notification_type" => "health"
             },
             now
           )["notification_page"]["total"] == 29

    assert Inspection.delivery_inspection(
             %{"notification_status" => "all", "search" => "private-destination-token"},
             now
           )["notification_page"]["total"] == 0

    assert Inspection.delivery_inspection(
             %{"notification_status" => "all", "notification_type" => "loss"},
             now
           )["notification_page"]["total"] == 0
  end

  test "visible defaults and bounded values normalize consistently" do
    assert NotificationFilters.params(%{}) == %{"notification_status" => "unresolved"}

    assert NotificationFilters.params(%{"notification_status" => "all"}) == %{
             "notification_status" => "all"
           }

    assert NotificationFilters.params(%{
             "search" => <<255>>,
             "notification_channel" => "other",
             "notification_page" => "bad"
           }) == %{"notification_status" => "unresolved"}
  end
end
