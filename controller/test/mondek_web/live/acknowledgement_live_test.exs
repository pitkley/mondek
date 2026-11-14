# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.AcknowledgementLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Control
  @endpoint MondekWeb.Endpoint
  @form "#preview-incident-ack-form"

  test "default acknowledgement lasts until incident ends and retains its audit when recovery closes it" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    assert has_element?(view, @form <> " input[value=until_incident_ends][checked]")
    refute has_element?(view, @form <> " input[name=amount]")
    view |> form(@form, note: "Waiting for replacement storage") |> render_submit()
    saved = Repo.get!(Incident, incident.id)
    assert saved.acknowledgement_mode == "until_incident_ends"
    assert saved.acknowledged_until == nil
    assert saved.acknowledgement_ceiling == "CRIT"
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "Incident ends")

    assert has_element?(
             view,
             "table[aria-label='Active acknowledgement']",
             "Waiting for replacement storage"
           )

    assert has_element?(view, "details", "Local operator")
    refute render(view) =~ "until —"
    {:ok, execution, _} = live(build_conn(), "/executions/#{incident.assignment_id}")
    assert has_element?(execution, "#execution-controls", "until this incident ends")
    assert has_element?(execution, "#execution-controls", "Waiting for replacement storage")
    recovered_at = Monitoring.now()
    recovered_time = DateTime.to_iso8601(recovered_at)

    recovered =
      measurement("OK", 2, %{"started_at" => recovered_time, "evaluated_at" => recovered_time})
      |> update_in(
        ["results"],
        &Enum.map(&1, fn row -> Map.put(row, "source_at", recovered_time) end)
      )

    ingest(recovered, recovered_at)
    send(view.pid, :tick)
    refute has_element?(view, "table[aria-label='Active acknowledgement']")
    refute has_element?(view, @form)
    assert render(view) =~ "This incident has ended"
    assert render(view) =~ "Waiting for replacement storage"
  end

  test "incident priority reorders on acknowledgement and ending without changing severity" do
    critical = open_incident()

    report =
      measurement("WARN", 1, %{"assignment_id" => "10000000-0000-4000-8000-000000000002"})
      |> update_in(
        ["results"],
        &Enum.map(&1, fn result -> Map.put(result, "key", "readiness") end)
      )

    assert disposition(ingest(report)) == "current"

    warning =
      Repo.one!(
        from i in Incident, where: i.assignment_id == "10000000-0000-4000-8000-000000000002"
      )

    {:ok, listing, _} = live(build_conn(), "/incidents")
    assert incident_rows(listing) == [critical.id, warning.id]

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               critical.id,
               options(critical),
               "Investigating critical"
             )

    send(listing.pid, :tick)
    assert incident_rows(listing) == [warning.id, critical.id]
    assert has_element?(listing, "#preview-incident-health-#{critical.id}", "Acknowledged")
    assert has_element?(listing, "#preview-incident-health-#{critical.id}", "Critical")
    {:ok, reopened, _} = live(build_conn(), "/incidents")
    assert incident_rows(reopened) == [warning.id, critical.id]
    current = Repo.get!(Incident, critical.id)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               critical.id,
               Map.put(options(current), "mode", "end"),
               "Resume attention"
             )

    send(listing.pid, :tick)
    assert incident_rows(listing) == [critical.id, warning.id]
    refute has_element?(listing, "#preview-incident-health-#{critical.id}", "Acknowledged")
  end

  test "day durations accept a week and reject excessive durations without losing the draft" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    view |> form(@form, mode: "duration") |> render_change()
    before = Monitoring.now()

    view
    |> form(@form, amount: "7", unit: "days", note: "Replacement next week")
    |> render_submit()

    saved = Repo.get!(Incident, incident.id)
    assert saved.acknowledgement_mode == "until"
    assert DateTime.diff(saved.acknowledged_until, before) in 604_800..604_805
    view |> element("button", "Replace acknowledgement") |> render_click()
    view |> form(@form, mode: "duration") |> render_change()

    view
    |> form(@form, amount: "999999999", unit: "days", note: "Procurement lead time")
    |> render_submit()

    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "input[name=amount][value='999999999']")
    assert has_element?(view, "textarea[name=note]", "Procurement lead time")
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Replacement next week"
    before = Monitoring.now()

    view
    |> form(@form, amount: "339", unit: "hours", note: "Procurement lead time")
    |> render_submit()

    assert DateTime.diff(Repo.get!(Incident, incident.id).acknowledged_until, before) in 1_220_400..1_220_405
  end

  test "specific UTC expiry is exact and invalid or past times preserve proposed values" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    view |> form(@form, mode: "until") |> render_change()

    view
    |> form(@form, expires_at: "2003-01-02T15:04:00", note: "Maintenance coordination")
    |> render_submit()

    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "input[name=expires_at][value='2003-01-02T15:04:00']")
    assert has_element?(view, "textarea[name=note]", "Maintenance coordination")
    assert Repo.get!(Incident, incident.id).acknowledgement_mode == nil
    view |> form(@form, expires_at: "10000-01-01T00:00:00") |> render_submit()
    assert has_element?(view, "[role=alert]")
    expiry = Monitoring.now() |> DateTime.add(3 * 86_400) |> DateTime.truncate(:second)

    view
    |> form(@form, expires_at: Calendar.strftime(expiry, "%Y-%m-%dT%H:%M:%S"))
    |> render_submit()

    assert DateTime.compare(Repo.get!(Incident, incident.id).acknowledged_until, expiry) == :eq
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "UTC")
  end

  test "duration draft and original review recover through signed stack recovery without recording a control" do
    incident = open_incident()
    path = incident_path(incident)
    {:ok, view, _} = live(build_conn(), path)
    view |> form(@form, mode: "duration") |> render_change()

    view
    |> form(@form, amount: "30", unit: "days", note: "Waiting for reviewed change")
    |> render_change()

    snapshot = hidden(view, "#investigation-stack-recovery input[name=snapshot]")
    revision = hidden(view, @form <> " input[name=_revision]")
    send(view.pid, :tick)
    assert has_element?(view, "input[name=amount][value='30']")
    assert Repo.aggregate(Control, :count) == 0
    {:ok, recovered, _} = live(build_conn(), path)

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    send(recovered.pid, :tick)
    assert has_element?(recovered, "input[name=amount][value='30']")
    assert has_element?(recovered, "textarea[name=note]", "Waiting for reviewed change")
    assert hidden(recovered, @form <> " input[name=_revision]") == revision
    assert Repo.aggregate(Control, :count) == 0
    recovered |> form(@form) |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Waiting for reviewed change"
  end

  test "a concurrent control cannot be replaced or ended using an earlier review" do
    incident = open_incident()
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    view |> form(@form, note: "My proposed investigation") |> render_change()

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(incident.id, options(incident), "Newer control")

    view |> form(@form) |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Newer control"
    assert has_element?(view, "[role=alert]", "The incident changed")

    view
    |> with_target("#investigation-stack")
    |> render_hook("end_acknowledgement", %{"entity" => "health:#{incident.id}"})

    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    view |> element("button", "Replace acknowledgement") |> render_click()
    view |> element("button", "Review current incident") |> render_click()
    view |> form(@form, note: "My reviewed investigation") |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "My reviewed investigation"
    view |> element("button", "End acknowledgement") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
  end

  test "severity changes require renewed review and acknowledgements keep their original ceiling" do
    incident = open_incident("WARN")
    {:ok, view, _} = live(build_conn(), incident_path(incident))
    ingest(measurement("CRIT", 2))
    view |> form(@form, note: "Reviewing warning") |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_mode == nil
    assert has_element?(view, "[role=alert]", "The incident changed")
    view |> element("button", "Review current incident") |> render_click()
    view |> form(@form) |> render_submit()
    assert Repo.get!(Incident, incident.id).acknowledgement_ceiling == "CRIT"
    ingest(measurement("WARN", 3))
    ingest(measurement("CRIT", 4))
    send(view.pid, :tick)
    assert Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
  end

  test "historical controls without a recorded severity ceiling never invent one" do
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

  defp incident_path(incident), do: "/incidents/health/" <> incident.id <> "/full"

  defp incident_rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("tr[id^=preview-incident-health-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "preview-incident-health-", ""))
  end

  defp options(incident),
    do: %{
      "mode" => "until_incident_ends",
      "revision" => incident.acknowledgement_revision,
      "attention_revision" => incident.attention_revision
    }

  defp hidden(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("value")
      |> hd()
end
