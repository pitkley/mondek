# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, CoverageFixtures, Inspection, MonitoringIncident, MonitoringLoss}

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  test "dashboard separates acknowledged incidents and restores attention at expiry" do
    now = Monitoring.now()

    for n <- 1..6 do
      check = CoverageFixtures.check("Failure #{n}", "production", "Service #{n}")
      publication = CoverageFixtures.publication([CoverageFixtures.candidate(check)])
      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = CoverageFixtures.activate(publication, now)
      assert disposition(CoverageFixtures.sample(publication, "CRIT", 1, now)) == "current"
    end

    incidents = Monitoring.list_incidents(%{}, now).items

    for incident <- Enum.take(incidents, 5) do
      assert {:ok, _} =
               reviewed_acknowledgement_fixture(incident["id"], 3600, "Investigating", now)
    end

    summary = MondekWeb.NextIncidentsLive.open_summary(now)
    assert summary["unacknowledged"].total == 1
    assert length(summary["unacknowledged"].rows) == 1
    assert summary["acknowledged"].total == 5
    assert length(summary["acknowledged"].rows) == 4
    expired = MondekWeb.NextIncidentsLive.open_summary(DateTime.add(now, 3600, :second))
    assert expired["unacknowledged"].total == 6
    assert expired["acknowledged"].total == 0
    {:ok, view, _} = live(build_conn(), "/")

    assert has_element?(
             view,
             "table[aria-label='Unacknowledged incidents'] tbody tr",
             "Unacknowledged"
           )

    assert has_element?(
             view,
             "section#overview-acknowledged-incidents",
             "5 incidents"
           )

    assert has_element?(view, "#overview-incidents-heading", "Incidents")
    assert has_element?(view, "#overview-unacknowledged-incidents h3", "Unacknowledged")
    assert has_element?(view, "#overview-acknowledged-incidents h3", "Acknowledged")
    refute has_element?(view, "#preview-open-incidents details")
    {:ok, listing, _} = live(build_conn(), "/incidents")
    assert has_element?(listing, "#incidents-unacknowledged h2", "Unacknowledged")
    assert has_element?(listing, "#incidents-acknowledged h2", "Acknowledged")

    for incident <- Enum.take(incidents, 5) do
      selector = "#preview-incident-health-" <> incident["id"]
      assert has_element?(listing, "#incidents-acknowledged " <> selector)
      refute has_element?(listing, "#incidents-unacknowledged " <> selector)
    end

    remaining = List.last(incidents)

    assert has_element?(
             listing,
             "#incidents-unacknowledged #preview-incident-health-" <> remaining["id"]
           )

    id = hd(incidents)["id"]

    for {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#incident-page"}] do
      {:ok, detail, _} = live(build_conn(), "/incidents/health/#{id}" <> suffix)

      assert has_element?(
               detail,
               root <> " aside[aria-label='Incident acknowledgement']",
               "Investigating"
             )

      assert has_element?(detail, root <> " button", "End acknowledgement")
    end
  end

  test "checks filters results and keeps its filters when opening and closing evidence" do
    now = Monitoring.now()
    check = CoverageFixtures.check("Queue depth", "production", "Parcel queue")
    [output] = check["outputs"]
    output = Map.put(output, "group", %{"key" => "logistics", "label" => "Logistics"})
    candidate = CoverageFixtures.candidate(Map.put(check, "outputs", [output]))
    other = CoverageFixtures.candidate(CoverageFixtures.check("Cache", "staging", "A Redis"))

    for {candidate, health} <- [{candidate, "CRIT"}, {other, "OK"}] do
      publication = CoverageFixtures.publication([candidate])
      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = CoverageFixtures.activate(publication, now)
      assert disposition(CoverageFixtures.sample(publication, health, 1, now)) == "current"
    end

    {:ok, view, _} = live(build_conn(), "/checks")
    assert has_element?(view, "a[aria-current='page'][href='/checks']")
    assert has_element?(view, "#preview-check-results", "Parcel queue")
    assert has_element?(view, "#preview-check-results", "Redis")
    assert has_element?(view, "#preview-check-results tbody tr:first-child", "Parcel queue")

    group = Mondek.ChecksFilters.options("group", "Logistics") |> hd()
    render_hook(view, "filter_open", %{"field" => "group"})
    render_hook(view, "filter_select", %{"key" => group.key, "kind" => group.kind})
    assert_patch(view, "/checks?group=#{group.key}")
    refute has_element?(view, "#preview-check-results", "Redis")

    render_hook(view, "filter_open", %{"field" => "health"})
    render_hook(view, "filter_select", %{"key" => "CRIT", "kind" => ""})
    query = "?group=#{group.key}&health=CRIT"
    assert_patch(view, "/checks" <> query)
    [result] = Inspection.preview_checks(%{"group" => group.key, "health" => "CRIT"}, now).items
    id = result["id"]

    view |> element("#open-result-#{id}") |> render_click()
    assert_patch(view, "/checks/#{id}" <> query)
    assert has_element?(view, "#overview-panel", "Queue depth")

    assert has_element?(
             view,
             "#overview-panel a[href*='surface=page']",
             "Open as page"
           )

    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, "/checks" <> query)

    {:ok, full, _} = live(build_conn(), "/checks/#{id}/full" <> query)
    assert has_element?(full, "h1", "Queue depth")
    assert has_element?(full, "a[href='/checks#{query}']", "Back to checks")
  end

  test "peer navigation selects the active result and its row closes the investigation" do
    now = Monitoring.now()

    candidate =
      CoverageFixtures.candidate(
        CoverageFixtures.check("Queue depth", "production", "Parcel queue")
      )

    first = CoverageFixtures.publication([candidate], %{"runner_label" => "Observer A"})
    second = CoverageFixtures.publication([candidate], %{"runner_label" => "Observer B"})

    for {publication, health} <- [{first, "CRIT"}, {second, "OK"}] do
      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = CoverageFixtures.activate(publication, now)
      assert disposition(CoverageFixtures.sample(publication, health, 1, now)) == "current"
    end

    [one] = Inspection.overview_results(%{}, now).attention.items
    [two] = Inspection.overview_results(%{}, now).healthy.items

    for prefix <- ["/results", "/checks"] do
      {:ok, view, _} = live(build_conn(), prefix <> "/#{one["id"]}?search=Parcel")
      assert has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      refute has_element?(view, "#result-row-#{two["id"]}.preview-selected")
      view |> element("#preview-related-results a", "Observer B") |> render_click()
      assert has_element?(view, "[data-active-entity='result:#{two["id"]}']")
      assert has_element?(view, "#result-row-#{two["id"]}.preview-selected")
      refute has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      send(view.pid, :tick)
      assert has_element?(view, "#result-row-#{two["id"]}.preview-selected")
      view |> element("#open-result-#{two["id"]}") |> render_click()

      assert_patch(
        view,
        if(prefix == "/checks", do: "/checks?search=Parcel", else: "/?search=Parcel")
      )

      refute has_element?(view, "#overview-panel")
      refute has_element?(view, "tr.preview-selected")

      view |> element("#open-result-#{one["id"]}") |> render_click()

      view
      |> element("#overview-panel table[aria-label='Collection'] a", "Observer A")
      |> render_click()

      assert has_element?(view, "#overview-panel #runner-detail")
      refute has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      refute has_element?(view, "#result-row-#{two["id"]}.preview-selected")
      view |> element("[data-overview-close]") |> render_click()
      assert has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      view |> element("#overview-panel a", "View incident") |> render_click()
      assert has_element?(view, "#overview-panel", "Recorded failure")
      refute has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      refute has_element?(view, "#result-row-#{two["id"]}.preview-selected")
      view |> element("#open-result-#{one["id"]}") |> render_click()
      assert has_element?(view, "#result-row-#{one["id"]}.preview-selected")
      assert has_element?(view, "#overview-panel table[aria-label='Latest measurement']")
    end
  end

  test "result fly-over shows four previous measurements and links to the longer history" do
    now = Monitoring.now()
    start = DateTime.add(now, -10, :second)

    candidate =
      CoverageFixtures.candidate(CoverageFixtures.check("Queue depth", "production", "Queue"))

    publication = CoverageFixtures.publication([candidate])

    assert {:ok, _} = Monitoring.inventory(publication, start)
    assert {:ok, _} = CoverageFixtures.activate(publication, start)

    for sequence <- 1..7 do
      health = if sequence <= 2, do: "CRIT", else: "OK"
      at = DateTime.add(start, sequence, :second)
      assert disposition(CoverageFixtures.sample(publication, health, sequence, at)) == "current"
    end

    [result] = Inspection.overview_results(%{}, now).healthy.items
    id = result["id"]
    table = "table[aria-label='Previous measurements']"
    full_path = "/results/#{id}/full"

    {:ok, fly_over, _} = live(build_conn(), "/results/#{id}")
    assert has_element?(fly_over, table <> " tr:nth-child(4)")
    refute has_element?(fly_over, table <> " tr:nth-child(5)")
    refute has_element?(fly_over, table, "Measured CRIT")

    assert has_element?(
             fly_over,
             "details table[aria-label='Older measurements']",
             "Measured CRIT"
           )

    assert has_element?(fly_over, "a[href*='surface=page']", "View more measurements")

    {:ok, full, _} = live(build_conn(), full_path)
    assert has_element?(full, table <> " tr:nth-child(6)")
    assert has_element?(full, table, "Measured CRIT")
    refute has_element?(full, "a", "View more measurements")
  end

  test "exact peers retain old Critical evidence alongside fresh Healthy evidence" do
    now = Monitoring.now()
    old = DateTime.add(now, -30, :second)

    candidate =
      CoverageFixtures.candidate(
        CoverageFixtures.check("Queue depth", "production", "Parcel queue")
      )

    first = CoverageFixtures.publication([candidate], %{"runner_label" => "Observer A"})
    second = CoverageFixtures.publication([candidate], %{"runner_label" => "Observer B"})

    for {publication, health, at} <- [{first, "CRIT", old}, {second, "OK", now}] do
      assert {:ok, _} = Monitoring.inventory(publication, at)
      assert {:ok, _} = CoverageFixtures.activate(publication, at)
      assert disposition(CoverageFixtures.sample(publication, health, 1, at)) == "current"
    end

    overview = Inspection.overview_results(%{}, now)
    assert overview.attention.total == 1
    assert overview.healthy.total == 1
    [group] = overview.attention.items
    assert overview.health.critical == 1
    assert overview.health.healthy == 1
    assert get_in(group, ["current", "knowledge"]) == "stale"

    {:ok, view, html} = live(build_conn(), "/?search=Parcel")
    assert html =~ "/assets/preview.css"
    refute html =~ "/assets/app.css"
    assert has_element?(view, "#preview-attention", "Observer A")
    assert has_element?(view, "#preview-healthy-results", "Observer B")
    assert has_element?(view, "#preview-attention", "Overdue measurement")
    assert has_element?(view, "#preview-attention", "Measured CRIT")

    view |> element("#open-result-#{group["id"]}") |> render_click()
    assert_patch(view, "/results/#{group["id"]}?search=Parcel")
    assert has_element?(view, "#overview-panel", "Observer A")
    assert has_element?(view, "#overview-panel", "Observer B")
    assert has_element?(view, "#overview-panel", "Critical")
    assert has_element?(view, "#preview-related-results", "Observer B")
    assert has_element?(view, "#overview-panel .preview-evidence-state", "Critical")
    refute has_element?(view, "#overview-panel .preview-evidence-state", "Healthy")
    refute has_element?(view, "#preview-related-results[open]")
    assert has_element?(view, "[data-overview-close][href='/?search=Parcel']")

    assert has_element?(
             view,
             "a[href*='surface=page']",
             "Open as page"
           )

    {:ok, full, _} = live(build_conn(), "/results/#{group["id"]}/full?search=Parcel")
    assert has_element?(full, "h1", "Queue depth")
    assert has_element?(full, "table[aria-label='Latest measurement']", "Critical")
    assert has_element?(full, "table[aria-label='Collection']", "Observer A")
    assert has_element?(full, "a[href='/?search=Parcel']", "Back to overview")
    refute has_element?(full, "#preview-overview-card")

    # A refresh must preserve the selected evidence and filtered return path.
    send(view.pid, :tick)
    assert render(view) =~ "overview-panel-title"
    render_submit(element(view, "#overview-search"), %{"search" => "Parcel"})
    assert has_element?(view, "#overview-panel", "Observer A")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, "/?search=Parcel")
    refute has_element?(view, "#overview-panel")

    [incident] = Monitoring.list_incidents(%{}, now).items
    id = incident["id"]
    assert has_element?(view, "#preview-open-incidents", "Unacknowledged")
    overview_incident = MondekWeb.InvestigationTrail.path("/?search=Parcel", [{"health", id}])
    view |> element("#overview-incident-health-#{id}") |> render_click()
    assert_patch(view, overview_incident)
    assert has_element?(view, "#preview-overview-card")
    assert has_element?(view, "#overview-panel", "Queue depth")
    view |> element("#overview-panel a", "View latest check result") |> render_click()

    assert_patch(
      view,
      MondekWeb.InvestigationTrail.path("/?search=Parcel", [
        {"health", id},
        {"result", group["id"]}
      ])
    )

    assert has_element?(view, "#overview-panel", "Check result")
    assert has_element?(view, "[data-panel-back-path='#{overview_incident}']")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, overview_incident)
    {:ok, incidents, _} = live(build_conn(), "/incidents")

    render_hook(incidents, "filter_open", %{"field" => "grouping"})
    render_hook(incidents, "filter_select", %{"key" => "standalone"})
    assert_patch(incidents, "/incidents?grouping=standalone")
    assert has_element?(incidents, "#preview-incident-health-#{id}")
    render_patch(incidents, "/incidents")

    render_hook(incidents, "filter_open", %{"field" => "type"})
    render_hook(incidents, "filter_select", %{"key" => "health", "kind" => ""})
    assert_patch(incidents, "/incidents?type=health")
    render_click(element(incidents, "#preview-incident-health-#{id} a"))
    assert_patch(incidents, "/incidents/health/#{id}?type=health")
    assert has_element?(incidents, "#incident-heading", "Queue depth")
    assert has_element?(incidents, "main", "Measured CRIT")
    assert has_element?(incidents, "main a", "View latest check result")
    assert has_element?(incidents, "#preview-delivery-heading")
    assert has_element?(incidents, "#preview-history-heading")

    render_submit(element(incidents, "#preview-incident-ack-form"), %{
      "mode" => "until_incident_ends",
      "note" => "Reviewed in the incident drawer"
    })

    assert has_element?(incidents, "main", "Acknowledgement saved.")
    assert has_element?(incidents, "main", "Reviewed in the incident drawer")
    refute has_element?(incidents, "#preview-incident-ack-form")
    render_click(element(incidents, "button", "Replace acknowledgement"))

    render_submit(element(incidents, "#preview-incident-ack-form"), %{
      "mode" => "duration",
      "amount" => "2",
      "unit" => "hours",
      "note" => ""
    })

    assert %{"acknowledgement_mode" => "until", "acknowledgement_note" => "No note provided."} =
             Monitoring.incident_detail(id)["incident"]

    assert has_element?(
             incidents,
             "table[aria-label='Active acknowledgement']",
             "No note provided"
           )

    refute has_element?(incidents, "#preview-incident-ack-form")
    render_click(element(incidents, "button", "Replace acknowledgement"))

    expiry = DateTime.add(Monitoring.now(), 3, :hour) |> DateTime.truncate(:second)

    render_submit(element(incidents, "#preview-incident-ack-form"), %{
      "mode" => "until",
      "expires_at" => expiry |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    })

    assert {:ok, saved_expiry, 0} =
             DateTime.from_iso8601(
               Monitoring.incident_detail(id)["incident"]["acknowledged_until"]
             )

    assert DateTime.compare(saved_expiry, expiry) == :eq

    render_click(element(incidents, "button", "End acknowledgement"))

    assert has_element?(incidents, "main", "Acknowledgement ended.")
  end

  test "a declaration excluded everywhere has a real placement panel, not onboarding or a fabricated result" do
    now = Monitoring.now()

    candidate =
      CoverageFixtures.candidate(
        CoverageFixtures.check("Root disk", "branch", "Branch node"),
        false
      )

    assert {:ok, _} = Monitoring.inventory(CoverageFixtures.publication([candidate]), now)
    [scope] = Coverage.scopes(%{}, now)["items"]

    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "#preview-onboarding")
    assert has_element?(view, "#preview-unobserved", "Branch node")
    assert has_element?(view, "#preview-unobserved", "No selected runner")
    view |> element("#open-expected-#{scope["id"]}") |> render_click()
    assert_patch(view, "/expected/#{scope["id"]}")
    assert has_element?(view, "#overview-panel", "Observer lacks service-query capability")
    refute has_element?(view, "#overview-panel a[href^='/checks/']")
    refute has_element?(view, "#overview-panel", "Source and evidence identity")
  end

  test "coverage separates declared gaps from fresh unhealthy measurements and stacks the result" do
    now = Monitoring.now()

    missing =
      CoverageFixtures.candidate(
        CoverageFixtures.check("Root disk", "production", "Node B"),
        false
      )

    measured =
      CoverageFixtures.candidate(CoverageFixtures.check("Search capacity", "staging", "Search"))

    publication = CoverageFixtures.publication([missing, measured])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = CoverageFixtures.activate(publication, now)
    assert disposition(CoverageFixtures.sample(publication, "CRIT", 1, now)) == "current"
    [gap, reporting] = Coverage.scopes(%{}, now)["items"]

    {:ok, view, _} = live(build_conn(), "/coverage")

    assert has_element?(
             view,
             "table[aria-label='Declared results'] tbody tr:first-child",
             "No runner selected"
           )

    assert has_element?(
             view,
             "table[aria-label='Declared results'] tbody tr:nth-child(2)",
             "1 of 1 selected runner reporting"
           )

    render_hook(view, "filter_open", %{"field" => "status"})
    render_hook(view, "filter_select", %{"key" => "attention", "kind" => ""})
    assert_patch(view, "/coverage?status=attention")
    assert has_element?(view, "button[aria-label='Edit Coverage filter: Needs attention']")
    refute has_element?(view, "#open-coverage-#{reporting["id"]}")
    view |> element("a[aria-label='Remove Coverage filter']") |> render_click()
    assert_patch(view, "/coverage")
    assert has_element?(view, "#open-coverage-#{reporting["id"]}")
    render_patch(view, "/coverage?status=attention")
    view |> element("#open-coverage-#{gap["id"]}") |> render_click()
    assert has_element?(view, "#overview-panel", "Observer lacks service-query capability")
    refute has_element?(view, "#overview-panel a", "View check result")

    base = "/coverage/#{reporting["id"]}"
    render_patch(view, base)
    result_link = element(view, "#overview-panel a", "View check result")

    opened_result_path =
      result_link
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    render_click(result_link)
    assert has_element?(view, "#overview-panel", "Critical")

    configuration_href =
      view
      |> element("#overview-panel a", "View check configuration")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")
      |> hd()

    return_to = URI.decode_query(URI.parse(configuration_href).query)["return_to"]
    assert return_to == opened_result_path

    scope_path = MondekWeb.InvestigationTrail.path(base, [{"coverage", reporting["id"]}])
    assert has_element?(view, "[data-panel-back-path='#{scope_path}']")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, scope_path)
    assert has_element?(view, "#overview-panel", "Runner decisions")

    page_path =
      MondekWeb.InvestigationTrail.path(base, [{"coverage", reporting["id"]}], %{
        "surface" => "page",
        "page_entity" => "coverage:#{reporting["id"]}"
      })

    view |> element("#overview-panel a", "Open as page") |> render_click()
    assert_patch(view, page_path)
    assert has_element?(view, "#coverage-page-body table[aria-label='Runner decisions']")
    view |> element("#coverage-page-body a", "View check result") |> render_click()
    assert has_element?(view, "#overview-panel", "Critical")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert_patch(view, page_path)
    refute has_element?(view, "#overview-panel")

    for prefix <- ["/coverage", "/expected"],
        {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#coverage-page-body"}] do
      {:ok, gap_view, _} = live(build_conn(), "#{prefix}/#{gap["id"]}" <> suffix)

      assert has_element?(gap_view, root <> " table[aria-label='Coverage']", "No runner selected")

      assert has_element?(
               gap_view,
               root <> " table[aria-label='Runner decisions']",
               "Observer lacks service-query capability"
             )

      refute has_element?(gap_view, root <> " a", "View check result")
    end
  end

  test "monitoring loss retains its evidence and actions in both incident surfaces" do
    now = Monitoring.now()
    earlier = DateTime.add(now, -MonitoringLoss.grace_seconds() - 1)
    candidate = CoverageFixtures.candidate(CoverageFixtures.check("Root disk"), false)
    assert {:ok, _} = Monitoring.inventory(CoverageFixtures.publication([candidate]), earlier)
    assert {:ok, _} = MonitoringLoss.reconcile(earlier)
    assert {:ok, _} = MonitoringLoss.reconcile(now)
    incident = Repo.get_by!(MonitoringIncident, scope_kind: "coverage", status: "open")

    for {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#incident-page"}] do
      {:ok, view, _} = live(build_conn(), "/incidents/loss/#{incident.id}" <> suffix)

      assert has_element?(
               view,
               root <> if(root == "#incident-page", do: " h2", else: " h3"),
               "Affected results"
             )

      assert has_element?(
               view,
               root <> if(root == "#incident-page", do: " h3", else: " h4"),
               "Root disk"
             )

      assert has_element?(
               view,
               root <> " a[href*='coverage%3A']",
               "Review expected monitoring"
             )

      assert has_element?(view, root <> " #preview-incident-ack-form")
      assert has_element?(view, root <> " a", "Schedule maintenance")
      assert has_element?(view, root <> " #preview-history-heading", "Incident history")
      assert has_element?(view, root <> " #preview-delivery-heading", "Notification delivery")
    end
  end

  test "runner diagnostic keeps its explanation and setup link in both surfaces" do
    now = Monitoring.now()

    candidate =
      CoverageFixtures.candidate(CoverageFixtures.check("Local disk"), false)
      |> Map.merge(%{
        "environment" => nil,
        "environment_label" => nil,
        "scope_resolved" => false,
        "scope_reason" => "Declare a monitored environment"
      })
      |> put_in(["outputs", Access.at(0), "target"], nil)

    assert {:ok, _} = Monitoring.inventory(CoverageFixtures.publication([candidate]), now)
    [diagnostic] = Coverage.diagnostics(%{}, now)["items"]
    base = "/coverage/diagnostics/#{diagnostic["id"]}"

    for {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#coverage-page-body"}] do
      {:ok, view, _} = live(build_conn(), base <> suffix)

      assert has_element?(
               view,
               root <> " table[aria-label='Diagnostic details']",
               "Declare a monitored environment"
             )

      assert has_element?(view, root <> " table[aria-label='Diagnostic details'] th", "Source")
      assert has_element?(view, root <> " a", "Inspect runner setup")
    end
  end

  test "empty, unknown selections, and filtering never silently select another result" do
    {:ok, empty, _} = live(build_conn(), "/")
    assert has_element?(empty, "#preview-onboarding")
    refute has_element?(empty, "#preview-unobserved")
    {:ok, invalid, _} = live(build_conn(), "/results/not-a-result?search=queue")
    assert has_element?(invalid, "#overview-panel-title", "Result unavailable")
    assert has_element?(invalid, "[data-overview-close][href='/?search=queue']")
    {:ok, missing, _} = live(build_conn(), "/expected/" <> String.duplicate("f", 64))
    assert has_element?(missing, "#overview-panel-title", "Declaration unavailable")
  end

  test "filter picker rejects malformed events and values outside its suggestions" do
    {:ok, view, _} = live(build_conn(), "/")
    render_hook(view, "filter_open", %{"field" => "environment"})
    assert has_element?(view, "#preview-search[aria-label=Environment]")

    render_hook(view, "filter_query", %{"search" => ["production"]})
    render_hook(view, "filter_first", %{})
    render_hook(view, "filter_select", %{"key" => "production"})
    render_hook(view, "filter_select", %{"key" => "production", "kind" => ""})

    assert has_element?(view, "#preview-search[aria-label=Environment]")
    refute_patched(view)
  end

  test "native rows page independently while related scopes remain bounded and exact" do
    now = Monitoring.now()
    candidate = CoverageFixtures.candidate(CoverageFixtures.check())

    for index <- 1..67 do
      publication =
        CoverageFixtures.publication([candidate], %{"runner_label" => "Observer #{index}"})

      assert {:ok, _} = Monitoring.inventory(publication, now)
    end

    for overrides <- [%{"source_id" => "another-source"}, %{}] do
      candidate =
        if overrides == %{},
          do: CoverageFixtures.candidate(CoverageFixtures.check("service", "staging")),
          else: candidate

      assert {:ok, _} =
               Monitoring.inventory(CoverageFixtures.publication([candidate], overrides), now)
    end

    results = Inspection.overview_results(%{}, now)
    assert results.attention.total == 69
    assert length(results.attention.items) == 30

    all_rows =
      for page <- 1..3,
          row <- Inspection.overview_results(%{"page" => to_string(page)}, now).attention.items,
          do: row["id"]

    assert length(Enum.uniq(all_rows)) == 69
    group = hd(Inspection.overview_results(%{"search" => "Observer 1"}, now).attention.items)
    detail = Inspection.overview_observers(group["id"], now)
    assert detail.total == 67
    assert length(detail.items) == 25
    assert hd(detail.items)["id"] == group["id"]
  end

  test "healthy results remain browsable and search applies before bounded paging" do
    now = Monitoring.now()

    candidate =
      CoverageFixtures.candidate(
        CoverageFixtures.check("Service", "production", "Service target")
      )

    publication = CoverageFixtures.publication([candidate])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = CoverageFixtures.activate(publication, now)
    assert disposition(CoverageFixtures.sample(publication, "OK", 1, now)) == "current"
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#preview-no-attention", "No results currently need attention")
    assert has_element?(view, "#preview-healthy-results", "Service target")
    render_submit(element(view, "#overview-search"), %{"search" => "absent-target"})
    assert_patch(view, "/?search=absent-target")
    refute has_element?(view, "#preview-healthy-results")
    assert has_element?(view, "#preview-summary", "1 / 1")
  end

  test "independent failures never disappear among healthy same-scope results" do
    now = Monitoring.now()
    candidate = CoverageFixtures.candidate(CoverageFixtures.check())

    for index <- 1..6 do
      publication =
        CoverageFixtures.publication([candidate], %{"runner_label" => "Shared observer"})

      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = CoverageFixtures.activate(publication, now)
      health = if index == 6, do: "CRIT", else: "OK"
      assert disposition(CoverageFixtures.sample(publication, health, 1, now)) == "current"
    end

    [group] = Inspection.overview_results(%{}, now).attention.items
    assert group["current"]["health"] == "CRIT"
    assert group["runner_display"] =~ group["runner_id"]
    assert Inspection.overview_results(%{}, now).healthy.total == 5
    detail = Inspection.overview_observers(group["id"], now)
    assert Enum.any?(Enum.take(detail.items, 2), &(&1["current"]["health"] == "CRIT"))
  end
end
