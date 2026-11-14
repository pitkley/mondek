# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ResultDetailsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.ResultStream

  @endpoint MondekWeb.Endpoint

  test "incident relationships inspect the exact result in place and link its shared configuration" do
    connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)
    path = "/incidents/health/#{incident.id}/full"
    {:ok, view, _} = live(build_conn(), path)
    view |> element("#incident-page a", "View latest check result") |> render_click()
    assert has_element?(view, "#incident-page[inert]")
    assert has_element?(view, "#overview-panel .preview-result-measurement", "Critical")

    assert has_element?(
             view,
             "#overview-panel a[href^='/configuration/#{incident.assignment_id}']",
             "View check configuration"
           )

    assert has_element?(view, "#overview-panel a[data-overview-close]", "Back one level")
    view |> element("#overview-panel a[data-overview-close]") |> render_click()
    refute has_element?(view, "#overview-panel")
    assert has_element?(view, "#incident-page a", "View latest check result")
    ingest(measurement("OK", 2))
    send(view.pid, :tick)
    assert has_element?(view, "#incident-page a", "View latest check result")
  end

  test "result and incident detail display escaped multiline evidence without expanding lists or notifications" do
    connect()
    details = "First line\n<script>alert('unsafe')</script>\n**plain**, not Markdown & literal"
    opening = put_in(measurement("CRIT"), ["results", Access.at(0), "details"], details)
    ingest(opening)
    incident = Repo.one!(Incident)

    stream =
      Repo.one!(
        from s in ResultStream, where: s.assignment_id == "10000000-0000-4000-8000-000000000001"
      )

    assignment = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    Monitoring.save_assignment(
      "10000000-0000-4000-8000-000000000001",
      1,
      Map.put(assignment.params, "crit_percent", 95)
    )

    connect(%{"prepared" => %{"10000000-0000-4000-8000-000000000001" => 2}})

    failed =
      measurement("UNKNOWN", 2, %{"generation" => 2, "complete" => false})
      |> put_in(["results", Access.at(0), "source_at"], nil)
      |> put_in(
        ["results", Access.at(0), "details"],
        "Later execution diagnostic\nConnection failed"
      )

    ingest(failed)
    {:ok, view, html} = live(build_conn(), "/results/" <> stream.id <> "/full")
    assert has_element?(view, ".preview-result-measurement", "First line")
    refute has_element?(view, "details .preview-result-measurement")

    assert has_element?(
             view,
             ".preview-result-measurement .preview-check-details strong",
             "plain"
           )

    refute has_element?(view, ".preview-result-measurement script")
    assert html =~ "&lt;script&gt;"
    assert has_element?(view, "#collection-diagnostics", "Later execution diagnostic")
    assert has_element?(view, "#collection-diagnostics", "Connection failed")

    assert fact_value(view, "Confirmed result provenance", "Confirmed configuration version") ==
             "1"

    assert fact_value(view, "Latest execution evidence", "Reported configuration version") == "2"

    {:ok, incident_view, _} = live(build_conn(), "/incidents/health/" <> incident.id <> "/full")
    assert has_element?(incident_view, "#preview-health-evidence", "First line")

    assert has_element?(
             incident_view,
             "#preview-health-evidence .preview-check-details strong",
             "plain"
           )

    refute has_element?(incident_view, "#preview-health-evidence script")
    refute has_element?(incident_view, "#preview-delivery .preview-check-details")

    for path <- ["/checks", "/", "/runners", "/notifications"] do
      {:ok, list_view, list_html} = live(build_conn(), path)
      refute has_element?(list_view, ".diagnostic-details")
      refute list_html =~ "First line"
    end
  end

  test "maximum-length result keys retain their complete identity in accessible disclosures" do
    key = String.duplicate("r", 123) <> " a/b:"

    definition = %{
      "key" => "long-result-key",
      "label" => "Long result identity",
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => key,
          "label" => "A result",
          "target" => %{"key" => "local", "kind" => "service", "label" => "Local service"}
        }
      ]
    }

    inventory =
      control()
      |> Map.merge(%{
        "runner_label" => "Local runner",
        "source_id" => "details-test",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => [definition]
      })

    assert {:ok, _} = Monitoring.inventory(inventory, at())
    assignment = Repo.get_by!(Assignment, source_key: "long-result-key")
    connect(%{"prepared" => %{assignment.id => 1}, "active" => %{}})

    sample =
      measurement("CRIT", 1, %{"assignment_id" => assignment.id})
      |> put_in(["results", Access.at(0), "key"], key)
      |> put_in(
        ["results", Access.at(0), "details"],
        "First line\n" <> String.duplicate("x", 1024)
      )

    assert disposition(ingest(sample)) == "current"
    stream = Repo.get_by!(ResultStream, assignment_id: assignment.id)
    incident = Repo.one!(Incident)

    for path <- [
          "/results/" <> stream.id <> "/full",
          "/incidents/health/" <> incident.id <> "/full"
        ] do
      {:ok, view, _} = live(build_conn(), path)
      assert render(view) =~ key
      assert has_element?(view, ".preview-check-details", String.duplicate("x", 1024))

      assert has_element?(
               view,
               ".preview-result-measurement .preview-check-details, #preview-health-evidence .preview-check-details",
               String.duplicate("x", 1024)
             )
    end
  end

  test "absent details do not add empty disclosures" do
    connect()
    ingest(measurement("OK"))
    {:ok, view, _} = live(build_conn(), "/executions/10000000-0000-4000-8000-000000000001")
    refute has_element?(view, ".preview-check-details")
  end

  defp fact_value(view, table, heading) do
    view
    |> element("table[aria-label='#{table}'] tr", heading)
    |> render()
    |> then(&LazyHTML.from_fragment("<table><tbody>" <> &1 <> "</tbody></table>"))
    |> LazyHTML.query("td")
    |> LazyHTML.text()
    |> String.trim()
  end
end
