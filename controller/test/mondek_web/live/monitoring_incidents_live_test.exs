# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MonitoringIncidentsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{MonitoringIncident, MonitoringGap}
  @endpoint MondekWeb.Endpoint

  defp incident(extra \\ %{}) do
    source = "source-" <> Ecto.UUID.generate()
    now = Monitoring.now()

    attrs =
      Map.merge(
        %{
          scope_key: "coverage:" <> source,
          scope_kind: "coverage",
          source_id: source,
          label: "Expected node monitoring",
          opened_at: DateTime.add(now, -300),
          member_count: 1
        },
        extra
      )

    Repo.insert!(struct(MonitoringIncident, attrs))
  end

  defp member(incident, index, extra \\ %{}) do
    key = "member-#{index}"

    details =
      Map.merge(
        %{
          "key" => key,
          "label" => "Disk #{index}",
          "knowledge" => "no_selected_runner",
          "coverage_id" => key,
          "target" => %{"kind" => "host", "key" => "node-#{index}", "label" => "Node #{index}"},
          "environment" => "Production",
          "source_id" => incident.source_id
        },
        extra
      )

    Repo.insert!(%MonitoringGap{
      key: key,
      scope_key: incident.scope_key,
      details: details,
      since_at: incident.opened_at,
      ready_at: incident.opened_at
    })
  end

  defp occurrence(incident, extra \\ %{}) do
    id = Ecto.UUID.generate()

    attrs =
      Map.merge(
        %{
          id: id,
          monitoring_incident_id: incident.id,
          kind: "firing",
          attention_revision: 1,
          inserted_at: Monitoring.now(),
          destination: "http://127.0.0.1:58080/webhook",
          payload: %{
            "incident_type" => "monitoring_loss",
            "monitoring_incident_id" => incident.id,
            "occurrence_id" => id,
            "kind" => "firing",
            "member_count" => incident.member_count
          }
        },
        extra
      )

    Repo.insert!(struct(Occurrence, attrs))
  end

  test "monitoring loss uses the unified list and truthful empty and invalid states" do
    {:ok, empty, _} = live(build_conn(), "/incidents?type=loss")
    assert has_element?(empty, "h1", "Incidents")
    assert render(empty) =~ "No incidents match these filters"
    assert has_element?(empty, "#preview-chip-type", "Monitoring loss")
    {:ok, invalid, _} = live(build_conn(), "/incidents/loss/not-an-id/full")
    assert has_element?(invalid, "h1", "Incident unavailable")
  end

  test "affected results paginate independently and open actual result evidence in the stack" do
    record = incident(%{member_count: 27})
    for index <- 1..27, do: member(record, index)
    {:ok, view, _} = live(build_conn(), path(record) <> "?page=2")
    assert count(view, "#preview-loss-evidence .preview-incident-evidence > :is(h3,h4)") == 25
    view |> element("nav[aria-label='Affected result pages'] a", "Next") |> render_click()
    assert count(view, "#preview-loss-evidence .preview-incident-evidence > :is(h3,h4)") == 2
    assert render(view) =~ "member_page=2"
    Repo.delete_all(MonitoringGap)
    connect()
    ingest(measurement("OK"))

    stream =
      Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

    member(record, 1, %{
      "stream_id" => stream.id,
      "assignment_id" => stream.assignment_id,
      "knowledge" => "control_contact_overdue"
    })

    send(view.pid, :tick)
    assert has_element?(view, "#preview-loss-evidence", "Runner contact overdue")
    view |> element("#preview-loss-evidence a", "View latest check result") |> render_click()
    assert has_element?(view, "#overview-panel .preview-result-measurement", "Healthy")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#preview-loss-evidence", "Runner contact overdue")
  end

  test "acknowledgement covers later scope losses and refresh never extends its timed expiry" do
    record = incident()
    member(record, 1)
    {:ok, view, _} = live(build_conn(), path(record))
    assert has_element?(view, "#preview-incident-ack-form", "including results added later")

    view
    |> form("#preview-incident-ack-form", note: "Waiting for network repair")
    |> render_submit()

    assert Monitoring.acknowledgement_active?(Repo.get!(MonitoringIncident, record.id))
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "Incident ends")
    assert Repo.aggregate(Incident, :count) == 0
    view |> element("button", "End acknowledgement") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(MonitoringIncident, record.id))
    view |> form("#preview-incident-ack-form", mode: "duration") |> render_change()

    view
    |> form("#preview-incident-ack-form", amount: "30", unit: "days", note: "Long investigation")
    |> render_submit()

    saved = Repo.get!(MonitoringIncident, record.id)
    assert DateTime.diff(saved.acknowledged_until, Monitoring.now()) > 29 * 86_400
    member(record, 2)
    send(view.pid, :tick)
    assert Repo.get!(MonitoringIncident, record.id).acknowledged_until == saved.acknowledged_until
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "UTC")
  end

  test "concurrent controls preserve a draft and require renewed explicit review" do
    record = incident()
    member(record, 1)
    {:ok, view, _} = live(build_conn(), path(record))
    view |> form("#preview-incident-ack-form", note: "My investigation note") |> render_change()

    {:ok, _} =
      reviewed_monitoring_acknowledgement_fixture(
        record.id,
        %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
        "Another operator"
      )

    view |> form("#preview-incident-ack-form") |> render_submit()
    assert has_element?(view, "[role=alert]", "The incident changed")
    assert Repo.get!(MonitoringIncident, record.id).acknowledgement_note == "Another operator"
    view |> element("button", "Replace acknowledgement") |> render_click()
    view |> element("button", "Review current incident") |> render_click()

    view
    |> form("#preview-incident-ack-form", note: "My reviewed investigation")
    |> render_submit()

    assert Repo.get!(MonitoringIncident, record.id).acknowledgement_note ==
             "My reviewed investigation"
  end

  test "restored monitoring and withdrawn scope stay distinct from measured target recovery" do
    for reason <- ["monitoring_restored", "scope_withdrawn"] do
      record = incident(%{status: "closed", closed_at: Monitoring.now(), closure_reason: reason})
      {:ok, view, _} = live(build_conn(), path(record))
      refute has_element?(view, "#preview-incident-ack-form")
      refute has_element?(view, "#preview-loss-evidence", "Healthy")

      if reason == "monitoring_restored" do
        assert has_element?(view, "#preview-loss-evidence", "Monitoring was restored")
      else
        assert has_element?(view, "#preview-history", "Scope withdrawn")
        refute has_element?(view, "#preview-loss-evidence", "Monitoring was restored")
      end
    end
  end

  test "monitoring delivery history and global notification use the loss identity" do
    record = incident()
    member(record, 1)
    work = occurrence(record)

    Repo.insert!(%Attempt{
      occurrence_id: work.id,
      status: "failed_or_ambiguous",
      started_at: Monitoring.now(),
      finished_at: Monitoring.now(),
      http_status: 503,
      error: "Receiver rejected delivery"
    })

    {:ok, _} =
      reviewed_monitoring_acknowledgement_fixture(
        record.id,
        %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
        "Investigating"
      )

    {:ok, view, _} = live(build_conn(), path(record))
    assert render(view) =~ "Waiting for Acknowledgement"
    assert render(view) =~ "HTTP 503"
    {:ok, notification, _} = live(build_conn(), "/notifications/#{work.id}/full")
    notification |> element("a", "View monitoring loss") |> render_click()
    assert has_element?(notification, "#overview-panel #preview-loss-evidence")
    refute has_element?(notification, "#overview-panel #preview-health-evidence")
  end

  test "priority pages put acknowledged episodes after outstanding losses" do
    old =
      incident(%{
        label: "Acknowledged oldest",
        acknowledgement_mode: "until_incident_ends",
        opened_at: DateTime.add(Monitoring.now(), -5000)
      })

    for index <- 1..26, do: incident(%{label: "Investigate #{index}"})
    {:ok, view, _} = live(build_conn(), "/incidents?type=loss")
    refute has_element?(view, "#preview-incident-loss-#{old.id}")
    view |> element("nav[aria-label='Incident pages'] a", "Next") |> render_click()
    assert has_element?(view, "#preview-incident-loss-#{old.id}", "Acknowledged")
  end

  test "a monitoring investigation retains the originating delivery and rejects external returns" do
    connect()
    ingest(measurement("OK"))

    stream =
      Repo.get_by!(Mondek.ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

    record = incident()
    member(record, 1, %{"stream_id" => stream.id, "assignment_id" => stream.assignment_id})
    work = occurrence(record)
    {:ok, view, _} = live(build_conn(), "/notifications/#{work.id}/full")
    view |> element("a", "View monitoring loss") |> render_click()
    assert has_element?(view, "#overview-panel #preview-loss-evidence")
    view |> element("#overview-panel a", "View latest check result") |> render_click()
    assert has_element?(view, "#overview-panel .preview-result-measurement")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#overview-panel #preview-loss-evidence")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert has_element?(view, "#notification-delivery")
    refute MondekWeb.BrowserNavigation.return_path("https://other.invalid" <> path(record))
    {:ok, safe, _} = live(build_conn(), path(record) <> "?return_to=//other.invalid/runners")
    refute render(safe) =~ "href=\"//other.invalid"
  end

  defp path(record), do: "/incidents/loss/#{record.id}/full"

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
end
