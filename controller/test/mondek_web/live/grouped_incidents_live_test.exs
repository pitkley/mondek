# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GroupedIncidentsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{ConditionIncident, Control}

  alias MondekWeb.InvestigationTrail

  @endpoint MondekWeb.Endpoint
  @impact %{"key" => "writes-blocked", "label" => "Writes blocked"}

  test "a new impact between acknowledgement commit and refresh never reports an active hold" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    owner = self()
    handler = "grouped-commit-#{System.unique_integer([:positive])}"
    gate = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler,
        [:mondek, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == view.pid && metadata.query == "commit" &&
               :atomics.compare_exchange(gate, 1, 0, 1) == :ok do
            send(owner, {:acknowledgement_committed, self()})

            receive do
              :continue_acknowledgement -> :ok
            after
              5_000 -> raise "commit gate not released"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        view
        |> form("#preview-incident-ack-form", note: "Reviewed before blocked writes")
        |> render_submit()
      end)

    assert_receive {:acknowledgement_committed, worker}, 5_000
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
    sample(check, "CRIT", 2, [@impact])
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
    send(worker, :continue_acknowledgement)
    html = Task.await(task, 5_000)
    refute has_element?(view, "table[aria-label='Active acknowledgement']")
    refute html =~ "Failure notifications are held"
  end

  test "an inactive first inspection removes stale acknowledgement success but preserves unrelated feedback" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)

    {:ok, active, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    active |> form("#preview-incident-ack-form", note: "Earlier review") |> render_submit()
    GenServer.stop(active.pid)

    sample(check, "CRIT", 2, [@impact])
    {:ok, view, html} = live(build_conn(), "/incidents/health/#{group.id}/full")
    refute has_element?(view, "table[aria-label='Active acknowledgement']")
    refute html =~ "Failure notifications are held"
    assert has_element?(view, "#preview-operator-history-#{group.id}", "Earlier review")
  end

  test "one contributing result, runner and notification use singular summary wording" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, listing, _} = live(build_conn(), "/incidents?search=Result+1")
    assert has_element?(listing, "#preview-incident-health-#{group.id}", "Storage pressure")
    refute has_element?(listing, "#preview-incident-health-#{group.id}", "1 results")
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    assert has_element?(view, "table[aria-label='Contributing results']", "Result 1")
    assert has_element?(view, "table[aria-label='Shared incident summary']", "1 of 1")

    assert has_element?(
             view,
             "section[aria-labelledby='preview-delivery-heading']",
             "notification"
           )
  end

  test "notifications expose their requested impact and severity and attempts link to the shared parent" do
    [check] = inventory(1)
    sample(check, "CRIT", 1, [@impact])
    group = Repo.one!(ConditionIncident)
    notices = Repo.all(from o in Occurrence, where: o.condition_incident_id == ^group.id)
    {:ok, shared, _} = live(build_conn(), "/incidents/health/#{group.id}/full")

    for notice <- notices do
      label =
        if notice.payload["requested_fact"]["key"] == "writes-blocked",
          do: "Writes blocked",
          else: "Critical severity"

      {:ok, detail, _} = live(build_conn(), "/notifications/#{notice.id}/full")
      assert has_element?(detail, "[data-notification-body] .notification-requested-scope", label)
      assert has_element?(detail, "[data-notification-body] a[href*='health%3A#{group.id}']")
      assert has_element?(shared, "section[aria-labelledby='preview-delivery-heading']", label)
    end

    assert has_element?(shared, "table[aria-label='Contributing results']", "Writes blocked")
  end

  test "active acknowledgement uses friendly impact names and falls back to the reviewed key" do
    [check] = inventory(1)
    sample(check, "CRIT", 1, [@impact])
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")

    view
    |> form("#preview-incident-ack-form", note: "Investigating blocked writes")
    |> render_submit()

    assert has_element?(view, "table[aria-label='Active acknowledgement']", "Writes blocked")
    sample(check, "CRIT", 2)
    send(view.pid, :tick)
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "writes-blocked")
    assert Repo.get!(ConditionIncident, group.id).acknowledgement_impacts == ["writes-blocked"]
  end

  test "shared incident offers direct collection investigation only for missing evidence" do
    [check] = inventory(1)
    report = sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.one!(Incident)

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
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    view |> element("a[href*='result%3A#{child.stream_id}']") |> render_click()
    assert has_element?(view, "#overview-panel", "Datasource timed out")
    assert has_element?(view, "#overview-panel #result-collection-diagnostics")
  end

  test "measurement investigation follows shared notification ownership and retains result scope" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.one!(Incident)
    {:ok, view, _} = live(build_conn(), "/checks?health=CRIT")
    view |> element("#open-result-#{child.stream_id}") |> render_click()
    assert_patch(view)
    view |> element("#overview-panel a", "View shared incident") |> render_click()
    path = assert_patch(view)
    assert URI.parse(path).path == "/checks/#{child.stream_id}"

    assert URI.decode_query(URI.parse(path).query)["inspect"] ==
             "result:#{child.stream_id},health:#{group.id}"

    assert has_element?(view, "#overview-panel", "Storage pressure")
    assert has_element?(view, "#overview-panel", "Notification delivery")
    assert has_element?(view, "[data-panel-back-path*='result%3A#{child.stream_id}']")
  end

  test "notification investigation preserves the original shared incident filters within a bounded return chain" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.one!(Incident)

    path =
      InvestigationTrail.path("/incidents?search=Storage&notification_status=delivered", [
        {"health", group.id},
        {"result", child.stream_id}
      ])

    {:ok, view, _} = live(build_conn(), path)
    view |> element("#overview-panel a", "View shared incident") |> render_click()
    returned = assert_patch(view)
    query = URI.decode_query(URI.parse(returned).query)
    assert query["search"] == "Storage"
    assert query["notification_status"] == "delivered"
    assert query["inspect"] == "health:#{group.id}"
    refute query["return_to"]
  end

  test "the filtered list retains one whole incident and the detail has no invented owner" do
    [one, two] = inventory(2)
    sample(one, "WARN", 1)
    sample(two, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, listing, _} = live(build_conn(), "/incidents?search=Result+1")
    assert has_element?(listing, "#preview-incident-health-#{group.id}", "Critical")

    assert listing
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("#incidents-unacknowledged table > tbody > tr")
           |> Enum.count() == 1

    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    assert has_element?(view, "#incident-heading", "Storage pressure")
    assert has_element?(view, "table[aria-label='Contributing results']", "Result 1")
    assert has_element?(view, "table[aria-label='Contributing results']", "Result 2")
    assert has_element?(view, "table[aria-label='Shared incident summary']", "2 of 2")
    refute has_element?(view, "#incident-heading", "Independent observer")
  end

  test "late equivalent corroboration preserves shared acknowledgement and a draft; new impact requires review" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    view |> form("#preview-incident-ack-form", note: "Investigating storage") |> render_submit()
    view |> element("button[phx-click='toggle_acknowledgement_replacement']") |> render_click()

    view
    |> form("#preview-incident-ack-form", note: "Draft for tomorrow", mode: "duration")
    |> render_change()

    state = recovered_controls(view, {"health", group.id})
    sample(two, "CRIT", 1)
    send(view.pid, :tick)

    assert has_element?(
             view,
             "table[aria-label='Active acknowledgement']",
             "Investigating storage"
           )

    assert recovered_controls(view, {"health", group.id}).review == state.review
    sample(two, "CRIT", 2, [@impact])
    send(view.pid, :tick)
    refute has_element?(view, "table[aria-label='Active acknowledgement']")
    assert has_element?(view, "#preview-incident-ack-form", "Draft for tomorrow")
    view |> form("#preview-incident-ack-form") |> render_submit()
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
    assert render(view) =~ "Review it again"
  end

  test "partial maintenance and unavailable collection remain independent of the shared control" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "WARN", 1)
    group = Repo.one!(ConditionIncident)
    assert {:ok, _} = reviewed_maintenance_fixture(one.id, 3600, "Replace this disk")
    sample(one, "UNKNOWN", 2)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{group.id}/full")
    assert has_element?(view, "#preview-maintenance-heading + table", "1 of 2")
    assert has_element?(view, "table[aria-label='Contributing results']", "unavailable")
    assert has_element?(view, "table[aria-label='Contributing results']", "Critical")

    assert has_element?(
             view,
             "table[aria-label='Contributing results']",
             "Paused for maintenance"
           )

    view
    |> form("#preview-incident-ack-form", note: "Inspect both observations")
    |> render_submit()

    assert has_element?(
             view,
             "table[aria-label='Contributing results']",
             "Paused by shared acknowledgement"
           )

    view |> element("button[phx-click='end_acknowledgement']") |> render_click()

    assert has_element?(
             view,
             "table[aria-label='Contributing results']",
             "Paused for maintenance"
           )
  end

  test "shared incident links stack over check results on either preview host and full result pages" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "WARN", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.get_by!(Incident, assignment_id: one.id)

    for {prefix, full?} <- [
          {"/checks", false},
          {"/results", false},
          {"/checks", true}
        ] do
      base = prefix <> "/#{child.stream_id}" <> if(full?, do: "/full", else: "")
      host = base <> "?search=volume"
      initial = if full?, do: [], else: [{"result", child.stream_id}]
      incident = InvestigationTrail.path(host, initial ++ [{"health", group.id}])
      returned_host = InvestigationTrail.path(host, initial)
      {:ok, view, _} = live(build_conn(), host)

      root = if full?, do: "#preview-result-page", else: "#overview-panel"
      assert has_element?(view, root <> " table[aria-label='Latest measurement']", "Critical")
      assert has_element?(view, root <> " table[aria-label='Collection']")

      assert has_element?(
               view,
               root <> " table[aria-label='Open incidents'] a",
               "View shared incident"
             )

      view |> element("a", "View shared incident") |> render_click()
      assert_patch(view, incident)
      assert has_element?(view, "#overview-panel", "Contributing results")

      if full? do
        assert has_element?(view, "#preview-result-page[inert]")
      else
        assert has_element?(view, "[data-panel-back-path='#{returned_host}']")
      end

      view |> element("[data-overview-close]") |> render_click()
      assert_patch(view, returned_host)

      {:ok, direct, _} = live(build_conn(), incident)
      assert has_element?(direct, "#overview-panel", "Contributing results")

      view_path =
        InvestigationTrail.path(host, initial ++ [{"health", group.id}, {"health", child.id}])

      direct |> element("#overview-panel a[href='#{view_path}']") |> render_click()
      assert_patch(direct, view_path)
      assert has_element?(direct, "#overview-panel", "Recorded failure")
      assert has_element?(direct, "[data-panel-back-path='#{incident}']")

      direct |> element("#overview-panel a", "View latest check result") |> render_click()
      assert_patch(direct, returned_host)
      refute has_element?(direct, "[data-panel-back-path]")

      if full? do
        refute has_element?(direct, "#overview-panel")
        assert has_element?(direct, "#preview-result-page")
      else
        assert has_element?(direct, "#overview-panel", "Latest measurement")
      end
    end
  end

  test "preview filters maintained contributors and links their individual incidents" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1, [@impact])
    sample(two, "WARN", 1)
    group = Repo.one!(ConditionIncident)
    first = Repo.get_by!(Incident, assignment_id: one.id)
    second = Repo.get_by!(Incident, assignment_id: two.id)
    assert {:ok, window} = reviewed_maintenance_fixture(one.id, 3600, "Replace this disk")

    path = "/incidents/health/#{group.id}"
    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, "#preview-incident-health-#{group.id}")
    refute has_element?(view, "#preview-incident-health-#{first.id}")
    assert has_element?(view, "#preview-maintenance-heading + table", "1 of 2")
    assert has_element?(view, "a[href^='/maintenance/#{window["id"]}?']")
    first_path = InvestigationTrail.path(path, [{"health", group.id}, {"health", first.id}])
    assert has_element?(view, "a[href='#{first_path}']")
    assert has_element?(view, "summary", "Original notification payload")

    view |> element("a", "Show results with unpaused notifications") |> render_click()

    parent_path =
      InvestigationTrail.path(path, [{"health", group.id}], %{"contributors" => "uncovered"})

    assert_patch(view, parent_path)
    refute has_element?(view, "#overview-panel a[href*='health%3A#{first.id}']")

    child_path =
      InvestigationTrail.path(path, [{"health", group.id}, {"health", second.id}], %{
        "contributors" => "uncovered"
      })

    view |> element("#overview-panel a[href='#{child_path}']") |> render_click()

    assert_patch(view, child_path)

    assert has_element?(
             view,
             "a[href='#{parent_path}']",
             "Open shared incident and its notifications"
           )

    view |> element("a", "View latest check result") |> render_click()

    result_path =
      InvestigationTrail.path(
        path,
        [{"health", group.id}, {"health", second.id}, {"result", second.stream_id}],
        %{"contributors" => "uncovered"}
      )

    assert_patch(view, result_path)

    configuration_href =
      view
      |> element("#overview-panel a", "View check configuration")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    assert URI.decode_query(URI.parse(configuration_href).query)["return_to"] == result_path
    assert has_element?(view, "#overview-panel-title")
    assert has_element?(view, "[data-panel-back-path='#{child_path}'] a")
    assert has_element?(view, "#incidents-heading")

    view
    |> element("[data-panel-back-path='#{parent_path}'] a")
    |> render_click()

    assert_patch(view, parent_path)
    refute has_element?(view, "#overview-panel-title")

    assert has_element?(view, "#preview-chip-grouping", "Top-level incidents")
    view |> element("a[aria-label='Remove Grouping filter']") |> render_click()
    assert_patch(view, "/incidents?grouping=all")
    refute has_element?(view, "#preview-chip-grouping")
    assert has_element?(view, "#preview-incident-health-#{group.id}")
    assert has_element?(view, "#preview-incident-health-#{first.id}")
    assert has_element?(view, "#preview-incident-health-#{second.id}")

    render_hook(view, "filter_open", %{"field" => "grouping"})
    render_hook(view, "filter_select", %{"key" => "member"})
    assert_patch(view, "/incidents?grouping=member")
    refute has_element?(view, "#preview-incident-health-#{group.id}")
    assert has_element?(view, "#preview-incident-health-#{first.id}")
    assert has_element?(view, "#preview-incident-health-#{second.id}")

    render_patch(view, "/incidents?grouping=standalone")
    refute has_element?(view, "#preview-incident-health-#{first.id}")
    refute has_element?(view, "#preview-incident-health-#{group.id}")

    render_patch(view, path <> "?grouping=shared")
    view |> element("a", "Open as page") |> render_click()

    full =
      InvestigationTrail.path(path, [{"health", group.id}], %{
        "grouping" => "shared",
        "surface" => "page",
        "page_entity" => "health:#{group.id}"
      })

    assert_patch(view, full)
    assert has_element?(view, "#incident-page h1")
    refute has_element?(view, "#overview-panel")
    refute has_element?(view, "#incidents-heading")

    refute has_element?(view, "a", "Show historical contributors")
    sample(one, "OK", 2)
    send(view.pid, :tick)
    refute has_element?(view, "a[href*='health%3A#{first.id}']")
    view |> element("a", "Show historical contributors") |> render_click()

    history_path =
      InvestigationTrail.path(full, [{"health", group.id}], %{"contributors" => "history"})

    assert_patch(view, history_path)
    assert has_element?(view, "a[href*='health%3A#{first.id}']")
    refute has_element?(view, "a[href*='health%3A#{second.id}']")

    view |> element("a[href*='health%3A#{first.id}']") |> render_click()
    assert has_element?(view, "#incident-page h1")
    assert has_element?(view, "#overview-panel h2")
    view |> element("#overview-panel a", "View latest check result") |> render_click()
    assert has_element?(view, "#overview-panel", "Check result")
    assert has_element?(view, "[data-panel-back-path*='health%3A#{first.id}']")
    view |> element("[data-overview-close]") |> render_click()
    assert has_element?(view, "#overview-panel h2")
    view |> element("[data-overview-close]") |> render_click()
    refute has_element?(view, "#overview-panel")

    view
    |> form("form:has(#preview-detail-notification_status)", notification_status: "exhausted")
    |> render_change()

    assert_patch(
      view,
      InvestigationTrail.path(history_path, [{"health", group.id}], %{
        "notification_status" => "exhausted"
      })
    )

    assert has_element?(view, "#incident-page", "No notifications match this status.")

    view |> element("a", "Back to incidents") |> render_click()
    assert_patch(view, "/incidents?grouping=shared")
  end

  test "preview acknowledgement drafts survive refresh and stale saves on either host" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.get_by!(Incident, assignment_id: check.id)

    for path <- [
          "/incidents/health/#{group.id}",
          InvestigationTrail.path("/checks/#{child.stream_id}", [
            {"result", child.stream_id},
            {"health", group.id}
          ])
        ] do
      params = URI.decode_query(URI.parse(path).query || "")
      trail = InvestigationTrail.resolve(params, InvestigationTrail.initial(URI.parse(path).path))

      next_path =
        InvestigationTrail.path(path, trail, %{
          "surface" => "page",
          "page_entity" => "health:#{group.id}"
        })

      token = "health:#{group.id}"
      {:ok, view, _} = live(build_conn(), path)

      draft = %{
        "mode" => "duration",
        "amount" => "3",
        "unit" => "hours",
        "note" => "Still investigating"
      }

      if has_element?(view, "table[aria-label='Active acknowledgement']") do
        render_hook(
          with_target(view, "#investigation-stack"),
          "toggle_acknowledgement_replacement",
          %{"entity" => token}
        )
      end

      render_hook(
        with_target(view, "#investigation-stack"),
        "edit_acknowledgement",
        Map.put(draft, "entity", token)
      )

      send(view.pid, :tick)
      assert has_element?(view, "textarea[name=note]", "Still investigating")
      render_patch(view, next_path)
      assert has_element?(view, "textarea[name=note]", "Still investigating")

      current = Monitoring.incident_detail(group.id, Monitoring.now())["incident"]
      review = MondekWeb.PreviewIncidentControls.revision(current)

      assert {:ok, _} =
               Monitoring.acknowledge(
                 group.id,
                 Map.put(review, "mode", "until_incident_ends"),
                 "Other operator"
               )

      render_hook(
        with_target(view, "#investigation-stack"),
        "save_acknowledgement",
        Map.put(draft, "entity", token)
      )

      assert has_element?(view, "[role=alert]", "The incident changed")
      # Another operator's active acknowledgement can hide the replacement form.
      # The owning LiveView must retain the submitted draft and captured revision.
      controls = recovered_controls(view, {"health", group.id})
      assert controls.draft == draft
      assert controls.review == review

      assert controls.review !=
               MondekWeb.PreviewIncidentControls.revision(
                 Monitoring.incident_detail(group.id)["incident"]
               )

      assert Repo.get!(ConditionIncident, group.id).acknowledgement_note == "Other operator"

      render_hook(with_target(view, "#investigation-stack"), "review_control", %{
        "entity" => token
      })

      render_hook(
        with_target(view, "#investigation-stack"),
        "save_acknowledgement",
        Map.put(draft, "entity", token)
      )

      assert has_element?(
               view,
               "table[aria-label='Active acknowledgement']",
               "Still investigating"
             )

      render_hook(with_target(view, "#investigation-stack"), "retry_delivery", %{
        "entity" => token,
        "_id" => Ecto.UUID.generate(),
        "reason" => "Retry"
      })

      assert has_element?(view, "[role=alert]", "no longer eligible")

      render_patch(
        view,
        InvestigationTrail.path(path, [{"health", child.id}], %{
          "surface" => nil,
          "page_entity" => nil
        })
      )

      controls = recovered_controls(view, {"health", child.id})
      assert controls.draft == %{}
      assert controls.retry_drafts == %{}
    end

    {:ok, list, _} = live(build_conn(), "/checks")
    count = Repo.aggregate(Control, :count)

    render_hook(list, "save_acknowledgement", %{
      "mode" => "until_incident_ends",
      "note" => "No selected incident"
    })

    assert Repo.aggregate(Control, :count) == count
  end

  test "shared and standalone health incidents expose the same capabilities in both surfaces" do
    [shared, standalone] = inventory(2)
    sample(shared, "CRIT", 1, [@impact])
    sample(standalone, "WARN", 1)
    group = Repo.one!(ConditionIncident)
    individual = Repo.get_by!(Incident, assignment_id: standalone.id)

    for {id, evidence, link} <- [
          {group.id, "Contributing results", "Latest check result"},
          {individual.id, "Recorded failure", "View latest check result"}
        ],
        {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#incident-page"}] do
      {:ok, view, _} = live(build_conn(), "/incidents/health/#{id}" <> suffix)

      api = json_response(get(build_conn(), "/api/v1/incidents/health/#{id}"), 200)["data"]
      assert has_element?(view, root <> " #incident-heading", api["incident"]["display_title"])

      if evidence == "Contributing results" do
        assert Enum.all?(
                 api["contributions"],
                 &(&1["recorded_measurement"]["basis"] == "latest_failure")
               )

        assert Enum.any?(
                 api["contributions"],
                 &(&1["recorded_measurement"]["measurement"]["health"] == "CRIT")
               )
      else
        assert api["recorded_measurement"]["measurement"]["health"] == "WARN"
      end

      assert has_element?(view, root <> " table[aria-label='#{evidence}']")
      assert has_element?(view, root <> " a", link)
      assert has_element?(view, root <> " #preview-incident-ack-form")
      assert has_element?(view, root <> " a", "Schedule maintenance")
      assert has_element?(view, root <> " #preview-history-heading", "Incident history")
      assert has_element?(view, root <> " #preview-delivery-heading", "Notification delivery")
    end
  end

  test "preview delivery markup excludes the destination and webhook delivery envelope" do
    [check] = inventory(1)
    sample(check, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    now = Monitoring.now()
    detail = Monitoring.incident_detail(group.id, now, %{"notification_status" => "all"})
    [notice | _] = detail["occurrences"]
    secret = "https://receiver.example.invalid/private-hook-token"

    notice =
      notice
      |> put_in(["destination"], secret)
      |> put_in(["payload", "webhook_delivery"], %{"body" => "private-delivery-body"})

    html =
      render_component(&MondekWeb.PreviewIncidentSections.sections/1,
        incident: detail["incident"],
        detail: Map.put(detail, "occurrences", [notice]),
        kind: "health",
        now: now,
        review: nil,
        draft: %{},
        replacing: false,
        feedback: nil,
        delivery_feedback: nil,
        retry_drafts: %{},
        maintenance_windows: [],
        delivery_pagination: []
      )

    assert html =~ "Original notification payload"
    refute html =~ secret
    refute html =~ "private-delivery-body"
  end

  test "paging, filtering, ticks and form recovery preserve reviewed acknowledgement settings" do
    rows = inventory(26)
    Enum.each(rows, &sample(&1, "CRIT", 1))
    group = Repo.one!(ConditionIncident)
    path = "/incidents/health/#{group.id}/full"
    {:ok, view, _} = live(build_conn(), path)

    view
    |> form("#preview-incident-ack-form", mode: "duration", note: "Review across pages")
    |> render_change()

    view |> form("#preview-incident-ack-form", amount: "726", unit: "hours") |> render_change()
    before = recovered_controls(view, {"health", group.id})
    snapshot = link_value(view, "#investigation-stack-recovery input[name=snapshot]", "value")

    view
    |> element("nav[aria-label='Contributing result pages'] a[aria-label='Page 2']")
    |> render_click()

    page = assert_patch(view)
    assert URI.decode_query(URI.parse(page).query)["member_page"] == "2"
    send(view.pid, :tick)
    assert recovered_controls(view, {"health", group.id}).draft == before.draft
    {:ok, reconnected, _} = live(build_conn(), page)

    with_target(reconnected, "#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    assert recovered_controls(reconnected, {"health", group.id}).review == before.review
    assert has_element?(reconnected, "#preview-incident-ack-form", "Review across pages")
    assert has_element?(reconnected, "input[name=amount][value='726']")
    assert Repo.aggregate(Control, :count) == 0
  end

  test "individual contribution evidence and notification navigation preserve their distinct owners" do
    [check] = inventory(1)
    opening = sample(check, "CRIT", 1)
    latest = sample(check, "CRIT", 2)
    child = Repo.one!(Incident)
    group = Repo.one!(ConditionIncident)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{child.id}/full")
    assert has_element?(view, "#preview-measurements-#{child.id}", "Measured CRIT")
    assert Repo.get!(Incident, child.id).opening_observation_id == opening["id"]
    assert Repo.get!(Incident, child.id).latest_observation_id == latest["id"]

    assert has_element?(
             view,
             "a[href*='health%3A#{group.id}']",
             "Open shared incident and its notifications"
           )

    refute has_element?(view, "section[aria-labelledby='preview-delivery-heading']", "HTTP")
    view |> element("a", "Open shared incident and its notifications") |> render_click()
    assert has_element?(view, "#overview-panel", "Notification delivery")
  end

  test "closed contribution history and parent links remain attached to their original incident" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "OK", 1)
    original = Repo.one!(ConditionIncident)
    child = Repo.one!(Incident)
    recovery = sample(one, "OK", 2)
    recurrence = sample(one, "CRIT", 3)
    replacement = Repo.one!(from g in ConditionIncident, where: g.status == "open")
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{child.id}/full")
    assert has_element?(view, "a[href*='health%3A#{original.id}']")
    refute has_element?(view, "a[href*='health%3A#{replacement.id}']")
    assert Repo.get!(Incident, child.id).closing_observation_id == recovery["id"]
    assert has_element?(view, "#preview-measurements-#{child.id}", "Measured OK")
    refute has_element?(view, "#preview-incident-ack-form")
    assert has_element?(view, "#preview-recent-executions-#{child.id}", "Measured CRIT")
    assert Repo.get!(Observation, recurrence["id"])
  end

  test "individual acknowledgement stays explicitly scoped and does not acknowledge the group" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    child = Repo.get_by!(Incident, assignment_id: one.id)
    {:ok, view, _} = live(build_conn(), "/incidents/health/#{child.id}/full")
    view |> form("#preview-incident-ack-form", note: "Only this observer") |> render_submit()
    assert Repo.get!(Incident, child.id).acknowledgement_mode == "until_incident_ends"
    assert Repo.get!(ConditionIncident, group.id).acknowledgement_mode == nil
    assert has_element?(view, "table[aria-label='Active acknowledgement']", "contribution only")
    {:ok, shared, _} = live(build_conn(), "/incidents/health/#{group.id}/full")

    assert has_element?(
             shared,
             "table[aria-label='Contributing results']",
             "Paused by individual acknowledgement"
           )

    shared |> form("#preview-incident-ack-form", note: "Shared issue") |> render_submit()
    view |> element("button[phx-click='end_acknowledgement']") |> render_click()
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, child.id))
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id))
  end

  defp recovered_controls(view, identity) do
    token =
      view
      |> element("#investigation-stack-recovery input[name=snapshot]")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    {:ok, %{states: states}} =
      Phoenix.Token.verify(MondekWeb.Endpoint, "investigation-drafts-v1", token, max_age: 60)

    Map.fetch!(states, identity)
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

  defp link_value(view, selector, attribute) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input")
    |> LazyHTML.attribute(attribute)
    |> hd()
  end
end
