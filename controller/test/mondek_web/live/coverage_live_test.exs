# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Coverage
  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint

  test "fresh retained results do not send unconfirmed declarations to collection diagnostics" do
    now = Monitoring.now()
    publication = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = F.activate(publication, now)
    assert disposition(F.sample(publication, "OK", 1, now)) == "current"

    assert {:ok, _} =
             Monitoring.inventory(
               publication |> Map.put("inventory_revision", 2) |> Map.delete("coverage"),
               now
             )

    [scope] = Coverage.scopes(%{}, now)["items"]
    {:ok, view, _} = live(build_conn(), "/coverage/" <> scope["id"])
    assert has_element?(view, "#coverage-observers a", "Inspect runner publication")
    refute has_element?(view, "#coverage-observers a", "Investigate measurement")
  end

  test "monitoring loss retains incident context through intended coverage and its publishing runner" do
    now = Monitoring.now()
    publication = F.publication([F.candidate(F.check(), false)])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    [scope] = Coverage.scopes(%{}, now)["items"]

    incident =
      Repo.insert!(%Mondek.MonitoringIncident{
        scope_key: "coverage:" <> publication["source_id"],
        scope_kind: "coverage",
        source_id: publication["source_id"],
        label: "Missing monitoring",
        opened_at: now,
        member_count: 1
      })

    Repo.insert!(%Mondek.MonitoringGap{
      key: scope["id"],
      scope_key: incident.scope_key,
      since_at: now,
      ready_at: now,
      details: %{
        "coverage_id" => scope["id"],
        "label" => "Expected result",
        "knowledge" => "no_selected_runner"
      }
    })

    origin = "/monitoring-incidents/#{incident.id}?members_page=1&status=open"
    {:ok, loss, _} = live(build_conn(), origin)

    {:ok, coverage, _} =
      loss |> element("#monitoring-members a") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(coverage, ".back[href='#{origin}']", "Back to monitoring incident")
    assert has_element?(coverage, "#coverage-observers", "Excluded from execution")

    {:ok, runner, _} =
      coverage
      |> element("#coverage-observers .actions a", "Inspect runner context")
      |> render_click()
      |> follow_redirect(build_conn())

    assert has_element?(runner, ".back", "Back to coverage")

    {:ok, coverage, _} =
      runner |> element(".back") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(coverage, ".back[href='#{origin}']", "Back to monitoring incident")
  end

  test "a never-installed node is visible with its exclusion and source guidance" do
    now = Monitoring.now()
    candidate = F.candidate(F.check("Root disk", "production", "Node B"), false)
    publication = F.publication([candidate], %{"runner_label" => "Node A"})
    assert {:ok, _} = Monitoring.inventory(publication, now)
    [scope] = Coverage.scopes(%{}, now)["items"]
    {:ok, view, _} = live(build_conn(), "/coverage")
    assert has_element?(view, "#coverage-scopes", "Node B")
    assert has_element?(view, "#coverage-scopes", "No selected runner")
    assert has_element?(view, "#coverage-scopes", "0 of 0 selected runners")
    assert has_element?(view, "#coverage-boundary", "nobody has declared remain unknown")
    assert has_element?(view, "#coverage-explanation", "Being selected to run is not proof")
    assert has_element?(view, "#coverage-explanation a[href='/checks']", "Checks")

    {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])
    assert has_element?(detail, "#coverage-observers", "Observer lacks service-query capability")
    assert has_element?(detail, "#coverage-observers", "Node A")
    refute has_element?(detail, "#coverage-observers a", "Inspect result")

    assert has_element?(
             detail,
             "#coverage-agent-prompts-coverage-text",
             "explicit Binding targets/environments"
           )
  end

  test "intended result titles avoid duplicate labels while preserving distinct outputs" do
    now = Monitoring.now()
    duplicate = F.check("Root disk") |> put_in(["outputs", Access.at(0), "label"], "Root disk")
    distinct = F.check("Backups") |> put_in(["outputs", Access.at(0), "label"], "Daily export")

    assert {:ok, _} =
             Monitoring.inventory(
               F.publication([F.candidate(duplicate, false), F.candidate(distinct, false)]),
               now
             )

    {:ok, list, _} = live(build_conn(), "/coverage")
    assert has_element?(list, "#coverage-scopes h3", "Root disk")
    refute has_element?(list, "#coverage-scopes h3", "Root disk · Root disk")
    assert has_element?(list, "#coverage-scopes h3", "Backups · Daily export")

    for scope <- Coverage.scopes(%{}, now)["items"] do
      {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])
      assert has_element?(detail, "#coverage-scope-detail h2", "Measurement coverage")

      expected =
        if scope["source_key"] == "Root disk", do: "Root disk", else: "Backups · Daily export"

      assert has_element?(detail, "h1", "Coverage")
      assert has_element?(detail, ".view-heading h2", expected)
      refute has_element?(detail, ".view-heading h2", "Root disk · Root disk")
    end
  end

  test "placement separates monitored environment from execution environment" do
    now = Monitoring.now()

    local =
      F.candidate(F.check("Backup service", "edge-node", "production"), false)
      |> Map.put(
        "exclusion_reason",
        "Requires execution in edge-node; runner executes in observer.example.test"
      )

    shared = F.candidate(F.check("Remote logs", "edge-node", "production"))

    publication =
      F.publication([local, shared])
      |> put_in(["coverage", "runner_context", "local_environment"], "observer.example.test")

    assert {:ok, _} = Monitoring.inventory(publication, now)

    for scope <- Coverage.scopes(%{}, now)["items"] do
      {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])
      assert has_element?(detail, "#coverage-scope-detail", "edge-node")

      assert has_element?(
               detail,
               "#coverage-observers",
               "Runner executes in: observer.example.test"
             )

      if scope["source_key"] == "Backup service" do
        assert has_element?(
                 detail,
                 "#coverage-observers",
                 "Requires execution in edge-node; runner executes in observer.example.test"
               )

        assert has_element?(detail, "#coverage-observers .badge", "Not selected here")
        refute has_element?(detail, "#coverage-observers a", "Inspect result")
      else
        assert has_element?(detail, "#coverage-observers", "Selected to execute")

        assert has_element?(
                 detail,
                 "#coverage-observers",
                 "Shared runners can monitor other environments"
               )

        refute has_element?(detail, "#coverage-observers", "Excluded from execution")
      end
    end
  end

  test "fresh Critical evidence and an unavailable peer show partial coverage with independent results" do
    now = Monitoring.now()
    one = F.publication([F.candidate(F.check())], %{"runner_label" => "Primary observer"})
    two = F.publication([F.candidate(F.check())], %{"runner_label" => "Other observer"})

    for publication <- [one, two] do
      assert {:ok, _} = Monitoring.inventory(publication, now)
      assert {:ok, _} = F.activate(publication, now)
    end

    assert disposition(F.sample(one, "CRIT", 1, now)) == "current"
    assert disposition(F.sample(two, "UNKNOWN", 1, now)) == "current"
    [scope] = Coverage.scopes(%{}, now)["items"]
    {:ok, list, _} = live(build_conn(), "/coverage?runner_id=" <> one["installation_id"])
    assert has_element?(list, "#coverage-scopes", "1 of 2 selected runners")
    assert render(list) =~ "include every runner declaring each result"

    return_path = "/coverage/" <> scope["id"] <> "?runner_id=" <> one["installation_id"]
    {:ok, detail, _} = live(build_conn(), return_path)
    assert has_element?(detail, "#coverage-scope-detail", "Partial runner coverage")

    assert has_element?(
             detail,
             "[data-runner-id='#{one["installation_id"]}']",
             "Last measured health: Critical"
           )

    assert has_element?(
             detail,
             "[data-runner-id='#{two["installation_id"]}']",
             "Collection unavailable"
           )

    refute has_element?(
             detail,
             "[data-runner-id='#{two["installation_id"]}']",
             "Last measured health"
           )

    assert has_element?(
             detail,
             "[data-runner-id='#{two["installation_id"]}'] a",
             "Investigate measurement"
           )

    refute has_element?(
             detail,
             "[data-runner-id='#{one["installation_id"]}'] a",
             "Investigate measurement"
           )

    navigation =
      detail
      |> element("[data-runner-id='#{one["installation_id"]}'] a", "Inspect result")
      |> render_click()

    {:ok, result, _} = follow_redirect(navigation, build_conn())
    assert has_element?(result, "a.back[href='#{return_path}']", "Back to coverage")
  end

  test "scopes page in bounded groups and preserve the list page through inspection" do
    candidates =
      for n <- 1..60,
          do: F.candidate(F.check("check-#{String.pad_leading(to_string(n), 3, "0")}"), false)

    assert {:ok, _} = Monitoring.inventory(F.publication(candidates), Monitoring.now())
    {:ok, list, _} = live(build_conn(), "/coverage?search=check-&page=2")

    assert Enum.count(
             list
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("[data-scope-id]")
           ) == 25

    assert has_element?(list, "#coverage-scopes", "60 matching intended results")
    assert has_element?(list, "#coverage-pages-top", "Page 2 of 3")
    refute has_element?(list, "#coverage-scopes", "check-001")
    navigation = list |> element("[data-scope-id]:first-of-type h3 a") |> render_click()
    {:ok, detail, _} = follow_redirect(navigation, build_conn())

    assert has_element?(
             detail,
             "a.back[href='/coverage?page=2&search=check-']",
             "All intended results"
           )
  end

  test "unsupported, downgraded and unbound declarations are distinct from empty coverage" do
    now = Monitoring.now()
    unsupported = F.publication([]) |> Map.delete("coverage")
    assert {:ok, _} = Monitoring.inventory(unsupported, now)
    known = F.publication([F.candidate(F.check(), false)], %{"runner_label" => "Downgraded"})
    assert {:ok, _} = Monitoring.inventory(known, now)
    downgraded = known |> Map.put("inventory_revision", 2) |> Map.delete("coverage")
    assert {:ok, _} = Monitoring.inventory(downgraded, now)

    unbound =
      F.candidate(F.check("Local template"), false)
      |> Map.merge(%{
        "environment" => nil,
        "environment_label" => nil,
        "scope_resolved" => false,
        "scope_reason" => "A monitored environment is required"
      })
      |> put_in(["outputs", Access.at(0), "target"], nil)

    assert {:ok, _} = Monitoring.inventory(F.publication([unbound]), now)
    {:ok, list, _} = live(build_conn(), "/coverage")

    assert has_element?(
             list,
             "#coverage-audit-warning",
             "Sources missing coverage support: 1"
           )

    assert has_element?(list, "#coverage-scopes", "Declarations unconfirmed")
    {:ok, publishers, _} = live(build_conn(), "/coverage/publishers")
    assert has_element?(publishers, "#coverage-publishers", "Intended checks unknown")
    assert has_element?(publishers, "#coverage-publishers", "Declarations unconfirmed")
    {:ok, diagnostics, _} = live(build_conn(), "/coverage/diagnostics")

    assert has_element?(
             diagnostics,
             "#coverage-diagnostics",
             "A monitored environment is required"
           )
  end

  test "source replacement retains earlier measurements as context without claiming desired coverage" do
    now = Monitoring.now()
    publication = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = F.activate(publication, now)
    assert disposition(F.sample(publication, "OK", 1, now)) == "current"
    [scope] = Coverage.scopes(%{}, now)["items"]

    newer =
      Map.merge(publication, %{
        "inventory_revision" => 2,
        "source_revision" => String.duplicate("f", 64)
      })

    assert {:ok, _} = Monitoring.inventory(newer, now)
    {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])
    assert has_element?(detail, "#coverage-scope-detail", "Awaiting current measurement")

    assert has_element?(
             detail,
             "#coverage-observers",
             "Fresh evidence belongs to an earlier configuration"
           )

    assert has_element?(detail, "#coverage-observers", "Last measured health: Healthy")
    refute has_element?(detail, "#coverage-observers .badge", "Fresh measurement")
  end

  test "a fresh observer does not hide an unconfirmed publisher and supported empty catalogues are explicit" do
    now = Monitoring.now()
    active = F.publication([F.candidate(F.check())])
    excluded = F.publication([F.candidate(F.check(), false)])

    for publication <- [active, excluded],
        do: assert({:ok, _} = Monitoring.inventory(publication, now))

    assert {:ok, _} = F.activate(active, now)
    assert disposition(F.sample(active, "OK", 1, now)) == "current"

    assert {:ok, _} =
             Monitoring.inventory(
               excluded |> Map.put("inventory_revision", 2) |> Map.delete("coverage"),
               now
             )

    [scope] = Coverage.scopes(%{}, now)["items"]
    {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])
    assert has_element?(detail, "#coverage-scope-detail", "Partial runner coverage")

    assert has_element?(
             detail,
             "#coverage-scope-detail",
             "Fresh measurements: 1 of 1 selected runners"
           )

    assert has_element?(
             detail,
             "#coverage-scope-detail",
             "1 last-known declarations remain unconfirmed"
           )

    assert has_element?(detail, "#coverage-scope-detail", "or has an unconfirmed declaration")

    empty = excluded |> Map.put("inventory_revision", 3) |> put_in(["coverage", "candidates"], [])
    assert {:ok, _} = Monitoring.inventory(empty, now)
    send(detail.pid, :tick)
    assert has_element?(detail, "#coverage-scope-detail", "Fresh measurements available")
    {:ok, publishers, _} = live(build_conn(), "/coverage/publishers")

    assert has_element?(
             publishers,
             "#coverage-publishers",
             "This runner explicitly declares no checks for this source"
           )
  end

  test "unknown scope is a recoverable empty state and filter values retain literal identifiers" do
    {:ok, missing, _} = live(build_conn(), "/coverage/" <> String.duplicate("a", 64))
    assert has_element?(missing, "#coverage-scope-missing", "no longer declared")
    {:ok, view, _} = live(build_conn(), "/coverage")

    view
    |> form("#coverage-filters", search: "1", source_id: "1", environment: "1", status: "missing")
    |> render_submit()

    assert_patch(view, "/coverage?environment=1&search=1&source_id=1&status=missing")
    assert has_element?(view, "#coverage-source[value='1']")
  end

  test "nested URL filters are ignored and pending edits survive background refresh and recovery" do
    {:ok, view, _} = live(build_conn(), "/coverage?search[value]=x&page[bad]=1")
    assert has_element?(view, "#coverage-filters")
    refute has_element?(view, "#coverage-search[value='x']")

    view
    |> form("#coverage-filters", search: "Pending check", environment: "staging")
    |> render_change()

    send(view.pid, :tick)
    assert has_element?(view, "#coverage-search[value='Pending check']")
    assert has_element?(view, "#coverage-environment[value='staging']")

    render_hook(view, "recover_filters", %{
      "search" => "Recovered check",
      "environment" => "production"
    })

    assert has_element?(view, "#coverage-search[value='Recovered check']")
    refute has_element?(view, "#coverage-scopes", "Recovered check")
  end

  test "unresolved declarations retain downgrade provenance and prompts distinguish exact target kinds" do
    now = Monitoring.now()

    candidate =
      F.candidate(F.check(), false)
      |> Map.merge(%{
        "scope_resolved" => false,
        "scope_reason" => "Custom metadata cannot resolve excluded scope"
      })

    publication = F.publication([candidate])
    assert {:ok, _} = Monitoring.inventory(publication, now)

    assert {:ok, _} =
             Monitoring.inventory(
               publication |> Map.put("inventory_revision", 2) |> Map.delete("coverage"),
               now
             )

    {:ok, unresolved, _} = live(build_conn(), "/coverage/diagnostics")
    assert has_element?(unresolved, "#coverage-diagnostics", "Last-known declaration")
    assert render(unresolved) =~ "custom metadata that cannot describe excluded checks"

    for kind <- ["host", "service"] do
      item =
        F.candidate(F.check("shared-key"), false)
        |> put_in(["outputs", Access.at(0), "target", "kind"], kind)

      assert {:ok, _} = Monitoring.inventory(F.publication([item]), now)
    end

    scopes = Coverage.scopes(%{}, now)["items"]
    assert length(scopes) == 2

    for scope <- scopes do
      {:ok, detail, _} = live(build_conn(), "/coverage/" <> scope["id"])

      prompt =
        detail
        |> element("#coverage-agent-prompts-coverage-text")
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.text()

      assert prompt =~ ~s("target_kind":"#{scope["target"]["kind"]}")
      assert prompt =~ ~s("controller_url":"http://www.example.com")
    end
  end
end
