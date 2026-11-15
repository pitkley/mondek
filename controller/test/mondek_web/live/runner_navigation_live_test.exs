# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnerNavigationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{CoverageFixtures, Inspection, MonitoringIncident}
  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  test "runner result navigation keeps scope, origin and stacked evidence" do
    [first, _second] = publish_two()
    runner_id = first["installation_id"]
    runner_page = "/runners/#{runner_id}/full"
    {:ok, runner, _} = live(build_conn(), runner_page)

    [href] =
      runner
      |> element("#runner-measurements a", "Inspect all results")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    origin = URI.decode_query(URI.parse(href).query)["return_to"]
    assert URI.parse(origin).path == runner_page

    navigation =
      runner |> element("#runner-measurements a", "Inspect all results") |> render_click()

    {:ok, checks, _} = follow_redirect(navigation, build_conn())
    assert has_element?(checks, "#preview-chip-runner_id", "Observer one")
    assert row_count(checks, "#preview-check-results") == 1
    assert has_element?(checks, "#preview-check-results", "Check one")
    refute has_element?(checks, "#preview-check-results", "Check two")
    [result] = Inspection.preview_checks(%{"runner_id" => runner_id}, Monitoring.now()).items
    checks |> element("#open-result-#{result["id"]}") |> render_click()
    assert has_element?(checks, "#overview-panel", "Check one")

    checks
    |> element("#overview-panel table[aria-label='Collection'] a", "Observer one")
    |> render_click()

    assert has_element?(checks, "#overview-panel #runner-detail", runner_id)
    checks |> element("#overview-panel a[data-overview-close]") |> render_click()
    assert has_element?(checks, "#overview-panel", "Check one")
    assert has_element?(checks, "#preview-chip-runner_id", "Observer one")
    checks |> element("#overview-panel a[data-overview-close]") |> render_click()
    assert has_element?(checks, "a[href='#{origin}']")
    render_hook(checks, "filter_open", %{"field" => "source_id"})
    render_hook(checks, "filter_select", %{"key" => first["source_id"], "kind" => ""})
    assert has_element?(checks, "#preview-chip-source_id", first["source_id"])
    assert row_count(checks, "#preview-check-results") == 1
    assert has_element?(checks, "a[href='#{origin}']")
  end

  test "runner coverage links retain exact source and allow removing both chips" do
    [first, _second] = publish_two()
    runner_id = first["installation_id"]
    {:ok, runner, _} = live(build_conn(), "/runners/#{runner_id}/full")

    navigation =
      runner
      |> element("#runner-publications a", "Inspect declarations and placement")
      |> render_click()

    {:ok, coverage, _} = follow_redirect(navigation, build_conn())
    assert has_element?(coverage, "#preview-chip-runner_id", "Observer one")
    assert has_element?(coverage, "#preview-chip-source_id", first["source_id"])
    assert row_count(coverage, "table[aria-label='Declared results']") == 1

    coverage
    |> element("#preview-chip-runner_id a[aria-label='Remove Runner filter']")
    |> render_click()

    refute has_element?(coverage, "#preview-chip-runner_id")
    assert row_count(coverage, "table[aria-label='Declared results']") == 1

    coverage
    |> element("#preview-chip-source_id a[aria-label='Remove Source filter']")
    |> render_click()

    assert row_count(coverage, "table[aria-label='Declared results']") == 2
  end

  test "monitoring loss runner scope is visible and removable" do
    [first, second] = publish_two()
    now = Monitoring.now()

    for publication <- [first, second] do
      Repo.insert!(%MonitoringIncident{
        id: Ecto.UUID.generate(),
        runner_id: publication["installation_id"],
        source_id: nil,
        scope_kind: "runner",
        scope_key: "runner:" <> publication["installation_id"],
        member_count: 1,
        label: publication["runner_label"] <> " lost monitoring",
        opened_at: now,
        status: "open",
        member_snapshot: []
      })
    end

    path =
      "/incidents?" <>
        URI.encode_query(%{"type" => "loss", "runner_id" => first["installation_id"]})

    {:ok, incidents, _} = live(build_conn(), path)
    assert has_element?(incidents, "#preview-chip-runner_id", "Observer one")
    assert row_count(incidents, "#incidents-unacknowledged table") == 1
    assert has_element?(incidents, "#incidents-unacknowledged table", "Observer one")
    refute has_element?(incidents, "#incidents-unacknowledged table", "Observer two")

    incidents
    |> element("#preview-chip-runner_id a[aria-label='Remove Runner filter']")
    |> render_click()

    refute has_element?(incidents, "#preview-chip-runner_id")
    assert row_count(incidents, "#incidents-unacknowledged table") == 2
  end

  defp publish_two do
    now = Monitoring.now()

    for suffix <- ["one", "two"] do
      candidate =
        CoverageFixtures.candidate(
          CoverageFixtures.check("Check #{suffix}", "production", "Target #{suffix}")
        )

      p =
        CoverageFixtures.publication([candidate], %{
          "source_id" => "source-#{suffix}",
          "runner_label" => "Observer #{suffix}"
        })

      assert {:ok, _} = Monitoring.inventory(p, now)
      assert {:ok, _} = CoverageFixtures.activate(p, now)
      assert disposition(CoverageFixtures.sample(p, "OK", 1, now)) == "current"
      p
    end
  end

  defp row_count(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("tbody > tr")
      |> Enum.count()
end
