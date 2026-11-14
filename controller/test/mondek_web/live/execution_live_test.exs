# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ExecutionLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint
  @check "10000000-0000-4000-8000-000000000001"

  defp measured do
    connect()
    ingest(measurement("CRIT"))
    Repo.get_by!(Mondek.ResultStream, assignment_id: @check)
  end

  test "one execution body exposes the same evidence, relationships and settings in full page and panel" do
    stream = measured()

    for {path, body} <- [
          {"/executions/#{@check}", "#execution-page"},
          {"/?inspect=execution%3A#{@check}", "#overview-panel"}
        ] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, body <> " [data-execution-body]")

      for title <- [
            "Scheduled execution",
            "Independent results",
            "Collection diagnostics",
            "Shared check settings",
            "Incident history",
            "Execution evidence",
            "Operator control history"
          ] do
        assert has_element?(
                 view,
                 body <> if(body == "#execution-page", do: " h2", else: " h3"),
                 title
               )
      end

      assert has_element?(view, body <> " a[href*='result%3A#{stream.id}']")
      assert has_element?(view, body <> " a[href*='runner%3A']")
      assert has_element?(view, body <> " a[href^='/configuration/#{@check}']", "Configure")

      assert has_element?(view, body <> " td", "Saving does not establish adoption") ||
               has_element?(view, body <> " p", "Saving does not establish adoption")
    end
  end

  test "execution result relationship returns to the exact root instead of duplicating it" do
    stream = measured()
    {:ok, view, _} = live(build_conn(), "/executions/#{@check}")
    view |> element("#execution-results a[href*='result%3A#{stream.id}']") |> render_click()
    assert has_element?(view, "#execution-page[inert]")
    assert has_element?(view, "#overview-panel #preview-result-collection")
    view |> element("#overview-panel a", "Shared execution and history") |> render_click()
    refute has_element?(view, "#overview-panel")
    assert has_element?(view, "#execution-page:not([inert])")
    refute has_element?(view, "[data-panel-back-path]")
  end

  test "collection diagnostics retain original health and time while showing newer failed execution" do
    now = Monitoring.now()
    Monitoring.control(control(%{"active" => %{@check => 1}}), now)
    source = DateTime.to_iso8601(now)

    assert disposition(
             ingest(
               measurement("CRIT", 1, %{
                 "started_at" => source,
                 "evaluated_at" => source,
                 "results" => [
                   %{
                     "key" => "capacity",
                     "health" => "CRIT",
                     "source_at" => source,
                     "summary" => "Confirmed pressure",
                     "details" => "Measured **details**"
                   }
                 ]
               }),
               now
             )
           ) == "current"

    later = DateTime.add(now, 1)
    time = DateTime.to_iso8601(later)

    assert disposition(
             ingest(
               measurement("UNKNOWN", 2, %{
                 "started_at" => time,
                 "evaluated_at" => time,
                 "complete" => false,
                 "diagnostic" => "Collection failed",
                 "results" => [
                   %{
                     "key" => "capacity",
                     "health" => "UNKNOWN",
                     "summary" => "Datasource unavailable",
                     "details" => "Connection refused <script>unsafe()</script>"
                   }
                 ]
               }),
               later
             )
           ) == "current"

    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @check)

    for path <- ["/results/#{stream.id}", "/results/#{stream.id}/full?diagnostics=1"] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "[id$='result-collection-diagnostics'][open]")
      assert has_element?(view, "[id$='collection-diagnostics']", "Collection unavailable")
      assert has_element?(view, "[id$='collection-diagnostics']", "Connection refused")
      assert has_element?(view, ".preview-result-measurement", "Confirmed pressure")
      assert has_element?(view, ".preview-result-measurement strong", "details")
      refute html =~ "<script>unsafe()"
      prompt = view |> element("[id$='collection-agent-prompt-text']") |> render()
      refute prompt =~ "Connection refused"
      assert has_element?(view, ".preview-result-measurement time[datetime='#{source}']")
    end
  end

  test "unknown or malformed execution identity is a useful unavailable page" do
    {:ok, missing, _} = live(build_conn(), "/executions/#{Ecto.UUID.generate()}")
    assert has_element?(missing, "h1", "Scheduled execution not found")
    {:ok, malformed, _} = live(build_conn(), "/executions/invalid")
    assert has_element?(malformed, "h1", "Scheduled execution not found")
    refute has_element?(malformed, "[data-execution-body]")
  end

  test "historical settings retain removed keys and frozen units beside current source provenance" do
    now = Monitoring.now()
    source = DateTime.to_iso8601(now)
    Monitoring.control(control(%{"active" => %{@check => 1}}), now)

    configuration = Repo.get_by!(Mondek.Configuration, assignment_id: @check, generation: 1)

    frozen_schema = %{
      "fields" => %{"old_threshold" => %{"label" => "Original threshold", "unit" => "ms"}}
    }

    configuration
    |> Ecto.Changeset.change(
      params: %{"old_threshold" => 125},
      definition: Map.put(configuration.definition, "parameter_schema", frozen_schema)
    )
    |> Repo.update!()

    assert disposition(
             ingest(
               measurement("CRIT", 1, %{
                 "started_at" => source,
                 "evaluated_at" => source,
                 "results" => [
                   %{
                     "key" => "capacity",
                     "health" => "CRIT",
                     "source_at" => source,
                     "summary" => "Measured original settings"
                   }
                 ]
               }),
               now
             )
           ) == "current"

    Repo.get!(Assignment, @check)
    |> Ecto.Changeset.change(
      desired_generation: 2,
      params: %{"new_threshold" => 2},
      parameter_schema: %{
        "fields" => %{"new_threshold" => %{"label" => "Replacement threshold", "unit" => "s"}}
      },
      source_revision: "replacement-source-revision",
      definition_revision: "replacement-definition-revision"
    )
    |> Repo.update!()

    assert {:ok, _} = withdraw_source_fixture(@check, "Publisher replaced", DateTime.add(now, 1))

    for path <- ["/executions/#{@check}", "/?inspect=execution%3A#{@check}"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "table[aria-label='Saved parameters']", "Replacement threshold")
      assert has_element?(view, "table[aria-label='Saved parameters'] td", "2 s")
      refute has_element?(view, "table[aria-label='Saved parameters']", "old_threshold")

      assert has_element?(
               view,
               "table[aria-label='Last fully measured execution parameters']",
               "Original threshold"
             )

      assert has_element?(
               view,
               "table[aria-label='Last fully measured execution parameters'] td",
               "125 ms"
             )

      refute has_element?(
               view,
               "table[aria-label='Last fully measured execution parameters']",
               "new_threshold"
             )

      assert has_element?(view, "[id$='execution-provenance']", "replacement-source-revision")
      assert has_element?(view, "[id$='execution-provenance']", "replacement-definition-revision")
      assert has_element?(view, "[id$='execution-provenance']", "Delegated to operator")
      assert has_element?(view, "[id$='execution-provenance']", "Publisher replaced")
      assert has_element?(view, "[id$='execution-scope']", "retirement is not recovery")
    end
  end

  test "execution history preserves reported source time, disposition and bounded scoped controls" do
    now = Monitoring.now()
    source = DateTime.to_iso8601(now)
    Monitoring.control(control(%{"active" => %{@check => 1}}), now)

    for sequence <- 1..6 do
      assert disposition(
               ingest(
                 measurement("CRIT", sequence, %{
                   "started_at" => source,
                   "evaluated_at" => source,
                   "results" => [
                     %{
                       "key" => "capacity",
                       "health" => "CRIT",
                       "source_at" => source,
                       "summary" => "Pressure sample #{sequence}",
                       "details" => "Recorded **pressure** <script>unsafe()</script>"
                     }
                   ]
                 }),
                 DateTime.add(now, sequence)
               )
             ) == "current"
    end

    assert disposition(ingest(measurement("OK", 1), DateTime.add(now, 7))) == "historical"
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @check)
    incident = Repo.get_by!(Incident, stream_id: stream.id)

    for sequence <- 1..6 do
      Repo.insert!(%Mondek.Control{
        assignment_id: @check,
        stream_id: stream.id,
        incident_id: incident.id,
        kind: "acknowledgement",
        actor: "Operator #{sequence}",
        reason: "Control note #{sequence}",
        acknowledgement_mode: "until_incident_ends",
        acknowledgement_ceiling: "CRIT",
        inserted_at: DateTime.add(now, sequence)
      })
    end

    for {path, full?} <- [
          {"/executions/#{@check}", true},
          {"/?inspect=execution%3A#{@check}", false}
        ] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "[id$='execution-history']", "Historical report")
      assert has_element?(view, "[id$='execution-history']", "Accepted as current on receipt")
      assert has_element?(view, ".execution-recorded-result time[datetime='#{source}']")
      assert has_element?(view, ".execution-recorded-result strong", "pressure")
      refute html =~ "<script>unsafe()"
      assert has_element?(view, "[id$='execution-controls']", "Operator 6")
      assert has_element?(view, "[id$='execution-controls']", "until this incident ends")
      assert has_element?(view, "[id$='execution-controls']", "severity and below")
      assert has_element?(view, "[id$='execution-controls'] a[href*='result%3A#{stream.id}']")
      assert has_element?(view, "[id$='execution-controls'] a[href*='health%3A#{incident.id}']")

      assert has_element?(
               view,
               "[id$='execution-controls']",
               "Showing 6 of 6 retained operator controls"
             )

      if full? do
        refute has_element?(view, "[id$='execution-older-controls']")
        refute has_element?(view, "[id$='execution-older-evidence']")
      else
        assert has_element?(
                 view,
                 "[id$='execution-older-controls']:not([open])",
                 "Control note 1"
               )

        assert has_element?(
                 view,
                 "[id$='execution-older-evidence']:not([open])",
                 "Pressure sample 1"
               )

        assert has_element?(view, "[id$='execution-controls'] > table", "Control note 6")
        refute has_element?(view, "[id$='execution-controls'] > table", "Control note 1")

        assert Enum.count(
                 view
                 |> element("[id$='execution-controls'] > table")
                 |> render()
                 |> LazyHTML.from_fragment()
                 |> LazyHTML.query("tbody > tr")
               ) == 4
      end
    end
  end

  test "result surfaces retain their own confirmed version when a sibling is missing" do
    now = Monitoring.now()
    time = DateTime.to_iso8601(now)
    assignment = Repo.get!(Assignment, @check)

    sibling_output = %{
      "key" => "sibling",
      "label" => "Sibling",
      "target" => hd(assignment.outputs)["target"]
    }

    schema = put_in(assignment.parameter_schema, ["fields", "crit_percent", "unit"], "percent")

    assignment =
      assignment
      |> Ecto.Changeset.change(
        outputs: assignment.outputs ++ [sibling_output],
        expected_keys: ["capacity", "sibling"],
        parameter_schema: schema
      )
      |> Repo.update!()

    Repo.get_by!(Mondek.Configuration, assignment_id: @check, generation: 1)
    |> Ecto.Changeset.change(definition: Mondek.Inventory.definition(assignment))
    |> Repo.update!()

    Repo.insert!(%Mondek.ResultStream{
      assignment_id: @check,
      admission_generation: 1,
      result_key: "sibling",
      label: "Sibling",
      target: sibling_output["target"]
    })

    Monitoring.control(control(%{"active" => %{@check => 1}}), now)

    sample = %{
      "key" => "capacity",
      "health" => "CRIT",
      "source_at" => time,
      "summary" => "Measured capacity"
    }

    first =
      measurement("CRIT", 1, %{
        "started_at" => time,
        "evaluated_at" => time,
        "results" => [sample, Map.put(sample, "key", "sibling")]
      })

    assert disposition(ingest(first, now)) == "current"

    assert {:ok, _} =
             Monitoring.save_assignment(
               @check,
               assignment.revision,
               Map.put(assignment.params, "crit_percent", 95)
             )

    later = DateTime.add(now, 1)
    later_time = DateTime.to_iso8601(later)

    Monitoring.control(
      control(%{"prepared" => %{@check => 2}, "active" => %{@check => 2}}),
      later
    )

    partial =
      measurement("CRIT", 2, %{
        "generation" => 2,
        "started_at" => later_time,
        "evaluated_at" => later_time,
        "complete" => false,
        "results" => [Map.put(sample, "source_at", later_time)]
      })

    assert disposition(ingest(partial, later)) == "current"
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: @check, result_key: "capacity")
    assert stream.current["confirmed_generation"] == 2
    assert Repo.get!(Assignment, @check).current["confirmed_generation"] == 1

    # Current source schema must not relabel the frozen measured settings.
    Repo.get!(Assignment, @check)
    |> Ecto.Changeset.change(
      parameter_schema: put_in(schema, ["fields", "crit_percent", "unit"], "replacement-unit")
    )
    |> Repo.update!()

    for {path, body} <- [
          {"/results/#{stream.id}/full", "#preview-result-page"},
          {"/?inspect=result%3A#{stream.id}", "#overview-panel"}
        ] do
      {:ok, view, _} = live(build_conn(), path)
      provenance = body <> " [id$='result-measurement-provenance']"

      assert has_element?(
               view,
               provenance <> " table[aria-label='Confirmed result provenance'] tr:first-child td",
               "2"
             )

      assert has_element?(view, provenance, partial["id"])
      refute has_element?(view, provenance, first["id"])

      assert has_element?(
               view,
               provenance <> " table[aria-label='Last measured result parameters']",
               "95 percent"
             )

      refute has_element?(view, provenance, "replacement-unit")
      assert has_element?(view, provenance, control()["session_id"])
    end
  end

  test "result maintenance preserves result scope and execution history remains reachable without current windows" do
    stream = measured()

    for {path, body} <- [
          {"/results/#{stream.id}/full", "#preview-result-page"},
          {"/?inspect=result%3A#{stream.id}", "#overview-panel"}
        ] do
      {:ok, view, _} = live(build_conn(), path)
      scope = body <> " [id$='result-maintenance']"
      assert has_element?(view, scope, "No active or upcoming")

      assert has_element?(
               view,
               scope <> " a[href*='check_id=#{@check}'][href*='stream_id=#{stream.id}']",
               "Schedule maintenance"
             )

      assert has_element?(
               view,
               scope <>
                 " a[href*='assignment_id=#{@check}'][href*='stream_id=#{stream.id}'][href*='status=history']",
               "View maintenance history"
             )

      assert has_element?(view, scope <> " a[href*='return_to=']", "Schedule maintenance")
    end

    for path <- ["/executions/#{@check}", "/?inspect=execution%3A#{@check}"] do
      {:ok, view, _} = live(build_conn(), path)

      assert has_element?(
               view,
               "[id$='execution-maintenance'] a[href*='assignment_id=#{@check}'][href*='status=history']",
               "View maintenance history"
             )

      refute has_element?(view, "[id$='execution-maintenance'] a[href*='stream_id=']")
    end
  end
end
