# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NavigationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, MonitoringIncident, SourceInventory}
  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint

  test "every page uses global unacknowledged counts even when its own filtered list is empty" do
    %{scope: scope, publication: publication, loss: loss} = installation()

    routes = [
      {"/", "/"},
      {"/checks?search=not-present&page=8", "/checks"},
      {"/coverage?search=not-present&page=8", "/coverage"},
      {"/coverage/publishers?search=not-present", "/coverage"},
      {"/coverage/diagnostics?source_id=not-present", "/coverage"},
      {"/coverage/#{scope["id"]}", "/coverage"},
      {"/coverage/publishers/#{publication.id}", "/coverage"},
      {"/incidents?status=closed", "/incidents"},
      {"/monitoring-incidents?status=closed", "/incidents"},
      {"/monitoring-incidents/#{loss.id}", "/incidents"},
      {"/maintenance?status=ended", "/maintenance"},
      {"/maintenance/new", "/maintenance"},
      {"/configuration", "/configuration"},
      {"/configuration/rules", "/configuration"},
      {"/configuration/rules/new", "/configuration"},
      {"/configuration/10000000-0000-4000-8000-000000000001", "/configuration"},
      {"/runners?search=not-present", "/runners"},
      {"/notifications?notification_status=exhausted", "/notifications"},
      {"/guide", "/guide"}
    ]

    for {path, active} <- routes do
      {:ok, view, _} = live(build_conn(), path)
      assert_counts(view, 1, 1)
      assert has_element?(view, ".sidebar .nav a[aria-current=page][href='#{active}']"), path
      assert has_element?(view, "a.skip-link[href='#main-content']"), path
      assert has_element?(view, "#main-content[tabindex='-1']"), path
      GenServer.stop(view.pid)
    end
  end

  test "refresh updates counts without replacing drafts in independent page shells" do
    %{health: health, loss: loss, publication: publication, check: check} = installation()
    {:ok, coverage, _} = live(build_conn(), "/coverage")
    {:ok, monitoring, _} = live(build_conn(), "/monitoring-incidents/#{loss.id}")
    {:ok, publisher, _} = live(build_conn(), "/coverage/publishers/#{publication.id}")
    {:ok, maintenance, _} = live(build_conn(), "/maintenance/new?check_id=#{check.id}")
    {:ok, rules, _} = live(build_conn(), "/configuration/rules/new?check_id=#{check.id}")

    coverage |> form("#coverage-filters", search: "Unsubmitted search") |> render_change()

    monitoring
    |> form("#monitoring-acknowledgement-form", note: "Investigate after lunch")
    |> render_change()

    publisher
    |> form("#publisher-lifecycle-form", lifecycle: %{reason: "Review old deployment"})
    |> render_change()

    maintenance
    |> form("#maintenance-form", window: %{name: "Weekend repairs"})
    |> render_change()

    rules
    |> form("#configuration-rule-form", rule: %{name: "Production limits"})
    |> render_change()

    now = Monitoring.now()
    assert {:ok, _} = reviewed_acknowledgement_fixture(health.id, 3600, "Investigating", now)

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(
               loss.id,
               3600,
               "Investigating collection",
               now
             )

    views = [coverage, monitoring, publisher, maintenance, rules]

    for view <- views do
      send(view.pid, :tick)
      assert_counts(view, 0, 0)
    end

    assert has_element?(coverage, "#coverage-search[value='Unsubmitted search']")
    assert has_element?(monitoring, "#monitoring-ack-note", "Investigate after lunch")
    assert has_element?(publisher, "#publisher-reason", "Review old deployment")
    assert has_element?(maintenance, "#maintenance-name[value='Weekend repairs']")
    assert has_element?(rules, "#rule-name[value='Production limits']")

    # Expired acknowledgements become attention again on the normal tick, even
    # while the operator keeps an unsaved draft open on another section.
    expired = DateTime.add(now, -1)

    Repo.update_all(from(i in Incident, where: i.id == ^health.id),
      set: [acknowledged_until: expired]
    )

    Repo.update_all(from(i in MonitoringIncident, where: i.id == ^loss.id),
      set: [acknowledged_until: expired]
    )

    for view <- views do
      send(view.pid, :tick)
      assert_counts(view, 1, 1)
    end

    assert has_element?(rules, "#rule-name[value='Production limits']")
    assert has_element?(maintenance, "#maintenance-name[value='Weekend repairs']")
  end

  test "Coverage and Incidents retain a section heading above tabs and view-specific titles" do
    %{scope: scope, publication: publication} = installation()

    for {path, section, title, active} <- [
          {"/coverage", "Coverage", "Intended results", "/coverage"},
          {"/coverage/publishers", "Coverage", "Runner declarations", "/coverage/publishers"},
          {"/coverage/diagnostics", "Coverage", "Unresolved declarations",
           "/coverage/diagnostics"},
          {"/coverage/#{scope["id"]}", "Coverage", "service", "/coverage"},
          {"/coverage/publishers/#{publication.id}", "Coverage", "Observer",
           "/coverage/publishers"},
          {"/incidents", "Incidents", "Target health", "/incidents"},
          {"/monitoring-incidents", "Incidents", "Monitoring loss", "/monitoring-incidents"}
        ] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#main-content .section-heading h1", section)

      assert has_element?(
               view,
               ".section-heading + nav.coverage-tabs[aria-label='#{section |> String.replace("Incidents", "Incident")} views']"
             )

      assert has_element?(view, "nav.coverage-tabs a[aria-current=page][href='#{active}']")
      assert has_element?(view, "nav.coverage-tabs ~ .view-heading h2", title)

      assert view |> render() |> LazyHTML.from_document() |> LazyHTML.query("h1") |> Enum.count() ==
               1

      GenServer.stop(view.pid)
    end
  end

  defp installation do
    now = Monitoring.now()
    assert {:ok, _} = Monitoring.control(control(), now)

    sample =
      measurement("CRIT", 1, %{
        "started_at" => Monitoring.iso(now),
        "evaluated_at" => Monitoring.iso(now)
      })
      |> update_in(
        ["results"],
        &Enum.map(&1, fn result -> Map.put(result, "source_at", Monitoring.iso(now)) end)
      )

    assert disposition(ingest(sample, now)) == "current"
    health = Repo.one!(Incident)

    candidate = F.candidate(F.check())
    declaration = F.publication([candidate])
    [check] = declaration["checks"]

    check =
      Map.merge(check, %{
        "params_owner" => "ui",
        "parameter_contract" => "example.limits.v1",
        "parameter_schema" => %{
          "fields" => %{
            "limit" => %{
              "type" => "integer",
              "label" => "Limit",
              "minimum" => 0,
              "maximum" => 100
            }
          }
        },
        "params" => %{"limit" => 80}
      })

    assert {:ok, _} = Monitoring.inventory(%{declaration | "checks" => [check]}, now)
    [scope] = Coverage.scopes(%{}, now)["items"]
    publication = Repo.one!(SourceInventory)
    [check] = F.assignments(declaration)
    loss = loss("Unacknowledged collection", now)
    held = loss("Acknowledged collection", now)

    assert {:ok, _} =
             reviewed_monitoring_acknowledgement_fixture(held.id, 3600, "Known issue", now)

    %{scope: scope, publication: publication, check: check, health: health, loss: loss}
  end

  defp loss(label, now) do
    key = Ecto.UUID.generate()

    Repo.insert!(%MonitoringIncident{
      scope_key: "coverage:" <> key,
      scope_kind: "coverage",
      source_id: key,
      label: label,
      opened_at: now,
      member_count: 1
    })
  end

  defp assert_counts(view, health, monitoring) do
    assert view
           |> element("#incident-attention-count")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text() == "#{health}"

    if monitoring == 0 do
      refute has_element?(view, "#incident-navigation .monitoring-loss-count")
    else
      assert has_element?(view, "#incident-navigation .monitoring-loss-count", "+#{monitoring}")
    end

    assert has_element?(
             view,
             "#incident-navigation[aria-label*='#{health} unacknowledged open incidents']"
           )
  end
end
