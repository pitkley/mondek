# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Coverage
  alias Mondek.CoverageFixtures, as: F
  @endpoint MondekWeb.Endpoint

  test "retained fresh results do not turn unconfirmed declarations into confirmed coverage" do
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
    {:ok, view, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
    assert has_element?(view, "table[aria-label='Runner decisions']", "Declaration unconfirmed")
    assert has_element?(view, "a", "Review source declaration")

    refute has_element?(
             view,
             "#preview-coverage-facts",
             "Every selected runner has a current measurement"
           )
  end

  test "monitoring loss opens its exact declaration and runner within one investigation" do
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

    {:ok, view, _} = live(build_conn(), "/incidents/loss/#{incident.id}/full")
    view |> element("a[href*='coverage%3A#{scope["id"]}']") |> render_click()
    assert has_element?(view, "#overview-panel", "Not selected")

    view
    |> element("#overview-panel a[href*='runner%3A#{publication["installation_id"]}']")
    |> render_click()

    assert has_element?(view, "#overview-panel #runner-detail")
    assert has_element?(view, "[data-panel-back-path*='coverage%3A#{scope["id"]}']")
  end

  test "a never-installed node retains exclusion evidence and source guidance" do
    now = Monitoring.now()
    candidate = F.candidate(F.check("Root disk", "production", "Node B"), false)
    publication = F.publication([candidate], %{"runner_label" => "Node A"})
    assert {:ok, _} = Monitoring.inventory(publication, now)
    [scope] = Coverage.scopes(%{}, now)["items"]
    {:ok, list, _} = live(build_conn(), "/coverage")
    assert has_element?(list, "table[aria-label='Declared results']", "Node B")
    assert has_element?(list, "table[aria-label='Declared results']", "No runner selected")
    {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")

    assert has_element?(
             detail,
             "table[aria-label='Runner decisions']",
             "Observer lacks service-query capability"
           )

    assert has_element?(detail, "table[aria-label='Runner decisions']", "Node A")
    refute has_element?(detail, "table[aria-label='Runner decisions'] a", "View check result")

    assert has_element?(
             detail,
             "#coverage-agent-prompts-coverage-text",
             "explicit Binding targets/environments"
           )
  end

  test "declared result labels avoid duplicate names while retaining distinct output labels" do
    now = Monitoring.now()
    duplicate = F.check("Root disk") |> put_in(["outputs", Access.at(0), "label"], "Root disk")
    distinct = F.check("Backups") |> put_in(["outputs", Access.at(0), "label"], "Daily export")

    assert {:ok, _} =
             Monitoring.inventory(
               F.publication([F.candidate(duplicate, false), F.candidate(distinct, false)]),
               now
             )

    {:ok, list, _} = live(build_conn(), "/coverage")
    assert has_element?(list, "table[aria-label='Declared results']", "Root disk")
    refute has_element?(list, "table[aria-label='Declared results']", "Root disk · Root disk")
    assert has_element?(list, "table[aria-label='Declared results']", "Backups · Daily export")

    for scope <- Coverage.scopes(%{}, now)["items"] do
      {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
      assert has_element?(detail, "#preview-coverage-facts")
      refute render(detail) =~ "Root disk · Root disk"
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
      {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
      assert has_element?(detail, "#preview-coverage-identity", "edge-node")

      assert has_element?(
               detail,
               "table[aria-label='Observer identity']",
               "observer.example.test"
             )

      if scope["source_key"] == "Backup service" do
        assert has_element?(
                 detail,
                 "table[aria-label='Runner decisions']",
                 "Requires execution in edge-node"
               )

        assert has_element?(detail, "table[aria-label='Runner decisions']", "Not selected")
      else
        assert has_element?(
                 detail,
                 "table[aria-label='Runner decisions']",
                 "Waiting for measurement"
               )
      end
    end
  end

  test "critical evidence and an unavailable peer retain independent result states" do
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
    {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
    assert has_element?(detail, "#preview-coverage-facts", "Partial coverage")
    assert has_element?(detail, "#preview-coverage-facts", "1 of 2")
    assert has_element?(detail, "table[aria-label='Runner decisions']", "Collection unavailable")

    [observer] =
      Coverage.observers(scope["id"], %{}, now)["items"]
      |> Enum.filter(&(&1["runner_id"] == one["installation_id"]))

    detail |> element("a[href*='result%3A#{observer["stream_id"]}']") |> render_click()
    assert has_element?(detail, "#overview-panel", "Critical")
  end

  test "bounded declaration pages retain their page when opening and reopening details" do
    candidates =
      for n <- 1..60,
          do: F.candidate(F.check("check-#{String.pad_leading(to_string(n), 3, "0")}"), false)

    assert {:ok, _} = Monitoring.inventory(F.publication(candidates), Monitoring.now())
    {:ok, view, _} = live(build_conn(), "/coverage?search=check-&page=2")
    assert count(view, "table[aria-label='Declared results'] > tbody > tr") == 25
    assert has_element?(view, "nav[aria-label='Declared result pages'] [aria-current=page]", "2")

    view
    |> element("table[aria-label='Declared results'] tbody tr:first-child a[data-overview-open]")
    |> render_click()

    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["page"] == "2"
    {:ok, reopened, _} = live(build_conn(), path)
    assert has_element?(reopened, "#overview-panel #preview-coverage-facts")
    assert count(reopened, "table[aria-label='Declared results'] > tbody > tr") == 25
  end

  test "unsupported downgraded and unresolved catalogues remain distinct from empty coverage" do
    now = Monitoring.now()
    assert {:ok, _} = Monitoring.inventory(F.publication([]) |> Map.delete("coverage"), now)
    known = F.publication([F.candidate(F.check(), false)], %{"runner_label" => "Downgraded"})
    assert {:ok, _} = Monitoring.inventory(known, now)

    assert {:ok, _} =
             Monitoring.inventory(
               known |> Map.put("inventory_revision", 2) |> Map.delete("coverage"),
               now
             )

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
    {:ok, view, _} = live(build_conn(), "/coverage")
    assert has_element?(view, ".preview-coverage-audit")
    assert has_element?(view, "table[aria-label='Declared results']", "Declarations unconfirmed")

    assert has_element?(
             view,
             "#preview-coverage-runner-diagnostics",
             "A monitored environment is required"
           )

    {:ok, publishers, _} = live(build_conn(), "/coverage/publishers")
    assert render(publishers) =~ "Catalogue not supported"
    assert render(publishers) =~ "Catalogue needs confirmation"
  end

  test "source replacement retains old measurement without claiming current configuration coverage" do
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
    {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
    assert has_element?(detail, "table[aria-label='Runner decisions']", "earlier configuration")

    refute has_element?(
             detail,
             "#preview-coverage-facts",
             "Every selected runner has a current measurement"
           )

    assert has_element?(detail, "table[aria-label='Runner decisions'] a", "View check result")
  end

  test "one fresh observer does not hide an unconfirmed peer and empty catalogues stay explicit" do
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
    {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")
    assert has_element?(detail, "#preview-coverage-facts", "Partial coverage")
    assert has_element?(detail, "#preview-coverage-facts", "1 of 1 selected runner reporting")
    assert has_element?(detail, "#preview-coverage-facts", "Unconfirmed")
    empty = excluded |> Map.put("inventory_revision", 3) |> put_in(["coverage", "candidates"], [])
    assert {:ok, _} = Monitoring.inventory(empty, now)
    send(detail.pid, :tick)

    assert has_element?(
             detail,
             "#preview-coverage-facts",
             "Every selected runner has a current measurement"
           )

    assert Enum.any?(
             Coverage.publishers(%{}, now)["items"],
             &(&1["declarations"] == 0 && &1["audit_status"] == "confirmed")
           )
  end

  test "unknown declarations recover safely and literal filter identifiers stay intact" do
    {:ok, missing, _} = live(build_conn(), "/coverage/#{String.duplicate("a", 64)}/full")
    assert has_element?(missing, "h1", "Declaration unavailable")
    {:ok, view, _} = live(build_conn(), "/coverage?search=1&source_id=1&environment=1")
    assert has_element?(view, "form[phx-hook='PreviewFilterPicker'][data-search='1']")
    assert has_element?(view, ".preview-filter-chip", "1")

    assert Mondek.CoverageFilters.params(%{"source_id" => "1", "environment" => "1"}) == %{
             "source_id" => "1",
             "environment" => "1"
           }
  end

  test "nested query filters are ignored while applied filters survive ticks and reopening" do
    {:ok, view, _} = live(build_conn(), "/coverage?search[value]=x&page[bad]=1")
    assert has_element?(view, "form[phx-hook='PreviewFilterPicker']")
    refute has_element?(view, ".preview-search-token", "x")
    render_change(view, "search", %{"search" => "Pending check"})
    path = assert_patch(view)
    send(view.pid, :tick)
    assert has_element?(view, "form[phx-hook='PreviewFilterPicker'][data-search='Pending check']")
    render_change(view, "search", %{"search" => "Pending check"})
    refute_patched(view)
    {:ok, reopened, _} = live(build_conn(), path)

    assert has_element?(
             reopened,
             "form[phx-hook='PreviewFilterPicker'][data-search='Pending check']"
           )
  end

  test "unresolved declarations retain downgrade provenance and prompts distinguish target kinds" do
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

    {:ok, unresolved, _} = live(build_conn(), "/coverage")

    assert has_element?(
             unresolved,
             "#preview-coverage-runner-diagnostics",
             "Custom metadata cannot resolve excluded scope"
           )

    for kind <- ["host", "service"] do
      item =
        F.candidate(F.check("shared-key"), false)
        |> put_in(["outputs", Access.at(0), "target", "kind"], kind)

      assert {:ok, _} = Monitoring.inventory(F.publication([item]), now)
    end

    scopes = Coverage.scopes(%{}, now)["items"]
    assert length(scopes) == 2

    for scope <- scopes do
      {:ok, detail, _} = live(build_conn(), "/coverage/#{scope["id"]}/full")

      assert has_element?(
               detail,
               "#coverage-agent-prompts-coverage-text",
               ~s("target_kind":"#{scope["target"]["kind"]}")
             )

      assert has_element?(
               detail,
               "#coverage-agent-prompts-coverage-text",
               ~s("controller_url":"#{MondekWeb.Endpoint.url()}")
             )
    end
  end

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
end
