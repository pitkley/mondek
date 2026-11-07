# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, CoverageFixtures, Inspection}

  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

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
    {:ok, incidents, _} = live(build_conn(), "/next/incidents")

    render_hook(incidents, "filter_open", %{"field" => "type"})
    render_hook(incidents, "filter_select", %{"key" => "health", "kind" => ""})
    assert_patch(incidents, "/next/incidents?type=health")
    render_click(element(incidents, "#preview-incident-health-#{id} a"))
    assert_patch(incidents, "/next/incidents/health/#{id}?type=health")
    assert has_element?(incidents, "#incident-heading", "Queue depth")
    assert has_element?(incidents, "main", "Measured CRIT")
    assert has_element?(incidents, "main a", "Open current result evidence")
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
