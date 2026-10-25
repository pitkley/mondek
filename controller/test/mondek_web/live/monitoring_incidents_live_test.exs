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

  test "monitoring loss is a separate discoverable incident view with truthful empty and invalid states" do
    {:ok, health, _} = live(build_conn(), "/incidents")

    assert has_element?(
             health,
             "nav[aria-label='Incident views'] a[href='/monitoring-incidents']",
             "Monitoring loss"
           )

    {:ok, view, _} = live(build_conn(), "/monitoring-incidents")
    assert has_element?(view, "h1", "Incidents")
    assert has_element?(view, ".view-heading h2", "Monitoring loss")
    assert has_element?(view, "#monitoring-incident-list", "No matching monitoring incidents")
    assert has_element?(view, "#monitoring-loss-explanation", "healthy heartbeat alone does not")
    {:ok, invalid, _} = live(build_conn(), "/monitoring-incidents/not-an-id")
    assert has_element?(invalid, ".notice", "not in retained history")
  end

  test "affected results page independently of the incident list and link to the actual investigation" do
    record = incident(%{member_count: 27})
    for index <- 1..27, do: member(record, index)
    {:ok, view, _} = live(build_conn(), "/monitoring-incidents/#{record.id}?page=2")

    assert Enum.count(
             view
             |> element("#monitoring-members")
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query(".monitoring-loss-member")
           ) == 25

    view |> element("nav[aria-label='Affected results pages'] a", "Next") |> render_click()
    assert_patch(view, "/monitoring-incidents/#{record.id}?members_page=2&page=2")

    assert Enum.count(
             view
             |> element("#monitoring-members")
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query(".monitoring-loss-member")
           ) == 2

    assert has_element?(view, "a.back[href='/monitoring-incidents?page=2']")

    Repo.delete_all(MonitoringGap)
    stream_id = Ecto.UUID.generate()

    member(record, 1, %{
      "stream_id" => stream_id,
      "assignment_id" => "10000000-0000-4000-8000-000000000001",
      "knowledge" => "control_contact_overdue"
    })

    send(view.pid, :tick)

    assert has_element?(
             view,
             "#monitoring-members a[href^='/checks/#{stream_id}/diagnostics?']",
             "Investigate measurement"
           )

    assert has_element?(view, "#monitoring-members", "Control contact overdue")
    refute has_element?(view, "#monitoring-members a[href='/coverage/member-1']")
  end

  test "acknowledgement explicitly covers later scope losses and survives refresh without silently extending a timed acknowledgement" do
    record = incident()
    member(record, 1)
    {:ok, view, _} = live(build_conn(), "/monitoring-incidents/#{record.id}")
    assert has_element?(view, "#monitoring-ack-scope", "including results added later")

    view
    |> form("#monitoring-acknowledgement-form", %{note: "Waiting for network repair"})
    |> render_submit()

    assert Monitoring.acknowledgement_active?(Repo.get!(MonitoringIncident, record.id))

    assert has_element?(
             view,
             "#active-monitoring-acknowledgement",
             "Until this monitoring incident ends"
           )

    assert has_element?(view, "#monitoring-loss-summary", "Acknowledged")
    assert Repo.aggregate(Incident, :count) == 0
    view |> element("#end-monitoring-acknowledgement") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(MonitoringIncident, record.id))

    view |> form("#monitoring-acknowledgement-form", %{mode: "duration"}) |> render_change()

    view
    |> form("#monitoring-acknowledgement-form", %{
      hours: "720",
      note: "Long maintenance investigation"
    })
    |> render_submit()

    updated = Repo.get!(MonitoringIncident, record.id)
    assert DateTime.diff(updated.acknowledged_until, Monitoring.now()) > 29 * 86_400
    assert has_element?(view, "#active-monitoring-acknowledgement", "Until ")
    assert has_element?(view, "#monitoring-ack-mode option[value='until'][selected]")
  end

  test "concurrent control changes preserve an operator draft and require renewed review" do
    record = incident()
    member(record, 1)
    {:ok, view, _} = live(build_conn(), "/monitoring-incidents/#{record.id}")

    view
    |> form("#monitoring-acknowledgement-form", %{note: "My investigation note"})
    |> render_change()

    {:ok, _} =
      reviewed_monitoring_acknowledgement_fixture(
        record.id,
        %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
        "Another operator"
      )

    send(view.pid, :tick)
    assert has_element?(view, "#monitoring-acknowledgement-form button[disabled]")
    assert has_element?(view, "#monitoring-ack-note", "My investigation note")
    view |> element("#review-monitoring-acknowledgement") |> render_click()
    view |> form("#monitoring-acknowledgement-form") |> render_submit()

    assert Repo.get!(MonitoringIncident, record.id).acknowledgement_note ==
             "My investigation note"
  end

  test "restored visibility and withdrawn scope do not claim measured healthy recovery" do
    for reason <- ["monitoring_restored", "scope_withdrawn"] do
      record = incident(%{status: "closed", closed_at: Monitoring.now(), closure_reason: reason})
      {:ok, view, _} = live(build_conn(), "/monitoring-incidents/#{record.id}")
      refute has_element?(view, "#monitoring-acknowledgement-form")
      refute has_element?(view, "#monitoring-loss-summary .badge", "Healthy")

      if reason == "monitoring_restored" do
        assert has_element?(view, "#monitoring-loss-summary h2", "Monitoring restored")
        assert has_element?(view, "#monitoring-loss-summary", "not healthy targets")
      else
        assert has_element?(view, "#monitoring-loss-summary h2", "Closed")
        assert has_element?(view, "#monitoring-loss-summary", "administrative closure")
      end
    end
  end

  test "monitoring notification history and global delivery links use the correct incident kind" do
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

    {:ok, view, _} = live(build_conn(), "/monitoring-incidents/#{record.id}")
    assert has_element?(view, "#notification-#{work.id}", "held by acknowledgement")
    assert has_element?(view, "#notification-#{work.id}", "Failed or uncertain · HTTP 503")
    assert has_element?(view, "#monitoring-incident-prompts-incident-text", "monitoring_loss")
    {:ok, delivery, _} = live(build_conn(), "/notifications")

    assert has_element?(
             delivery,
             "#notification-row-#{work.id} a[href^='/notifications/#{work.id}']"
           )

    {:ok, notification, _} = live(build_conn(), "/notifications/#{work.id}")

    assert has_element?(
             notification,
             "#notification-#{work.id} a[href^='/monitoring-incidents/#{record.id}']"
           )
  end

  test "list sorting and counters put acknowledged episodes after unacknowledged pages" do
    old =
      incident(%{
        label: "Acknowledged oldest",
        acknowledgement_mode: "until_incident_ends",
        opened_at: DateTime.add(Monitoring.now(), -5000)
      })

    for index <- 1..26, do: incident(%{label: "Investigate #{index}"})
    {:ok, view, _} = live(build_conn(), "/monitoring-incidents")
    refute has_element?(view, "#monitoring-incident-#{old.id}")
    assert has_element?(view, "#monitoring-incident-list", "27 open · 26 unacknowledged")
    view |> element("nav[aria-label='Monitoring incident pages'] a", "Next") |> render_click()

    assert has_element?(
             view,
             "#monitoring-incident-#{old.id}.monitoring-loss-acknowledged",
             "Acknowledged"
           )
  end

  test "measurement investigation returns to its monitoring episode and originating delivery view" do
    connect()
    ingest(measurement("OK"))

    stream =
      Repo.one!(
        from s in Mondek.ResultStream,
          where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
      )

    record = incident()

    member(record, 1, %{
      "stream_id" => stream.id,
      "assignment_id" => "10000000-0000-4000-8000-000000000001"
    })

    work = occurrence(record)

    return_to =
      MondekWeb.NotificationNavigation.detail_path(
        work.id,
        "/notifications?notification_page=3&notification_status=all"
      )

    episode_path =
      "/monitoring-incidents/#{record.id}?" <> URI.encode_query(%{"return_to" => return_to})

    {:ok, view, _} = live(build_conn(), episode_path)

    assert has_element?(
             view,
             "a.back[href='#{episode_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("return_to")}']",
             "Back to notification delivery"
           )

    diagnostic_path =
      view
      |> element("#monitoring-members a")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    {:ok, diagnostic, _} = live(build_conn(), diagnostic_path)

    assert has_element?(
             diagnostic,
             "#investigation-back[href='#{episode_path}']",
             "Back to monitoring incident"
           )

    assert has_element?(diagnostic, "a", "View result")

    refute MondekWeb.MonitoringIncidentsLive.return_path(
             "https://other.invalid/monitoring-incidents/#{record.id}"
           )

    {:ok, untrusted, _} =
      live(
        build_conn(),
        "/monitoring-incidents/#{record.id}?" <>
          URI.encode_query(%{"return_to" => "//other.invalid/runners"})
      )

    assert has_element?(untrusted, "a.back[href='/monitoring-incidents']")
  end
end
