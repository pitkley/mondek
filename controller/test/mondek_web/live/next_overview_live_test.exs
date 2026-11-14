# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, CoverageFixtures, Inspection, MonitoringIncident, MonitoringLoss}

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

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

    {:ok, view, _} = live(build_conn(), "/next/checks")
    assert has_element?(view, "a[aria-current='page'][href='/next/checks']")
    assert has_element?(view, "#preview-check-results", "Parcel queue")
    assert has_element?(view, "#preview-check-results", "Redis")
    assert has_element?(view, "#preview-check-results tbody tr:first-child", "Parcel queue")

    group = Mondek.ChecksFilters.options("group", "Logistics") |> hd()
    render_hook(view, "filter_open", %{"field" => "group"})
    render_hook(view, "filter_select", %{"key" => group.key, "kind" => group.kind})
    assert_patch(view, "/next/checks?group=#{group.key}")
    refute has_element?(view, "#preview-check-results", "Redis")

    render_hook(view, "filter_open", %{"field" => "health"})
    render_hook(view, "filter_select", %{"key" => "CRIT", "kind" => ""})
    query = "?group=#{group.key}&health=CRIT"
    assert_patch(view, "/next/checks" <> query)
    [result] = Inspection.preview_checks(%{"group" => group.key, "health" => "CRIT"}, now).items
    id = result["id"]

    view |> element("#open-result-#{id}") |> render_click()
    assert_patch(view, "/next/checks/#{id}" <> query)
    assert has_element?(view, "#overview-panel", "Queue depth")

    assert has_element?(
             view,
             "#overview-panel a[href='/next/checks/#{id}/full#{query}']",
             "Open as page"
           )

    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, "/next/checks" <> query)

    {:ok, full, _} = live(build_conn(), "/next/checks/#{id}/full" <> query)
    assert has_element?(full, "h1", "Queue depth")
    assert has_element?(full, "a[href='/next/checks#{query}']", "Back to checks")
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
    full_path = "/next/results/#{id}/full"

    {:ok, fly_over, _} = live(build_conn(), "/next/results/#{id}")
    assert has_element?(fly_over, table <> " tr:nth-child(4)")
    refute has_element?(fly_over, table <> " tr:nth-child(5)")
    refute has_element?(fly_over, table, "Measured CRIT")

    assert has_element?(
             fly_over,
             "details table[aria-label='Older measurements']",
             "Measured CRIT"
           )

    assert has_element?(fly_over, "a[href='#{full_path}']", "View more measurements")

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

    {:ok, view, html} = live(build_conn(), "/next?search=Parcel")
    assert html =~ "/assets/preview.css"
    refute html =~ "/assets/app.css"
    assert has_element?(view, "#preview-attention", "Observer A")
    assert has_element?(view, "#preview-healthy-results", "Observer B")
    assert has_element?(view, "#preview-attention", "Overdue measurement")
    assert has_element?(view, "#preview-attention", "Measured CRIT")

    view |> element("#open-result-#{group["id"]}") |> render_click()
    assert_patch(view, "/next/results/#{group["id"]}?search=Parcel")
    assert has_element?(view, "#overview-panel", "Observer A")
    assert has_element?(view, "#overview-panel", "Observer B")
    assert has_element?(view, "#overview-panel", "Critical")
    assert has_element?(view, "#preview-related-results", "Observer B")
    assert has_element?(view, "#overview-panel .preview-evidence-state", "Critical")
    refute has_element?(view, "#overview-panel .preview-evidence-state", "Healthy")
    refute has_element?(view, "#preview-related-results[open]")
    assert has_element?(view, "[data-overview-close][href='/next?search=Parcel']")

    assert has_element?(
             view,
             "a[href='/next/results/#{group["id"]}/full?search=Parcel']",
             "Open as page"
           )

    {:ok, full, _} = live(build_conn(), "/next/results/#{group["id"]}/full?search=Parcel")
    assert has_element?(full, "h1", "Queue depth")
    assert has_element?(full, "table[aria-label='Latest measurement']", "Critical")
    assert has_element?(full, "table[aria-label='Collection']", "Observer A")
    assert has_element?(full, "a[href='/next?search=Parcel']", "Back to overview")
    refute has_element?(full, "#preview-overview-card")

    # A refresh must preserve the selected evidence and filtered return path.
    send(view.pid, :tick)
    assert render(view) =~ "overview-panel-title"
    render_submit(element(view, "#overview-search"), %{"search" => "Parcel"})
    assert has_element?(view, "#overview-panel", "Observer A")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, "/next?search=Parcel")
    refute has_element?(view, "#overview-panel")

    [incident] = Monitoring.list_incidents(%{}, now).items
    id = incident["id"]
    assert has_element?(view, "#preview-open-incidents", "Unacknowledged")
    overview_incident = "/next?incident=health%3A#{id}&search=Parcel"
    view |> element("#overview-incident-health-#{id}") |> render_click()
    assert_patch(view, overview_incident)
    assert has_element?(view, "#preview-overview-card")
    assert has_element?(view, "#overview-panel", "Queue depth")
    view |> element("#overview-panel a", "View latest check result") |> render_click()

    assert_patch(
      view,
      overview_incident |> String.replace("&search=", "&result=#{group["id"]}&search=")
    )

    assert has_element?(view, "#overview-panel", "Check result")
    assert has_element?(view, "[data-panel-back-path='#{overview_incident}']")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, overview_incident)
    {:ok, incidents, _} = live(build_conn(), "/next/incidents")

    render_hook(incidents, "filter_open", %{"field" => "grouping"})
    render_hook(incidents, "filter_select", %{"key" => "standalone"})
    assert_patch(incidents, "/next/incidents?grouping=standalone")
    assert has_element?(incidents, "#preview-incident-health-#{id}")
    render_patch(incidents, "/next/incidents")

    render_hook(incidents, "filter_open", %{"field" => "type"})
    render_hook(incidents, "filter_select", %{"key" => "health", "kind" => ""})
    assert_patch(incidents, "/next/incidents?type=health")
    render_click(element(incidents, "#preview-incident-health-#{id} a"))
    assert_patch(incidents, "/next/incidents/health/#{id}?type=health")
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

    {:ok, view, _} = live(build_conn(), "/next")
    refute has_element?(view, "#preview-onboarding")
    assert has_element?(view, "#preview-unobserved", "Branch node")
    assert has_element?(view, "#preview-unobserved", "No selected runner")
    view |> element("#open-expected-#{scope["id"]}") |> render_click()
    assert_patch(view, "/next/expected/#{scope["id"]}")
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

    {:ok, view, _} = live(build_conn(), "/next/coverage")

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
    assert_patch(view, "/next/coverage?status=attention")
    assert has_element?(view, "button[aria-label='Edit Coverage filter: Needs attention']")
    refute has_element?(view, "#open-coverage-#{reporting["id"]}")
    view |> element("a[aria-label='Remove Coverage filter']") |> render_click()
    assert_patch(view, "/next/coverage")
    assert has_element?(view, "#open-coverage-#{reporting["id"]}")
    render_patch(view, "/next/coverage?status=attention")
    view |> element("#open-coverage-#{gap["id"]}") |> render_click()
    assert has_element?(view, "#overview-panel", "Observer lacks service-query capability")
    refute has_element?(view, "#overview-panel a", "View check result")

    base = "/next/coverage/#{reporting["id"]}"
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

    assert has_element?(view, "[data-panel-back-path='#{base}']")
    view |> element("[data-overview-close]") |> render_click()
    assert_patch(view, base)
    assert has_element?(view, "#overview-panel", "Runner decisions")

    view |> element("#overview-panel a", "Open as page") |> render_click()
    assert_patch(view, base <> "/full")
    assert has_element?(view, "#coverage-page-body table[aria-label='Runner decisions']")
    view |> element("#coverage-page-body a", "View check result") |> render_click()
    assert has_element?(view, "#overview-panel", "Critical")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    assert_patch(view, base <> "/full")
    refute has_element?(view, "#overview-panel")

    for prefix <- ["/next/coverage", "/next/expected"],
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
      {:ok, view, _} = live(build_conn(), "/next/incidents/loss/#{incident.id}" <> suffix)

      assert has_element?(view, root <> " h3", "Affected results")
      assert has_element?(view, root <> " h4", "Root disk")

      assert has_element?(
               view,
               root <> " a[href^='/next/expected/']",
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
    base = "/next/coverage/diagnostics/#{diagnostic["id"]}"

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
    {:ok, empty, _} = live(build_conn(), "/next")
    assert has_element?(empty, "#preview-onboarding")
    refute has_element?(empty, "#preview-unobserved")
    {:ok, invalid, _} = live(build_conn(), "/next/results/not-a-result?search=queue")
    assert has_element?(invalid, "#overview-panel-title", "Result unavailable")
    assert has_element?(invalid, "[data-overview-close][href='/next?search=queue']")
    {:ok, missing, _} = live(build_conn(), "/next/expected/" <> String.duplicate("f", 64))
    assert has_element?(missing, "#overview-panel-title", "Result unavailable")
  end

  test "filter picker rejects malformed events and values outside its suggestions" do
    {:ok, view, _} = live(build_conn(), "/next")
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
    {:ok, view, _} = live(build_conn(), "/next")
    assert has_element?(view, "#preview-no-attention", "No results currently need attention")
    assert has_element?(view, "#preview-healthy-results", "Service target")
    render_submit(element(view, "#overview-search"), %{"search" => "absent-target"})
    assert_patch(view, "/next?search=absent-target")
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
