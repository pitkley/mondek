# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GroupedIncidentsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{ConditionIncident, Control}
  alias MondekWeb.IncidentLive

  @endpoint MondekWeb.Endpoint
  @impact %{"key" => "writes-blocked", "label" => "Writes blocked"}

  test "a new impact between acknowledgement commit and refresh never reports an active hold" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    owner = self()
    handler = "grouped-acknowledgement-commit-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        socket = incident_socket(group.id)
        worker = self()
        Process.put(handler, true)

        # Pause after the actual acknowledgement COMMIT, before its callback can
        # refresh. The disconnected socket has no automatic tick to race this gate.
        :ok =
          :telemetry.attach(
            handler,
            [:mondek, :repo, :query],
            fn _, _, metadata, _ ->
              if self() == worker && metadata.query == "commit" && Process.get(handler) do
                Process.put(handler, false)
                send(owner, {:acknowledgement_committed, self()})

                receive do
                  :continue_acknowledgement -> :ok
                after
                  5_000 -> raise "acknowledgement commit gate was not released"
                end
              end
            end,
            nil
          )

        try do
          IncidentLive.handle_event(
            "acknowledge",
            Map.put(
              socket.assigns.acknowledgement_draft,
              "note",
              "Reviewed before blocked writes"
            ),
            socket
          )
        after
          :telemetry.detach(handler)
        end
      end)

    assert_receive {:acknowledgement_committed, worker}, 5_000
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
    sample(check, "CRIT", 2, [@impact])
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
    send(worker, :continue_acknowledgement)
    assert {:noreply, socket} = Task.await(task, 5_000)
    assert socket.assigns.flash["info"] =~ "recorded but is no longer active"
    refute socket.assigns.flash["info"] =~ "Failure notifications are held"
    refute socket.assigns.incident_inspection["incident"]["acknowledgement_active"]
  end

  test "an inactive first inspection removes stale acknowledgement success but preserves unrelated feedback" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)

    socket =
      incident_socket(group.id, %{
        "info" => "Acknowledgement recorded. Failure notifications are held."
      })

    refute Map.has_key?(socket.assigns.flash, "info")
    other = incident_socket(group.id, %{"info" => "A notification retry was requested."})
    assert other.assigns.flash["info"] == "A notification retry was requested."
  end

  test "one contributing result, runner and notification use singular summary wording" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, listing, _} = live(build_conn(), "/incidents?search=Result+1")
    assert has_element?(listing, "tbody tr", "1 failing result · 1 runner")
    assert has_element?(listing, "tbody tr", "Matches 1 of 1 contributing result.")
    refute has_element?(listing, "tbody tr", "1 failing results")
    refute has_element?(listing, "tbody tr", "1 runners")

    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    assert has_element?(view, "#shared-incident-heading", "1 currently failing result ·")
    assert has_element?(view, "#condition-coverage", "1 of 1 failing result has no active hold")
    assert has_element?(view, "#incident-delivery-summary .badge", "1 notification")
    refute has_element?(view, "#incident-delivery-summary .badge", "1 notifications")
    assert has_element?(view, "#contributions-top", "1 of 1 entry")
    refute has_element?(view, "#contributions-bottom")

    occurrence = Repo.one!(from o in Occurrence, where: o.condition_incident_id == ^group.id)
    Monitoring.change(occurrence, %{status: "delivered"})
    send(view.pid, :tick)
    assert has_element?(view, "#condition-notifications-empty", "1 recorded notification.")
  end

  test "notifications expose their requested impact and severity and attempts link to the shared parent" do
    [check] = inventory(1)
    sample(check, "CRIT", 1, [@impact])
    group = Repo.one!(ConditionIncident)
    notices = Repo.all(from o in Occurrence, where: o.condition_incident_id == ^group.id)
    impact = Enum.find(notices, &(&1.payload["requested_fact"]["key"] == "writes-blocked"))
    critical = Enum.find(notices, &(&1.payload["requested_fact"]["key"] == "CRIT"))
    assert impact.incident_id == nil

    Repo.insert!(%Attempt{
      occurrence_id: impact.id,
      status: "failed_or_ambiguous",
      http_status: 503,
      started_at: Monitoring.now(),
      finished_at: Monitoring.now()
    })

    {:ok, shared, _} = live(build_conn(), "/incidents/#{group.id}")
    {:ok, delivery, _} = live(build_conn(), "/notifications")

    for {notice, label} <- [{impact, "Writes blocked"}, {critical, "Critical severity"}] do
      assert has_element?(
               shared,
               "#notification-#{notice.id} .notification-requested-scope",
               label
             )

      assert has_element?(
               delivery,
               "#notification-row-#{notice.id} a[href^='/notifications/#{notice.id}']"
             )

      detail_path = MondekWeb.NotificationNavigation.detail_path(notice.id, "/notifications")
      {:ok, detail, _} = live(build_conn(), detail_path)

      assert has_element?(
               detail,
               "#notification-#{notice.id} .notification-requested-scope",
               label
             )

      assert has_element?(
               detail,
               "#notification-#{notice.id} a[href='/incidents/#{group.id}?#{URI.encode_query(%{"return_to" => detail_path})}']",
               "Storage pressure"
             )

      refute has_element?(detail, "a[href='/incidents/#notification-#{notice.id}']")
      refute has_element?(detail, "#notification-#{notice.id} a", "Storage pressure · pressure")
    end

    assert has_element?(
             shared,
             "a[href='/incidents/#{group.id}?notification_id=#{impact.id}#notification-#{impact.id}']",
             "Storage pressure · Writes blocked"
           )

    assert has_element?(shared, ".contribution-impacts", "Writes blocked")
    Monitoring.change(impact, %{status: "delivered"})
    Monitoring.change(critical, %{status: "delivered"})
    {:ok, empty, _} = live(build_conn(), "/incidents/#{group.id}")

    assert has_element?(
             empty,
             "#condition-notifications-empty",
             "No notifications match this status"
           )

    refute has_element?(empty, "#incident-occurrences", "No notifications yet")

    empty
    |> element("#condition-notifications-empty a", "View all notifications")
    |> render_click()

    assert_patch(empty, "/incidents/#{group.id}?notification_status=all")
    assert has_element?(empty, "#notification-#{impact.id}")

    {:ok, focused, _} = live(build_conn(), "/incidents/#{group.id}?notification_id=#{impact.id}")
    assert has_element?(focused, "#notification-#{impact.id}", "Receiver accepted")
    assert has_element?(focused, "#condition-notification-status option[value='all'][selected]")

    focused
    |> form("#condition-notification-filter", notification_status: "pending")
    |> render_change()

    query = focused |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["notification_status"] == "pending"
    refute Map.has_key?(query, "notification_id")
  end

  test "active acknowledgement uses friendly impact names and falls back to the reviewed key" do
    [check] = inventory(1)
    sample(check, "CRIT", 1, [@impact])
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    view |> form("#acknowledgement-form", note: "Investigating blocked writes") |> render_submit()
    assert has_element?(view, "#acknowledged-impacts", "Impact scope: Writes blocked.")

    sample(check, "CRIT", 2)
    send(view.pid, :tick)
    assert has_element?(view, "#active-acknowledgement", "Investigating blocked writes")
    assert has_element?(view, "#condition-impacts", "No named impacts")
    assert has_element?(view, "#acknowledged-impacts", "Impact scope: writes-blocked.")
    assert Repo.get!(ConditionIncident, group.id).acknowledgement_impacts == ["writes-blocked"]
  end

  test "shared incident offers direct collection investigation only for missing evidence" do
    [check] = inventory(1)
    report = sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    contribution = Repo.one!(Incident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    refute has_element?(view, "#investigate-contribution-#{contribution.id}")

    failed =
      Map.merge(report, %{
        "id" => Ecto.UUID.generate(),
        "sequence" => 2,
        "complete" => false,
        "diagnostic" => "Datasource timed out",
        "results" => [
          %{"key" => "pressure", "health" => "UNKNOWN", "summary" => "Collection failed"}
        ]
      })

    assert disposition(ingest(failed, Monitoring.now())) == "current"
    send(view.pid, :tick)

    {:ok, investigation, _} =
      view
      |> element("#investigate-contribution-#{contribution.id}")
      |> render_click()
      |> follow_redirect(build_conn())

    assert has_element?(
             investigation,
             "#investigation-back[href='/incidents/#{group.id}']",
             "Back to incident"
           )

    assert has_element?(investigation, "#latest-execution", "Datasource timed out")
  end

  test "measurement investigation follows shared notification ownership and retains result scope" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    contribution = Repo.one!(Incident)
    occurrence = Repo.one!(from o in Occurrence, where: o.condition_incident_id == ^group.id)
    Monitoring.change(occurrence, %{status: "delivered"})

    inventory_path =
      %{"health" => "CRIT", "view" => "list"}
      |> MondekWeb.CheckInventory.normalize()
      |> MondekWeb.CheckInventory.path()

    result_path =
      "/checks/#{contribution.stream_id}?" <>
        URI.encode_query(%{"return_to" => inventory_path})

    investigation_path =
      "/checks/#{contribution.stream_id}/diagnostics?" <>
        URI.encode_query(%{"return_to" => inventory_path})

    {:ok, investigation, _} = live(build_conn(), investigation_path)

    [notification_path] =
      investigation
      |> element("#notification-boundary a[href^='/incidents/']")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    uri = URI.parse(notification_path)
    assert uri.path == "/incidents/#{group.id}"
    refute uri.path == "/incidents/#{contribution.id}"
    assert uri.fragment == "incident-occurrences"

    assert URI.decode_query(uri.query) == %{
             "notification_status" => "all",
             "return_to" => investigation_path
           }

    assert has_element?(investigation, "#notification-boundary a", "CRIT")

    prompt =
      investigation
      |> element("#collection-agent-prompts-collection-text")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("textarea")
      |> LazyHTML.text()

    assert prompt =~ ~s("target_id":"volume-1")
    assert prompt =~ ~s("target_kind":"volume")

    {:ok, shared, _} = live(build_conn(), notification_path)
    assert has_element?(shared, "#notification-#{occurrence.id}", "Receiver accepted")
    assert has_element?(shared, "a.back[href='#{investigation_path}']", "Back to investigation")

    {:ok, returned, _} = live(build_conn(), investigation_path)
    assert has_element?(returned, "#investigation-back[href='#{result_path}']")

    {:ok, result, _} = live(build_conn(), result_path)
    assert has_element?(result, "a.back[href='#{inventory_path}']")
  end

  test "notification investigation preserves the original shared incident filters within a bounded return chain" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    contribution = Repo.one!(Incident)
    inventory_path = "/incidents?search=Storage"

    original_incident =
      "/incidents/#{group.id}?" <>
        URI.encode_query(%{
          "state" => "failing",
          "page" => "2",
          "notification_status" => "delivered",
          "return_to" => inventory_path
        })

    result_path =
      "/checks/#{contribution.stream_id}?" <>
        URI.encode_query(%{"return_to" => original_incident})

    investigation_path =
      "/checks/#{contribution.stream_id}/diagnostics?" <>
        URI.encode_query(%{"return_to" => original_incident})

    {:ok, investigation, _} = live(build_conn(), investigation_path)
    notification_path = link_href(investigation, "#notification-boundary a[href^='/incidents/']")
    {:ok, notifications, _} = live(build_conn(), notification_path)
    assert has_element?(notifications, "a.back[href='#{investigation_path}']")

    {:ok, returned, _} = live(build_conn(), link_href(notifications, "a.back"))

    assert has_element?(
             returned,
             "#investigation-back[href='#{original_incident}']",
             "Back to incident"
           )

    assert has_element?(returned, "a[href='#{result_path}']", "View result")
    {:ok, result, _} = live(build_conn(), result_path)
    assert has_element?(result, "a.back[href='#{original_incident}']")

    # A second nested incident must be dropped, preserving only the allowed
    # diagnostics -> one incident -> inventory shape even for valid local IDs.
    too_deep_incident =
      "/incidents/#{group.id}?" <>
        URI.encode_query(%{"state" => "failing", "return_to" => original_incident})

    too_deep_investigation =
      "/checks/#{contribution.stream_id}/diagnostics?" <>
        URI.encode_query(%{"return_to" => too_deep_incident})

    {:ok, bounded, _} =
      live(
        build_conn(),
        "/incidents/#{group.id}?" <>
          URI.encode_query(%{"return_to" => too_deep_investigation})
      )

    allowed_incident = "/incidents/#{group.id}?state=failing"

    allowed_investigation =
      "/checks/#{contribution.stream_id}/diagnostics?" <>
        URI.encode_query(%{"return_to" => allowed_incident})

    assert link_href(bounded, "a.back") == allowed_investigation
  end

  test "the filtered list retains one whole incident and the detail has no invented owner" do
    [one, two] = inventory(2)
    sample(one, "WARN", 1)
    sample(two, "CRIT", 1)
    group = Repo.one!(ConditionIncident)

    {:ok, listing, _} = live(build_conn(), "/incidents?search=Result+1")
    assert has_element?(listing, "tbody tr", "Storage pressure")
    assert has_element?(listing, "tbody tr", "Matches 1 of 2 contributing results")
    assert has_element?(listing, "tbody tr", "Critical")

    assert listing
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("tbody tr")
           |> Enum.count() ==
             1

    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    assert has_element?(view, "#shared-incident-heading h1", "Storage pressure")
    assert has_element?(view, "#shared-incident-heading", "2 currently failing results")
    assert has_element?(view, "#incident-environment", "production")
    assert has_element?(view, "#condition-status", "1 critical · 1 warning")
    assert has_element?(view, "#condition-coverage", "2 of 2 failing results have no active hold")
    assert has_element?(view, "#condition-contributors", "Result 1")
    assert has_element?(view, "#condition-contributors", "Result 2")

    assert has_element?(
             view,
             "#condition-maintenance a[href='/maintenance/new']",
             "Choose maintenance scope"
           )

    refute has_element?(view, "#incident-check-now")
    refute has_element?(view, "#shared-incident-heading", "Runner:")
    assert has_element?(view, "#condition-evidence", "result excerpts")
    assert has_element?(view, "#incident-summary > #condition-status")

    assert has_element?(
             view,
             "#incident-summary > .shared-contributors > #condition-contributors"
           )

    assert has_element?(view, "#incident-history #incident-delivery-summary")
    assert has_element?(view, "#incident-history #incident-agent-prompts")

    assert has_element?(
             view,
             "#incident-acknowledgement-shortcut[href='#incident-acknowledgement']"
           )

    assert has_element?(view, "#incident-acknowledgement[tabindex='-1']")

    sections =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(".shared-incident-layout > [id]")
      |> LazyHTML.attribute("id")

    assert sections == ["incident-summary", "incident-controls", "incident-history"]

    occurrence =
      Repo.one!(from o in Occurrence, where: o.condition_incident_id == ^group.id, limit: 1)

    {:ok, delivery, _} = live(build_conn(), "/notifications/#{occurrence.id}")

    assert has_element?(
             delivery,
             "#notification-#{occurrence.id} a[href^='/incidents/#{group.id}']",
             "Storage pressure"
           )
  end

  test "late equivalent corroboration preserves shared acknowledgement and a draft; new impact requires review" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    view |> form("#acknowledgement-form", note: "Investigating storage") |> render_submit()
    assert has_element?(view, ".flash[role='status']", "Acknowledgement recorded.")

    view
    |> form("#acknowledgement-form", note: "Draft for tomorrow", mode: "duration")
    |> render_change()

    revision = hidden(view, "_revision")
    attention = hidden(view, "_attention_revision")

    sample(two, "CRIT", 1)
    send(view.pid, :tick)
    assert has_element?(view, "#active-acknowledgement", "Investigating storage")
    assert has_element?(view, "#ack-note", "Draft for tomorrow")
    assert has_element?(view, "#condition-coverage", "2 covered by the incident acknowledgement")
    assert hidden(view, "_revision") == revision
    assert hidden(view, "_attention_revision") == attention
    refute has_element?(view, "#review-acknowledgement")
    assert has_element?(view, ".flash[role='status']", "Acknowledgement recorded.")
    assert Repo.get_by!(Incident, assignment_id: two.id).acknowledgement_mode == nil

    sample(two, "CRIT", 2, [@impact])
    send(view.pid, :tick)
    refute has_element?(view, "#active-acknowledgement")
    refute has_element?(view, ".flash", "Acknowledgement recorded.")
    assert has_element?(view, "#condition-impacts", "Writes blocked")
    assert has_element?(view, "#review-acknowledgement")
    assert has_element?(view, "#acknowledgement-form button[disabled]")
    assert has_element?(view, "#ack-note", "Draft for tomorrow")
    refute has_element?(view, "#ack-reviewed-impacts")
    view |> element("#review-acknowledgement") |> render_click()
    assert has_element?(view, "#ack-reviewed-impacts", "Writes blocked")
    assert has_element?(view, "#ack-note", "Draft for tomorrow")
    view |> form("#acknowledgement-form") |> render_submit()
    assert Repo.get!(ConditionIncident, group.id).acknowledgement_impacts == ["writes-blocked"]
  end

  test "partial maintenance and unavailable collection remain independent of the shared control" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "WARN", 1)
    group = Repo.one!(ConditionIncident)
    assert {:ok, _} = reviewed_maintenance_fixture(one.id, 3600, "Replace this disk")
    sample(one, "UNKNOWN", 2)
    {:ok, view, _} = live(build_conn(), "/incidents/#{group.id}")
    first = Repo.get_by!(Incident, assignment_id: one.id)
    second = Repo.get_by!(Incident, assignment_id: two.id)
    assert has_element?(view, "#condition-coverage", "1 of 2 failing results has no active hold")
    assert has_element?(view, "#contribution-#{first.id}", "Collection is unavailable")
    assert has_element?(view, "#contribution-#{first.id}", "Measured CRIT")
    assert has_element?(view, "#contribution-#{first.id}", "Maintenance:")
    assert has_element?(view, "#contribution-#{second.id}", "No active notification hold")
    view |> form("#acknowledgement-form", note: "Inspect both observations") |> render_submit()
    assert has_element?(view, "#condition-coverage", "0 of 2 failing results have no active hold")
    view |> element("#end-acknowledgement") |> render_click()
    assert has_element?(view, "#condition-coverage", "1 of 2 failing results has no active hold")
    assert has_element?(view, "#contribution-#{first.id}", "Maintenance:")
  end

  test "paging, filtering, ticks and form recovery preserve reviewed acknowledgement settings" do
    rows = inventory(26)
    Enum.each(rows, &sample(&1, "CRIT", 1))
    group = Repo.one!(ConditionIncident)
    inventory_return = "/incidents?search=Storage&status=open"
    path = "/incidents/#{group.id}?" <> URI.encode_query(%{"return_to" => inventory_return})
    {:ok, view, _} = live(build_conn(), path)

    navigation_names =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#condition-contributors nav.pagination")
      |> LazyHTML.attribute("aria-label")

    assert navigation_names == [
             "Contributions pagination (top)",
             "Contributions pagination (bottom)"
           ]

    assert has_element?(view, "#contributions-top a", "Next")
    assert has_element?(view, "#contributions-bottom a", "Next")

    view
    |> form("#acknowledgement-form", note: "Review across pages", mode: "duration")
    |> render_change()

    view |> form("#acknowledgement-form", seconds: "custom") |> render_change()
    view |> form("#acknowledgement-form", days: "30", hours: "6") |> render_change()
    recovered = recovery(view)
    view |> element("#contributions-top a", "Next") |> render_click()
    page_path = assert_patch(view)
    assert URI.decode_query(URI.parse(page_path).query)["return_to"] == inventory_return
    assert has_element?(view, "#contributions-top", "Page 2 of 2")
    assert has_element?(view, "#condition-coverage", "26 of 26")
    assert has_element?(view, "#ack-note", "Review across pages")
    assert has_element?(view, "#ack-days[value='30']")
    view |> form("#condition-notification-filter", notification_status: "all") |> render_change()
    filtered_path = assert_patch(view)
    assert URI.decode_query(URI.parse(filtered_path).query)["page"] == "2"
    send(view.pid, :tick)
    assert has_element?(view, "#ack-hours[value='6']")
    assert Repo.aggregate(Control, :count) == 0

    {:ok, reconnected, _} = live(build_conn(), filtered_path)
    reconnected |> render_change("edit_acknowledgement", recovered)

    reconnected
    |> render_change("condition_notification_filter", %{"notification_status" => "all"})

    assert has_element?(reconnected, "#contributions-top", "Page 2 of 2")
    assert has_element?(reconnected, "#ack-note", "Review across pages")
    assert has_element?(reconnected, "#ack-days[value='30']")
    assert has_element?(reconnected, "#ack-hours[value='6']")
    assert hidden(reconnected, "_attention_revision") == recovered["_attention_revision"]
    assert Repo.aggregate(Control, :count) == 0

    result_href =
      reconnected
      |> element(".condition-row-actions a", "View result now")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    {:ok, result, _} = live(build_conn(), result_href)
    assert has_element?(result, "a.back[href='#{filtered_path}']", "Back to incident")
    assert has_element?(result, "a[href='#{filtered_path}']", "Inspect incident")

    # The only unheld WARN sits after 25 maintained CRIT results in the normal
    # urgency order. Its navigation must use the whole-group count, not page 2.
    for check <- Enum.take(rows, 25),
        do:
          assert(
            {:ok, _} = reviewed_maintenance_fixture(check.id, 3600, "Work on critical storage")
          )

    sample(List.last(rows), "WARN", 2)
    send(reconnected.pid, :tick)

    assert has_element?(
             reconnected,
             "#condition-coverage",
             "1 of 26 failing results has no active hold"
           )

    reconnected |> element("#inspect-uncovered-results") |> render_click()
    assert_patch(reconnected)
    assert has_element?(reconnected, "#contributions-top", "1 of 1 entry")
    assert has_element?(reconnected, "#condition-contributors", "Result 26")
    refute has_element?(reconnected, ".condition-contribution", "Result 1")
    assert has_element?(reconnected, "#ack-note", "Review across pages")
    assert has_element?(reconnected, "#condition-status", "25 critical · 1 warning")
  end

  test "individual contribution evidence and notification navigation preserve their distinct owners" do
    [check] = inventory(1)
    opening = sample(check, "CRIT", 1)
    latest = sample(check, "CRIT", 2)
    contribution = Repo.one!(Incident)
    group = Repo.one!(ConditionIncident)
    occurrence = Repo.one!(Occurrence)
    Monitoring.change(occurrence, %{status: "delivered"})

    parent_filters = %{
      "state" => "all",
      "page" => "1",
      "notification_status" => "unresolved",
      "notification_page" => "4",
      "notification_id" => occurrence.id,
      "return_to" => "/incidents?search=Storage"
    }

    parent_path = "/incidents/#{group.id}?" <> URI.encode_query(parent_filters)

    {:ok, view, _} =
      live(
        build_conn(),
        "/incidents/#{contribution.id}?" <> URI.encode_query(%{"return_to" => parent_path})
      )

    assert has_element?(
             view,
             "#incident-measurements h2",
             "Contribution measurement history"
           )

    assert has_element?(
             view,
             "#incident-measurements #evidence-#{opening["id"]}",
             "Measured CRIT"
           )

    assert has_element?(view, "#incident-measurements #evidence-#{latest["id"]}", "Measured CRIT")
    refute has_element?(view, "#incident-measurements .empty")

    assert has_element?(
             view,
             "#recent-incident-evidence .empty",
             "No additional retained executions"
           )

    # Grouped references are protected by foreign keys. Exercise the missing
    # inspection projection at the render boundary without weakening retention.
    socket = incident_socket(contribution.id)

    absent =
      render_component(
        &IncidentLive.render/1,
        Map.update!(socket.assigns, :incident_inspection, &Map.put(&1, "evidence", []))
      )
      |> LazyHTML.from_document()
      |> LazyHTML.query("#incident-measurements")
      |> LazyHTML.text()

    assert absent =~ "No retained measurements for this contribution"
    assert absent =~ "No linked measurement evidence is retained for this contribution."
    refute absent =~ "Scheduled reports will appear"
    assert has_element?(view, "#incident-occurrences h2", "Shared notification history")

    assert has_element?(
             view,
             "#incident-occurrences",
             "Notifications and delivery attempts are recorded on the shared incident."
           )

    refute has_element?(view, "#incident-occurrences", "No notifications yet")
    refute has_element?(view, "#incident-attempts")

    href =
      view
      |> element("#contribution-shared-notifications")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    destination = URI.parse(href)
    assert destination.path == "/incidents/#{group.id}"
    assert destination.fragment == "incident-occurrences"

    assert URI.decode_query(destination.query) ==
             parent_filters
             |> Map.drop(["notification_page", "notification_id"])
             |> Map.put("notification_status", "all")

    {:ok, shared, _} = live(build_conn(), href)
    assert has_element?(shared, "#notification-#{occurrence.id}", "Receiver accepted")
    assert has_element?(shared, "#condition-notification-filter option[value='all'][selected]")
  end

  test "closed contribution history and parent links remain attached to their original incident" do
    [one, two] = inventory(2)
    opening = sample(one, "CRIT", 1)
    sample(two, "OK", 1)
    original = Repo.one!(ConditionIncident)
    individual = Repo.one!(Incident)
    {:ok, view, _} = live(build_conn(), "/incidents/#{original.id}")
    assert has_element?(view, "#condition-other-results", "Last confirmed healthy evidence (1)")
    sample(two, "UNKNOWN", 2)
    send(view.pid, :tick)

    assert has_element?(
             view,
             "#condition-other-results",
             "Collection is unavailable; the last confirmed healthy measurement is retained"
           )

    assert has_element?(view, "#condition-other-results", "Measured OK")
    recovery = sample(one, "OK", 2)
    recurrence = sample(one, "CRIT", 3)
    replacement = Repo.one!(from g in ConditionIncident, where: g.status == "open")
    send(view.pid, :tick)
    assert has_element?(view, "#condition-status", "Incident outcome")
    assert has_element?(view, "#contribution-#{individual.id}", "Measured OK")
    assert has_element?(view, "#contribution-#{individual.id}", "Recovered")
    assert has_element?(view, "#contribution-#{individual.id} .resource-name", "Last failure:")
    refute has_element?(view, "#contribution-#{individual.id}", "Measured CRIT")
    refute has_element?(view, "#acknowledgement-form")
    {:ok, contribution, _} = live(build_conn(), "/incidents/#{individual.id}")
    assert has_element?(contribution, "#contribution-parent a[href='/incidents/#{original.id}']")

    assert has_element?(
             contribution,
             "#incident-measurements #evidence-#{opening["id"]}",
             "Measured CRIT"
           )

    assert has_element?(
             contribution,
             "#incident-measurements #evidence-#{recovery["id"]}",
             "Measured OK"
           )

    refute has_element?(contribution, "#incident-measurements #evidence-#{recurrence["id"]}")
    assert has_element?(contribution, "#recent-incident-evidence #evidence-#{recurrence["id"]}")
    assert has_element?(contribution, "#incident-check-now", "Measured CRIT")

    assert has_element?(
             contribution,
             "#contribution-shared-notifications[href='/incidents/#{original.id}?notification_status=all#incident-occurrences']"
           )

    refute has_element?(
             contribution,
             "#contribution-parent a[href='/incidents/#{replacement.id}']"
           )

    {:ok, current, _} = live(build_conn(), "/checks/#{individual.stream_id}")
    assert has_element?(current, "a[href='/incidents/#{replacement.id}']", "Inspect incident")
  end

  test "individual acknowledgement stays explicitly scoped and does not acknowledge the group" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    individual = Repo.get_by!(Incident, assignment_id: one.id)
    {:ok, view, _} = live(build_conn(), "/incidents/#{individual.id}")

    assert has_element?(
             view,
             "#contribution-parent",
             "Controls on this page apply to this result only"
           )

    assert has_element?(view, "#acknowledgement-form button", "Acknowledge this result only")
    assert has_element?(view, "#incident-acknowledgement-heading", "Individual acknowledgement")

    assert has_element?(
             view,
             "#incident-acknowledgement",
             "No individual acknowledgement is active"
           )

    assert has_element?(
             view,
             "#incident-acknowledgement-shortcut",
             "Acknowledge this result only"
           )

    assert has_element?(
             view,
             "#ack-mode option[value='until_incident_ends']",
             "This contribution ends"
           )

    assert has_element?(
             view,
             "#individual-acknowledgement-scope",
             "A shared incident acknowledgement may still hold notifications"
           )

    view
    |> form("#acknowledgement-form", note: "Investigating only this observer")
    |> render_submit()

    assert Repo.get!(Incident, individual.id).acknowledgement_mode == "until_incident_ends"
    assert Repo.get!(ConditionIncident, group.id).acknowledgement_mode == nil

    assert has_element?(
             view,
             "#acknowledgement-lifetime",
             "Until this contribution ends; no scheduled expiry."
           )

    assert has_element?(
             view,
             "#incident-acknowledgement-shortcut",
             "Review individual acknowledgement"
           )

    assert has_element?(
             view,
             ".flash",
             "Acknowledgement recorded. This individual acknowledgement holds this result’s failure notifications until this contribution ends"
           )

    assert has_element?(
             view,
             "#incident-acknowledgement .panel-footer",
             "The shared incident may continue after this contribution ends"
           )

    {:ok, shared, _} = live(build_conn(), "/incidents/#{group.id}")
    assert has_element?(shared, "#condition-coverage", "1 individually acknowledged")

    assert has_element?(
             shared,
             "#condition-coverage",
             "1 of 2 failing results has no active hold"
           )

    # The individual panel must not deny the shared hold when the parent is
    # acknowledged and this separate, narrower control is ended.
    shared
    |> form("#acknowledgement-form", note: "Investigating the shared condition")
    |> render_submit()

    assert has_element?(shared, "#incident-acknowledgement-heading", "Acknowledgement")

    assert has_element?(
             shared,
             "#acknowledgement-lifetime",
             "Until this incident ends; no scheduled expiry."
           )

    view |> element("#end-acknowledgement") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, individual.id))
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))

    assert has_element?(
             view,
             "#incident-acknowledgement",
             "No individual acknowledgement is active"
           )

    refute has_element?(view, "#incident-acknowledgement", "No acknowledgement is active")

    assert has_element?(
             view,
             "#individual-acknowledgement-scope",
             "A shared incident acknowledgement may still hold notifications"
           )

    assert has_element?(view, ".flash", "Individual acknowledgement ended.")
  end

  defp inventory(count) do
    checks =
      for index <- 1..count do
        %{
          "key" => "check-#{String.pad_leading(to_string(index), 3, "0")}",
          "label" => "Check #{index}",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => "production",
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{}},
          "params" => %{},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 60,
          "outputs" => [
            %{
              "key" => "pressure",
              "label" => "Result #{index}",
              "target" => %{
                "kind" => "volume",
                "key" => "volume-#{index}",
                "label" => "Data #{index}"
              },
              "condition" => %{
                "namespace" => "live-test",
                "key" => "storage",
                "label" => "Storage pressure"
              }
            }
          ]
        }
      end

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(control(), %{
                 "runner_label" => "Independent observer",
                 "source_id" => "condition-live",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               Monitoring.now()
             )

    rows =
      Repo.all(
        from a in Assignment, where: a.source_id == "condition-live", order_by: a.source_key
      )

    assert {:ok, _} =
             Monitoring.control(
               control(%{"prepared" => Map.new(rows, &{&1.id, 1})}),
               Monitoring.now()
             )

    rows
  end

  defp incident_socket(id, flash \\ %{}) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, live_action: :incident, flash: flash},
      private: %{live_temp: %{}}
    }

    {:ok, socket} = IncidentLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      IncidentLive.handle_params(%{"id" => id}, "http://localhost/incidents/#{id}", socket)

    socket
  end

  defp sample(assignment, health, sequence, impacts \\ []) do
    now = Monitoring.now()

    report =
      measurement(health, sequence, %{
        "assignment_id" => assignment.id,
        "started_at" => Monitoring.iso(now),
        "evaluated_at" => Monitoring.iso(now),
        "results" => [
          %{
            "key" => "pressure",
            "health" => health,
            "summary" => "Measured #{health}",
            "value" => 90,
            "source_at" => Monitoring.iso(now),
            "impacts" => impacts
          }
        ]
      })

    assert disposition(ingest(report, now)) == "current"
    report
  end

  defp link_href(view, selector) do
    [href] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    href
  end

  defp hidden(view, name),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#acknowledgement-form input[name='#{name}']")
      |> LazyHTML.attribute("value")
      |> hd()

  defp recovery(view) do
    Map.new(~w(_id _revision _attention_revision _health), &{&1, hidden(view, &1)})
    |> Map.merge(%{
      "note" => "Review across pages",
      "mode" => "duration",
      "seconds" => "custom",
      "days" => "30",
      "hours" => "6"
    })
  end
end
