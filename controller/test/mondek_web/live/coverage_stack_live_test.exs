# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageStackLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, CoverageFixtures, MonitoringIncident, MonitoringLoss}
  alias MondekWeb.InvestigationTrail
  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  test "declared results have the same evidence, identity and related links on either surface" do
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

    for scope <- Coverage.scopes(%{}, now)["items"],
        prefix <- ["/coverage", "/expected"],
        {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#coverage-page-body"}] do
      {:ok, view, _} = live(build_conn(), prefix <> "/" <> scope["id"] <> suffix)
      assert has_element?(view, root <> " table[aria-label='Coverage']")
      assert has_element?(view, root <> " table[aria-label='Runner decisions']")

      assert has_element?(
               view,
               root <> " table[aria-label='Declared-result identity']",
               scope["id"]
             )

      assert has_element?(view, root <> " a[href*='runner%3A#{publication["installation_id"]}']")

      assert has_element?(
               view,
               root <> " a[href^='/coverage/publishers/']",
               "Review source declaration"
             )

      if scope["status"] == "missing" do
        assert has_element?(view, root, "No runner selected")
        refute has_element?(view, root <> " a", "View check result")
      else
        assert has_element?(view, root, "Reporting")
        assert has_element?(view, root <> " a", "View check result")
      end
    end
  end

  test "coverage result and runner relationships stay in the same investigation including full roots" do
    now = Monitoring.now()

    publication =
      CoverageFixtures.publication([CoverageFixtures.candidate(CoverageFixtures.check())])

    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = CoverageFixtures.activate(publication, now)
    assert disposition(CoverageFixtures.sample(publication, "CRIT", 1, now)) == "current"
    [scope] = Coverage.scopes(%{}, now)["items"]

    for suffix <- ["", "/full"] do
      path = "/coverage/" <> scope["id"] <> suffix
      root = if suffix == "", do: "#overview-panel", else: "#coverage-page-body"
      {:ok, view, _} = live(build_conn(), path)

      view
      |> element(root <> " a[href*='runner%3A#{publication["installation_id"]}']")
      |> render_click()

      assert has_element?(view, "#overview-panel #runner-detail")
      view |> element("[data-overview-close]") |> render_click()
      assert has_element?(view, root <> " table[aria-label='Coverage']")
      view |> element(root <> " a", "View check result") |> render_click()
      assert has_element?(view, "#overview-panel", "Critical")
      view |> element("#overview-panel a", "View incident") |> render_click()
      assert has_element?(view, "#overview-panel", "Recorded failure")
      view |> element("#overview-panel a", "View latest check result") |> render_click()
      assert has_element?(view, "#overview-panel", "Check result")
      view |> element("[data-overview-close]") |> render_click()
      assert has_element?(view, root <> " table[aria-label='Coverage']")
    end
  end

  test "monitoring-loss incident opens its exact declared result in place and preserves its draft" do
    now = Monitoring.now()
    earlier = DateTime.add(now, -MonitoringLoss.grace_seconds() - 1)

    publication =
      CoverageFixtures.publication([CoverageFixtures.candidate(CoverageFixtures.check(), false)])

    assert {:ok, _} = Monitoring.inventory(publication, earlier)
    assert {:ok, _} = MonitoringLoss.reconcile(earlier)
    assert {:ok, _} = MonitoringLoss.reconcile(now)
    incident = Repo.get_by!(MonitoringIncident, scope_kind: "coverage", status: "open")
    [scope] = Coverage.scopes(%{}, now)["items"]

    for suffix <- ["", "/full"] do
      {:ok, view, _} = live(build_conn(), "/incidents/loss/#{incident.id}" <> suffix)

      view
      |> form("#preview-incident-ack-form", note: "Investigating placement")
      |> render_change()

      view |> element("a", "Review expected monitoring") |> render_click()
      assert has_element?(view, "[data-active-entity='coverage:#{scope["id"]}']")
      assert has_element?(view, "#overview-panel", "No runner selected")
      view |> element("[data-overview-close]") |> render_click()
      assert has_element?(view, "textarea[name=note]", "Investigating placement")
    end
  end

  test "diagnostic pages are complete, share chip filtering and expose the same details in both surfaces" do
    now = Monitoring.now()

    candidates =
      for index <- 1..27,
          do: unresolved("Unresolved #{String.pad_leading(to_string(index), 2, "0")}")

    publication =
      CoverageFixtures.publication(candidates, %{"runner_label" => "Diagnostics observer"})

    assert {:ok, _} = Monitoring.inventory(publication, now)
    [first | _] = Coverage.diagnostics(%{}, now)["items"]
    assert is_integer(first["id"])
    {:ok, view, _} = live(build_conn(), "/coverage")
    assert has_element?(view, "table[aria-label='Runner diagnostics'] tbody tr:nth-child(25)")
    refute has_element?(view, "table[aria-label='Runner diagnostics'] tbody tr:nth-child(26)")

    view
    |> element("nav[aria-label='Runner diagnostic pages'] a[aria-label='Page 2']")
    |> render_click()

    assert has_element?(view, "table[aria-label='Runner diagnostics'] tbody tr:nth-child(2)")
    refute has_element?(view, "table[aria-label='Runner diagnostics'] tbody tr:nth-child(3)")
    refute has_element?(view, "a[href='/coverage/diagnostics']")
    render_hook(view, "search", %{"search" => "Unresolved 27"})
    assert has_element?(view, "table[aria-label='Runner diagnostics']", "Unresolved 27")
    refute has_element?(view, "table[aria-label='Runner diagnostics'] tbody tr:nth-child(2)")
    refute has_element?(view, "nav[aria-label='Runner diagnostic pages']")
    render_hook(view, "search", %{"search" => "No such diagnostic"})

    assert has_element?(
             view,
             "#preview-coverage-runner-diagnostics",
             "No runner diagnostics match these filters"
           )

    for {suffix, root} <- [{"", "#overview-panel"}, {"/full", "#coverage-page-body"}] do
      {:ok, detail, _} = live(build_conn(), "/coverage/diagnostics/#{first["id"]}" <> suffix)

      assert has_element?(
               detail,
               root <> " table[aria-label='Diagnostic details']",
               "Declare a monitored environment"
             )

      assert has_element?(
               detail,
               root <> " table[aria-label='Declaration identity']",
               to_string(first["id"])
             )

      detail |> element(root <> " a", "Inspect runner setup") |> render_click()
      assert has_element?(detail, "#overview-panel #runner-detail", "Diagnostics observer")
      detail |> element("[data-overview-close]") |> render_click()
      assert has_element?(detail, root <> " table[aria-label='Diagnostic details']")
    end
  end

  test "diagnostic filters apply to known scope fields before paging and searching includes runner names" do
    now = Monitoring.now()

    known =
      unresolved("Known target")
      |> Map.put("environment", "production")
      |> Map.put("environment_label", "Production")

    unknown = unresolved("Unknown target") |> put_in(["outputs", Access.at(0), "target"], nil)

    publication =
      CoverageFixtures.publication([known, unknown], %{"runner_label" => "Diagnostic fleet"})

    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert Coverage.diagnostics(%{"environment" => "production"}, now)["total"] == 1

    assert Coverage.diagnostics(%{"target_kind" => "service", "target_key" => "service"}, now)[
             "total"
           ] == 1

    assert Coverage.diagnostics(%{"search" => "Diagnostic fleet"}, now)["total"] == 2
    assert Coverage.diagnostics(%{"search" => "no match"}, now)["unfiltered_total"] == 2
    assert Enum.any?(Mondek.CoverageFilters.options("environment", ""), &(&1.key == "production"))

    assert Enum.any?(
             Mondek.CoverageFilters.options("target", ""),
             &(&1.key == "service" && &1.kind == "service")
           )

    assert Mondek.CoverageFilters.options("environment", "", {"unknown-environment", ""}) == []
    assert Mondek.CoverageFilters.options("target", "", {"unknown-target", "service"}) == []
  end

  test "observer pages stay with each declared-result identity through deduplication, history and recovery" do
    now = Monitoring.now()

    for index <- 1..27 do
      publication =
        CoverageFixtures.publication(
          [
            CoverageFixtures.candidate(CoverageFixtures.check("First scope"), false),
            CoverageFixtures.candidate(CoverageFixtures.check("Second scope"), false)
          ],
          %{"runner_label" => "Observer #{String.pad_leading(to_string(index), 2, "0")}"}
        )

      assert {:ok, _} = Monitoring.inventory(publication, now)
    end

    [first, second] = Coverage.scopes(%{}, now)["items"]
    base = "/coverage/" <> first["id"]
    {:ok, view, _} = live(build_conn(), base)

    view
    |> element("nav[aria-label='Runner decision pages'] a[aria-label='Page 2']")
    |> render_click()

    first_page = current_page_link(view)

    assert has_element?(
             view,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 26"
           )

    second_path =
      InvestigationTrail.path(first_page, [{"coverage", first["id"]}, {"coverage", second["id"]}])

    render_patch(view, second_path)

    assert has_element?(
             view,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 01"
           )

    refute has_element?(
             view,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 26"
           )

    view
    |> element("nav[aria-label='Runner decision pages'] a[aria-label='Page 2']")
    |> render_click()

    snapshot = input_value(view, "#investigation-stack-recovery input[name=snapshot]")
    saved_second = current_page_link(view)
    view |> element("[data-overview-close]") |> render_click()

    assert has_element?(
             view,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 26"
           )

    render_patch(view, saved_second)

    assert has_element?(
             view,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 26"
           )

    {:ok, recovered, _} = live(build_conn(), saved_second)

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    recovered |> element("[data-overview-close]") |> render_click()

    assert has_element?(
             recovered,
             "#overview-panel table[aria-label='Runner decisions']",
             "Observer 26"
           )

    assert URI.decode_query(URI.parse(current_page_link(recovered)).query)["coverage_entity"] ==
             first["id"]
  end

  test "scope hashes and diagnostic integer identities reject the wrong shapes without fabricating evidence" do
    assert InvestigationTrail.identity({"coverage", String.duplicate("a", 64)}) ==
             {"coverage", String.duplicate("a", 64)}

    assert InvestigationTrail.identity({"diagnostic", "42"}) == {"diagnostic", "42"}
    assert InvestigationTrail.identity({"diagnostic", "00042"}) == {"diagnostic", "42"}

    for identity <- [
          {"coverage", Ecto.UUID.generate()},
          {"coverage", String.duplicate("A", 64)},
          {"diagnostic", "-1"},
          {"diagnostic", "0"},
          {"diagnostic", Ecto.UUID.generate()},
          {"diagnostic", String.duplicate("9", 20)}
        ],
        do: assert(is_nil(InvestigationTrail.identity(identity)))

    {:ok, missing, _} =
      live(build_conn(), "/coverage/" <> String.duplicate("f", 64) <> "/full")

    assert has_element?(missing, "#coverage-page-body", "Declaration unavailable")
    refute has_element?(missing, "table[aria-label='Coverage']")
    {:ok, diagnostic, _} = live(build_conn(), "/coverage/diagnostics/9223372036854775807")
    assert has_element?(diagnostic, "#overview-panel", "Diagnostic unavailable")
  end

  defp unresolved(name) do
    CoverageFixtures.candidate(CoverageFixtures.check(name), false)
    |> Map.merge(%{
      "environment" => nil,
      "environment_label" => nil,
      "scope_resolved" => false,
      "scope_reason" => "Declare a monitored environment"
    })
  end

  defp current_page_link(view),
    do:
      view
      |> element("#overview-panel")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#overview-panel")
      |> LazyHTML.attribute("data-panel-path")
      |> hd()

  defp input_value(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()
end
