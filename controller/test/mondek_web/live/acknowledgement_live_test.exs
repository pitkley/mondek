# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.AcknowledgementLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Control

  @endpoint MondekWeb.Endpoint

  test "default acknowledgement has no invented expiry and remains visible throughout inspection" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    assert has_element?(view, "#ack-mode option[value='until_incident_ends'][selected]")
    refute has_element?(view, "#ack-duration")

    view
    |> form("#acknowledgement-form", note: "Waiting for replacement storage")
    |> render_submit()

    saved = Repo.get!(Incident, incident.id)
    assert saved.acknowledgement_mode == "until_incident_ends"
    assert saved.acknowledged_until == nil
    assert saved.acknowledgement_ceiling == "CRIT"
    assert has_element?(view, "#active-acknowledgement", "Waiting for replacement storage")
    assert has_element?(view, "#acknowledgement-lifetime", "no scheduled expiry")
    assert has_element?(view, "#active-acknowledgement", "Local operator")
    assert has_element?(view, "#active-acknowledgement", "Critical severity and below")
    assert has_element?(view, "#incident-delivery-summary", "no scheduled expiry")
    refute render(view) =~ "until —"
    {:ok, listing, _} = live(build_conn(), "/incidents")

    assert has_element?(
             listing,
             "#incident-row-#{incident.id}.incident-acknowledged .badge.acknowledged",
             "Acknowledged"
           )

    assert has_element?(listing, "#incident-row-#{incident.id} .badge.crit", "Critical")
    assert has_element?(listing, "#incident-row-#{incident.id} .badge.open", "Open")

    assert has_element?(
             listing,
             "#incident-row-#{incident.id}",
             "Failure notifications held"
           )

    assert has_element?(
             listing,
             "#incident-navigation[aria-label='Incidents · 0 unacknowledged open incidents']",
             "0"
           )

    {:ok, resource, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")
    assert has_element?(resource, "#check-control-history", "until this incident ends")

    recovered_at = Monitoring.now()
    recovered_time = DateTime.to_iso8601(recovered_at)

    recovered =
      measurement("OK", 2, %{
        "started_at" => recovered_time,
        "evaluated_at" => recovered_time
      })
      |> update_in(["results"], fn results ->
        Enum.map(results, &Map.put(&1, "source_at", recovered_time))
      end)

    assert disposition(ingest(recovered, recovered_at)) == "current"
    send(view.pid, :tick)
    refute has_element?(view, "#active-acknowledgement")
    refute has_element?(view, "#acknowledgement-form")
    assert has_element?(view, "#incident-acknowledgement", "This incident has ended")
    assert has_element?(view, "#incident-control-history", "Waiting for replacement storage")
  end

  test "live incident ordering and navigation count follow acknowledgement and ending" do
    critical = open_incident()

    warning_report =
      measurement("WARN", 1, %{"assignment_id" => "10000000-0000-4000-8000-000000000002"})
      |> update_in(
        ["results"],
        &Enum.map(&1, fn result -> Map.put(result, "key", "readiness") end)
      )

    assert disposition(ingest(warning_report)) == "current"

    warning =
      Repo.one!(
        from i in Incident, where: i.assignment_id == "10000000-0000-4000-8000-000000000002"
      )

    {:ok, listing, _} = live(build_conn(), "/incidents")
    assert incident_rows(listing) == [critical.id, warning.id]
    assert has_element?(listing, "#incident-attention-count", "2")

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               critical.id,
               options(critical),
               "Investigating critical"
             )

    send(listing.pid, :tick)
    assert incident_rows(listing) == [warning.id, critical.id]
    assert has_element?(listing, "#incident-attention-count", "1")
    assert has_element?(listing, "#incident-row-#{critical.id}.incident-acknowledged")
    assert has_element?(listing, ".page-heading", "2 open · 1 acknowledged")

    {:ok, reconnected, _} = live(build_conn(), "/incidents")
    assert incident_rows(reconnected) == [warning.id, critical.id]
    assert has_element?(reconnected, "#incident-attention-count", "1")

    acknowledged = Repo.get!(Incident, critical.id)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               critical.id,
               Map.put(options(acknowledged), "mode", "end"),
               "Resume attention"
             )

    send(listing.pid, :tick)
    assert incident_rows(listing) == [critical.id, warning.id]
    assert has_element?(listing, "#incident-attention-count", "2")
    refute has_element?(listing, "#incident-row-#{critical.id}.incident-acknowledged")
  end

  test "week and custom durations support long acknowledgement with an honest UTC expiry" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    view |> form("#acknowledgement-form", mode: "duration") |> render_change()
    before = Monitoring.now()

    view
    |> form("#acknowledgement-form", seconds: "604800", note: "Replacement arrives next week")
    |> render_submit()

    saved = Repo.get!(Incident, incident.id)
    assert saved.acknowledgement_mode == "until"
    assert DateTime.diff(saved.acknowledged_until, before) in 604_800..604_805
    assert has_element?(view, "#acknowledgement-lifetime", "UTC")

    view |> form("#acknowledgement-form", mode: "duration") |> render_change()
    view |> form("#acknowledgement-form", seconds: "custom") |> render_change()

    view
    |> form("#acknowledgement-form", days: "999999999", hours: "3", note: "Procurement lead time")
    |> render_submit()

    assert has_element?(view, "#ack-error", "Choose a shorter duration")
    assert has_element?(view, "#ack-days[value='999999999']")
    assert has_element?(view, "#ack-note", "Procurement lead time")

    assert Repo.get!(Incident, incident.id).acknowledgement_note ==
             "Replacement arrives next week"

    before = Monitoring.now()

    view
    |> form("#acknowledgement-form", days: "14", hours: "3", note: "Procurement lead time")
    |> render_submit()

    saved = Repo.get!(Incident, incident.id)
    assert DateTime.diff(saved.acknowledged_until, before) in 1_220_400..1_220_405
    assert saved.acknowledgement_note == "Procurement lead time"
  end

  test "specific UTC expiry is exact and past times preserve the proposed values" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    view |> form("#acknowledgement-form", mode: "until") |> render_change()

    view
    |> form("#acknowledgement-form",
      expires_at: "2003-01-02T15:04:00",
      note: "Maintenance coordination"
    )
    |> render_submit()

    assert has_element?(view, "#ack-error", "Choose a future expiry date and time in UTC.")
    refute render(view) =~ "ISO8601"
    assert has_element?(view, "#ack-expires-at[value='2003-01-02T15:04:00']")
    assert has_element?(view, "#ack-note", "Maintenance coordination")
    assert Repo.get!(Incident, incident.id).acknowledgement_mode == nil

    view |> form("#acknowledgement-form", expires_at: "10000-01-01T00:00:00") |> render_submit()
    assert has_element?(view, "#ack-error", "Enter a valid UTC date and time through year 9999.")
    assert has_element?(view, "#ack-note", "Maintenance coordination")
    assert Repo.get!(Incident, incident.id).acknowledgement_mode == nil

    expiry = Monitoring.now() |> DateTime.add(3 * 86_400) |> DateTime.truncate(:second)
    local = Calendar.strftime(expiry, "%Y-%m-%dT%H:%M:%S")
    view |> form("#acknowledgement-form", expires_at: local) |> render_submit()
    assert DateTime.compare(Repo.get!(Incident, incident.id).acknowledged_until, expiry) == :eq
    assert has_element?(view, "#ack-expiry-help", "Enter UTC")
    assert has_element?(view, "#acknowledgement-lifetime", Calendar.strftime(expiry, "%Y"))
  end

  test "custom draft and reviewed revision survive ticks and reconnect without recording a control" do
    incident = open_incident()
    path = incident_path(incident)
    {:ok, view, _} = live(build_conn(), path)
    view |> form("#acknowledgement-form", mode: "duration") |> render_change()
    view |> form("#acknowledgement-form", seconds: "custom") |> render_change()

    view
    |> form("#acknowledgement-form", days: "30", hours: "6", note: "Waiting for reviewed change")
    |> render_change()

    captured =
      recovery(view, %{
        "mode" => "duration",
        "seconds" => "custom",
        "days" => "30",
        "hours" => "6",
        "note" => "Waiting for reviewed change"
      })

    send(view.pid, :tick)
    assert has_element?(view, "#ack-days[value='30']")
    assert has_element?(view, "#ack-hours[value='6']")
    assert Repo.aggregate(Control, :count) == 0
    {:ok, recovered, _} = live(build_conn(), path)
    recovered |> render_change("edit_acknowledgement", captured)
    send(recovered.pid, :tick)
    assert has_element?(recovered, "#ack-days[value='30']")
    assert has_element?(recovered, "#ack-note", "Waiting for reviewed change")
    assert hidden(recovered, "_revision") == hidden(view, "_revision")
    assert Repo.aggregate(Control, :count) == 0
    recovered |> form("#acknowledgement-form") |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Waiting for reviewed change"
  end

  test "a concurrent control cannot be overwritten or cancelled through a stale draft" do
    incident = open_incident()
    path = incident_path(incident)
    {:ok, old_view, _} = live(build_conn(), path)

    old_view
    |> form("#acknowledgement-form", note: "My proposed investigation")
    |> render_change()

    captured =
      recovery(old_view, %{"mode" => "until_incident_ends", "note" => "My proposed investigation"})

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(incident.id, options(incident), "Newer control")

    old_view |> render_submit("acknowledge", captured)
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Newer control"
    assert has_element?(old_view, "#ack-note", "My proposed investigation")
    assert has_element?(old_view, "#review-acknowledgement")

    old_view
    |> render_click("end_acknowledgement", %{
      "id" => incident.id,
      "revision" => captured["_revision"],
      "attention_revision" => captured["_attention_revision"]
    })

    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    assert has_element?(old_view, "#end-acknowledgement[disabled]")

    {:ok, recovered, _} = live(build_conn(), path)
    recovered |> render_change("edit_acknowledgement", captured)
    assert has_element?(recovered, "#review-acknowledgement")
    recovered |> element("#review-acknowledgement") |> render_click()
    assert has_element?(recovered, "#ack-note", "My proposed investigation")
    refute has_element?(recovered, "#end-acknowledgement[disabled]")
    recovered |> form("#acknowledgement-form") |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "My proposed investigation"
    recovered |> element("#end-acknowledgement") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    assert has_element?(recovered, "#ack-mode option[value='until_incident_ends'][selected]")
  end

  test "a severity change requires explicit review while a current acknowledgement keeps its original ceiling" do
    incident = open_incident("WARN")
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    captured = recovery(view, %{"mode" => "until_incident_ends", "note" => "Reviewing warning"})
    ingest(measurement("CRIT", 2))
    view |> render_submit("acknowledge", captured)
    assert Repo.get!(Incident, incident.id).acknowledgement_mode == nil
    assert has_element?(view, "#review-acknowledgement")
    view |> element("#review-acknowledgement") |> render_click()
    assert has_element?(view, "#ack-reviewed-severity", "Critical")
    view |> form("#acknowledgement-form") |> render_submit()
    ingest(measurement("WARN", 3))
    ingest(measurement("CRIT", 4))
    send(view.pid, :tick)
    assert has_element?(view, "#active-acknowledgement", "Critical severity and below")
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
  end

  test "old acknowledgement history does not invent an unavailable severity ceiling" do
    incident = open_incident()
    reviewed_acknowledgement_fixture(incident.id, 900, "Historical timed control")

    Repo.update_all(from(c in Control, where: c.incident_id == ^incident.id),
      set: [acknowledgement_ceiling: nil]
    )

    {:ok, view, _} = live(build_conn(), incident_path(incident))
    assert render(view) =~ "Historical timed control"
    refute render(view) =~ "covers —"
  end

  defp open_incident(health \\ "CRIT") do
    connect()
    ingest(measurement(health))
    Repo.one!(Incident)
  end

  defp incident_path(incident), do: "/incidents/" <> incident.id

  defp incident_rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#incident-list tbody tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "incident-row-", ""))
  end

  defp options(incident),
    do: %{
      "mode" => "until_incident_ends",
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

  defp hidden(view, name),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#acknowledgement-form input[name='#{name}']")
      |> LazyHTML.attribute("value")
      |> hd()

  defp recovery(view, values),
    do:
      Map.merge(
        Map.new(~w(_id _revision _attention_revision _health), &{&1, hidden(view, &1)}),
        values
      )
end
