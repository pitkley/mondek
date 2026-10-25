# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ResultDetailsLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.ResultStream

  @endpoint MondekWeb.Endpoint

  test "incident header reaches the exact result and its configuration with return navigation" do
    connect()
    ingest(measurement("CRIT"))
    incident = Repo.one!(Incident)
    return_to = "/incidents?status=open"
    incident_path = "/incidents/#{incident.id}?" <> URI.encode_query(%{"return_to" => return_to})

    result_path =
      "/checks/#{incident.stream_id}?" <> URI.encode_query(%{"return_to" => incident_path})

    {:ok, view, _} = live(build_conn(), incident_path)
    assert has_element?(view, ".page-heading #incident-view-check", "View check")
    refute has_element?(view, "#incident-history a", "View check")

    {:ok, result, _} =
      view
      |> element("#incident-view-check")
      |> render_click()
      |> follow_redirect(build_conn(), result_path)

    assert has_element?(result, ".back[href='#{incident_path}']", "Back to incident")

    configuration_path =
      "/configuration/#{incident.assignment_id}?" <>
        URI.encode_query(%{"return_to" => result_path})

    {:ok, configuration, _} =
      result
      |> element(".page-heading a", "Review configuration")
      |> render_click()
      |> follow_redirect(build_conn(), configuration_path)

    assert has_element?(configuration, ".back[href='#{result_path}']", "Back to result")

    ingest(measurement("OK", 2))
    {:ok, closed, _} = live(build_conn(), incident_path)
    assert has_element?(closed, ".page-heading #incident-view-check[href='#{result_path}']")
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
    {:ok, view, html} = live(build_conn(), "/checks/" <> stream.id)
    assert has_element?(view, "#confirmed-result-details h3", "Check details")
    refute has_element?(view, "details#confirmed-result-details")
    escaped_details = details |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    assert render(element(view, "#confirmed-result-details pre")) =~ escaped_details
    assert has_element?(view, ".diagnostic-details", "Later execution diagnostic")
    assert has_element?(view, ".diagnostic-details summary", "Result details: capacity")
    refute has_element?(view, ".diagnostic-details script")
    refute has_element?(view, ".diagnostic-details strong")
    assert html =~ "&lt;script&gt;"
    assert html =~ "First line\n"
    assert has_element?(view, "#confirmed-configuration", "1")
    assert has_element?(view, "#execution-configuration", "2")

    {:ok, incident_view, _} = live(build_conn(), "/incidents/" <> incident.id)
    assert render(element(incident_view, "#incident-current-details pre")) =~ escaped_details

    assert render(element(incident_view, "#incident-measurements .diagnostic-details pre")) =~
             escaped_details

    refute has_element?(incident_view, "#incident-occurrences .diagnostic-details")

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

    for path <- ["/checks/" <> stream.id, "/incidents/" <> incident.id] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "details.diagnostic-details > summary", "Result details: " <> key)

      details_id =
        "result-details-" <> sample["id"] <> "-" <> Base.url_encode64(key, padding: false)

      assert has_element?(view, "#" <> details_id)
      assert has_element?(view, ".resource-summary strong", key)
      assert has_element?(view, "details.diagnostic-details > pre", String.duplicate("x", 1024))
    end
  end

  test "absent details do not add empty disclosures" do
    connect()
    ingest(measurement("OK"))
    {:ok, view, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")
    refute has_element?(view, ".diagnostic-details")
  end
end
