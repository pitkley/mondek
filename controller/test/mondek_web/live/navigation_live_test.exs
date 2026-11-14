# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NavigationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Coverage, MonitoringIncident, SourceInventory}
  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint

  test "all migrated routes share one navigation with the correct selected section" do
    %{scope: scope, publication: publication, loss: loss} = installation()

    for {path, active} <- [
          {"/", "/"},
          {"/checks?search=not-present&page=8", "/checks"},
          {"/coverage?search=not-present&page=8", "/coverage"},
          {"/coverage/#{scope["id"]}/full", "/coverage"},
          {"/coverage/publishers", "/coverage"},
          {"/coverage/publishers/#{publication.id}", "/coverage"},
          {"/incidents?status=closed", "/incidents"},
          {"/incidents/loss/#{loss.id}/full", "/incidents"},
          {"/maintenance?status=ended", "/maintenance"},
          {"/maintenance/new", "/maintenance"},
          {"/configuration", "/configuration"},
          {"/configuration/rules", "/configuration"},
          {"/configuration/rules/new", "/configuration"},
          {"/configuration/history", "/configuration"},
          {"/configuration/10000000-0000-4000-8000-000000000001", "/configuration"},
          {"/runners?search=not-present", "/runners"},
          {"/notifications?notification_status=exhausted", "/notifications"}
        ] do
      {:ok, view, html} = live(build_conn(), path)

      assert has_element?(
               view,
               "nav[aria-label='Main navigation'] a[aria-current=page][href='#{active}']"
             ),
             path

      assert has_element?(view, "a[href='#main-content']", "Skip to content"), path
      assert has_element?(view, "#main-content[tabindex='-1']"), path
      assert html =~ "/assets/preview.css"
      refute html =~ "/assets/app.css"
      GenServer.stop(view.pid)
    end
  end

  test "refresh retains independent editing drafts while evidence changes elsewhere" do
    %{health: health, loss: loss, publication: publication, check: check} = installation()
    {:ok, monitoring, _} = live(build_conn(), "/incidents/loss/#{loss.id}/full")
    {:ok, publisher, _} = live(build_conn(), "/coverage/publishers/#{publication.id}")
    {:ok, maintenance, _} = live(build_conn(), "/maintenance/new?check_id=#{check.id}")
    {:ok, rules, _} = live(build_conn(), "/configuration/rules/new?check_id=#{check.id}")

    monitoring
    |> form("#preview-incident-ack-form", note: "Investigate after lunch")
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

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(health.id, 3600, "Investigating", Monitoring.now())

    for view <- [monitoring, publisher, maintenance, rules], do: send(view.pid, :tick)
    assert has_element?(monitoring, "#preview-incident-ack-form", "Investigate after lunch")
    assert has_element?(publisher, "#publisher-reason", "Review old deployment")
    assert has_element?(maintenance, "#maintenance-name[value='Weekend repairs']")
    assert has_element?(rules, "#rule-name[value='Production limits']")
  end

  test "list pages keep a single clear page heading and use filters instead of nested legacy tabs" do
    installation()

    for {path, heading} <- [
          {"/coverage", "Coverage"},
          {"/coverage/publishers", "Source publications"},
          {"/incidents", "Incidents"},
          {"/checks", "Checks"}
        ] do
      {:ok, view, _} = live(build_conn(), path)

      assert view |> render() |> LazyHTML.from_document() |> LazyHTML.query("h1") |> Enum.count() ==
               1

      assert has_element?(view, "h1", heading)
      assert has_element?(view, "form[phx-hook='PreviewFilterPicker']")
      refute has_element?(view, "nav.coverage-tabs")
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
end
