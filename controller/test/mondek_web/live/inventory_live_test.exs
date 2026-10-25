# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InventoryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "five hundred results are paged in the database and filters survive navigation" do
    checks =
      for index <- 1..500, do: check("check-#{String.pad_leading(to_string(index), 3, "0")}")

    assert {:ok, _} = publish(checks)

    {:ok, view, html} =
      live(build_conn(), "/checks?search=check-&environment=production&view=list")

    assert html =~ "500 matching"

    assert row_count(view, "#check-inventory tbody tr") == 50

    refute html =~ "check-500 result"
    assert has_element?(view, "a[href*='page=2']", "Next")
    view |> element("#inventory-pagination-top a", "Next") |> render_click()
    assert_patch(view, "/checks?environment=production&page=2&search=check-&tab=all&view=list")
    assert has_element?(view, "#inventory-search[value='check-']")
    assert has_element?(view, ".pagination", "Page 2 of 10")
    assert has_element?(view, "#check-inventory", "check-051 result")

    view
    |> form("#inventory-filters", search: "check-500", environment: "production")
    |> render_change()

    assert has_element?(view, "#check-inventory", "1 matching")
    assert has_element?(view, "#check-inventory", "check-500 result")
    {:ok, overview, _} = live(build_conn(), "/")
    assert has_element?(overview, "#coverage-summary", "503")

    assert row_count(overview, ".inventory-table tbody tr") <= 8
  end

  test "runner inspection names each independent collector and links its own inventory" do
    assert {:ok, _} = publish([check("local-node")])
    installation = Ecto.UUID.generate()

    assert {:ok, _} =
             Inventory.reconcile(
               control()
               |> Map.merge(%{
                 "installation_id" => installation,
                 "session_id" => Ecto.UUID.generate(),
                 "runner_label" => "Metrics collector",
                 "source_id" => "metrics.consumer",
                 "source_revision" => String.duplicate("c", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => [check("remote-service", "source")]
               }),
               at()
             )

    {:ok, view, _} = live(build_conn(), "/runners")
    assert has_element?(view, "#runner-list a", "Production node")
    assert has_element?(view, "#runner-row-#{installation} a", "Metrics collector")

    detail_navigation =
      view |> element("#runner-row-#{installation} .fleet-runner-name") |> render_click()

    {:ok, detail, _} = follow_redirect(detail_navigation, build_conn())
    assert has_element?(detail, "h1", "Metrics collector")

    assert has_element?(
             detail,
             "a[href='/configuration?runner_id=#{installation}']",
             "1 scheduled check"
           )

    navigation =
      detail |> element("a[href='/configuration?runner_id=#{installation}']") |> render_click()

    {:ok, inventory, _} = follow_redirect(navigation, build_conn())
    assert has_element?(inventory, "#check-inventory", "remote-service")
    refute has_element?(inventory, "#check-inventory", "local-node")
  end

  test "runner scheduler backlog is distinct from buffered reports and remains the last reported value" do
    scheduler = %{
      "active_checks" => 500,
      "running_checks" => 3,
      "max_concurrency" => 3,
      "due_waiting_checks" => 497,
      "oldest_due_seconds" => 32.125,
      "preparation_pending_checks" => 7,
      "prepared_waiting_checks" => 2
    }

    status = %{
      "queue_count" => 11,
      "queue_bytes" => 2048,
      "running" => 3,
      "scheduler" => scheduler
    }

    assert {:ok, _} = connect(%{"status" => status})
    id = control()["installation_id"]
    {:ok, view, _} = live(build_conn(), "/runners/" <> id)
    panel = "#runner-last-report"
    facts = runner_facts(view)
    assert facts["Active checks on runner"] == "500"
    assert facts["Running checks"] == "3"
    assert facts["Maximum concurrent checks"] == "3"
    assert facts["Due, waiting for a slot"] == "497"
    assert facts["Oldest due wait"] == "32.1 seconds"
    assert facts["Waiting for preparation"] == "7"
    assert facts["Prepared, awaiting activation"] == "2"
    assert has_element?(view, panel, "Last reported")
    assert has_element?(view, panel, "stay fixed until a new status report arrives")
    assert has_element?(view, panel, "Evidence awaiting upload")
    assert facts["Buffered reports"] == "11"
    send(view.pid, :tick)
    assert has_element?(view, panel, "32.1 seconds")

    idle = %{scheduler | "due_waiting_checks" => 0, "oldest_due_seconds" => 0.0}
    assert {:ok, _} = connect(%{"status" => %{status | "scheduler" => idle}})
    send(view.pid, :tick)
    assert runner_facts(view)["Due, waiting for a slot"] == "0"
    assert runner_facts(view)["Oldest due wait"] == "0.0 seconds"
  end

  test "same-named runners have distinct stable filter labels" do
    assert {:ok, _} = publish([check("first-observer")])
    second = Ecto.UUID.generate()
    first = control()["installation_id"]

    assert {:ok, _} =
             Inventory.reconcile(
               control()
               |> Map.merge(%{
                 "installation_id" => second,
                 "session_id" => Ecto.UUID.generate(),
                 "runner_label" => "Production node",
                 "source_id" => "other.source",
                 "source_revision" => String.duplicate("c", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => [check("second-observer")]
               }),
               at()
             )

    {:ok, view, _} = live(build_conn(), "/checks")

    for id <- [first, second] do
      assert has_element?(
               view,
               "#inventory-runner option[value='#{id}']",
               "Production node (#{id})"
             )
    end

    view |> form("#inventory-filters", runner_id: second) |> render_change()
    assert has_element?(view, "#check-inventory", "second-observer")
    refute has_element?(view, "#check-inventory", "first-observer")
    {:ok, runners, _} = live(build_conn(), "/runners")

    for id <- [first, second] do
      assert has_element?(
               runners,
               "#runner-row-#{id} a[href^='/runners/#{id}']",
               "Production node"
             )

      assert has_element?(runners, "#runner-row-#{id} .fleet-identity[title='#{id}']")
    end
  end

  test "source ownership shows declared bindings and removes UI authoring controls" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("owned", "source")])
    {:ok, view, _} = live(build_conn(), "/configuration/" <> assignment["id"])
    assert has_element?(view, "#source-owned-parameters", "owned by the source")
    assert has_element?(view, "#check-source", "consumer.demo")
    refute has_element?(view, "#delegated-parameters")
    refute has_element?(view, "form[id^='form-']")
    refute has_element?(view, "a[href='/configuration/new']")
    {:ok, check_view, _} = live(build_conn(), "/resources/" <> assignment["id"])
    refute has_element?(check_view, "#retire-check-form")
    assert has_element?(check_view, "a[href^='/configuration/#{assignment["id"]}?']")
  end

  test "configuration separates shared editable values from source details and preserves retirement history" do
    definition = check("shared") |> Map.put("outputs", [output("left"), output("right")])
    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    streams = Repo.all(from s in ResultStream, where: s.assignment_id == ^id)
    {:ok, view, _} = live(build_conn(), "/configuration/" <> id)

    assert has_element?(
             view,
             "#delegated-parameters",
             "These values override shared rules"
           )

    assert has_element?(view, "#form-#{id} input[name='params[limit]']")
    assert has_element?(view, "#check-schedule > div:first-child dt", "Runs every")
    assert has_element?(view, "#check-schedule > div:first-child dd", "3 seconds")
    assert has_element?(view, "#check-schedule > div:last-child dt", "Freshness limit")
    assert has_element?(view, "#check-schedule > div:last-child dd", "12 seconds")
    refute has_element?(view, "#check-schedule input")
    assert row_count(view, "#configuration-results li") == 2
    assert has_element?(view, "#configuration-scope", "2 results")
    assert has_element?(view, "#configuration-scope", "resources it discovers later")
    assert has_element?(view, "#form-#{id} ~ details#configuration-origin:not([open])")

    for stream <- streams do
      assert has_element?(view, "#configuration-results a[href='/checks/#{stream.id}']")
    end

    assert has_element?(
             view,
             "details#check-source-revisions:not([open])",
             "Technical source details"
           )

    assert has_element?(view, "#check-source-revisions", String.duplicate("a", 64))
    refute has_element?(view, "#form-#{id}", String.duplicate("a", 64))
    assert has_element?(view, "details#check-source-lifecycle:not([open])", "Removing checks")
    assert has_element?(view, "#check-source-lifecycle", "without a recovery measurement")
    assert has_element?(view, "#configuration-agent-prompts-#{id}-check textarea[readonly]", id)

    assert has_element?(
             view,
             "#configuration-agent-prompts-#{id}-retirement textarea[readonly]",
             "consumer.demo"
           )

    assert {:ok, %{"assignments" => []}} = publish([], 2)
    {:ok, retired, _} = live(build_conn(), "/configuration/" <> id)
    assert has_element?(retired, "#source-owned-parameters", "This check is retired")
    assert has_element?(retired, "#check-source-revisions", String.duplicate("a", 64))
    refute has_element?(retired, "#form-#{id}")
    refute has_element?(retired, ".configuration-progress")
  end

  test "source schedules use readable units without losing fractional precision" do
    definition =
      check("long-schedule")
      |> Map.merge(%{
        "interval_seconds" => 21_600,
        "timeout_seconds" => 0.25,
        "freshness_seconds" => 86_400.001
      })

    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    {:ok, view, _} = live(build_conn(), "/configuration/" <> assignment["id"])
    assert has_element?(view, "#check-schedule > div:first-child dd", "6 hours")
    assert has_element?(view, "#check-schedule > div:nth-child(2) dd", "0.25 seconds")
    assert has_element?(view, "#check-schedule > div:last-child dd", "1 day 0.001 seconds")
    refute has_element?(view, "#check-schedule", "2.16e4")
  end

  test "shared inventory filter help stays associated with the environment outside its control row" do
    for path <- ["/configuration", "/incidents"] do
      {:ok, view, _} = live(build_conn(), path)

      assert has_element?(
               view,
               "#inventory-environment[aria-describedby='inventory-environment-help']"
             )

      assert has_element?(
               view,
               "#inventory-filters > #inventory-environment-help",
               "enter an environment ID"
             )

      refute has_element?(view, "#inventory-filters .field #inventory-environment-help")
    end

    {:ok, checks, _} = live(build_conn(), "/checks")
    assert has_element?(checks, "#inventory-filters label", "Monitored environment")
    assert has_element?(checks, "#inventory-environment[title*='monitored environment ID']")
  end

  test "same-named environments remain distinct choices and navigation filters by stable ID" do
    first =
      check("environment-a")
      |> Map.merge(%{"environment" => "region-a", "environment_label" => "Production"})

    second =
      check("environment-b")
      |> Map.merge(%{"environment" => "region-b", "environment_label" => "Production"})

    assert {:ok, _} = publish([first, second])
    {:ok, view, _} = live(build_conn(), "/checks?environment=region-a&view=list")

    assert has_element?(
             view,
             "#inventory-environments option[value='region-a'][label='Production (region-a)']"
           )

    assert has_element?(
             view,
             "#inventory-environments option[value='region-b'][label='Production (region-b)']"
           )

    assert has_element?(view, "#check-inventory", "environment-a result")
    refute has_element?(view, "#check-inventory", "environment-b result")
    assert has_element?(view, "#check-inventory", "Production (region-a)")

    view |> form("#inventory-filters", environment: "region-b") |> render_change()
    assert_patch(view, "/checks?environment=region-b&status=active&tab=all&view=list")
    assert has_element?(view, "#inventory-environment[value='region-b']")
    assert has_element?(view, "#check-inventory", "environment-b result")
    refute has_element?(view, "#check-inventory", "environment-a result")

    navigation =
      view
      |> element("#check-inventory tbody tr:first-child .checks-result-link")
      |> render_click()

    {:ok, detail, _} = follow_redirect(navigation, build_conn())
    assert has_element?(detail, "#check-source", "Production (region-b)")

    assert has_element?(
             detail,
             ".back[href='/checks?environment=region-b&status=active&tab=all&view=list']"
           )
  end

  test "environment label rename preserves group URLs and the incident opening environment" do
    definition =
      check("renamed-environment")
      |> Map.merge(%{"environment" => "region-a", "environment_label" => "Production"})

    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    assert {:ok, _} = connect(%{"prepared" => %{id => 1}})

    payload =
      measurement("CRIT")
      |> Map.put("assignment_id", id)
      |> put_in(["results", Access.at(0), "key"], "renamed-environment")

    assert disposition(ingest(payload)) == "current"
    stream = Repo.one!(from s in ResultStream, where: s.assignment_id == ^id)
    incident = Repo.one!(from i in Incident, where: i.stream_id == ^stream.id)

    assert {:ok, %{"assignments" => [renamed]}} =
             publish([Map.put(definition, "environment_label", "Primary production")], 2)

    assert renamed["id"] == id

    assert Repo.one!(
             from s in ResultStream, where: s.assignment_id == ^id and is_nil(s.retired_at)
           ).id == stream.id

    assert Repo.get!(Incident, incident.id).status == "open"
    {:ok, filtered, _} = live(build_conn(), "/checks?environment=region-a")

    assert has_element?(
             filtered,
             "#inventory-environments option[value='region-a'][label='Primary production (region-a)']"
           )

    assert has_element?(filtered, "#check-inventory", "1 matching")
    {:ok, result, _} = live(build_conn(), "/checks/" <> stream.id)
    assert has_element?(result, "#check-source", "Primary production (region-a)")
    {:ok, history, _} = live(build_conn(), "/incidents/" <> incident.id)

    assert has_element?(
             history,
             "#incident-environment",
             "Monitored environment when opened: Production (region-a)"
           )

    refute has_element?(history, "#incident-environment", "Primary production")
  end

  test "a selected schema edits the complete typed set and preserves a concurrent reviewed draft" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("delegated")])
    path = "/configuration/" <> assignment["id"]
    {:ok, first, _} = live(build_conn(), path)
    {:ok, second, _} = live(build_conn(), path)
    id = assignment["id"]
    assert has_element?(first, "##{id}-target[readonly][value='node-a']")
    assert has_element?(first, "##{id}-mode option[value='strict']")
    params = %{limit: "41", enabled: "false", mode: "strict", target: "node-a"}
    first |> form("#form-" <> id, params: params) |> render_submit()
    first |> element("#confirm-instance-save") |> render_click()

    assert Repo.get!(Assignment, id).params == %{
             "limit" => 41,
             "enabled" => false,
             "mode" => "strict",
             "target" => "node-a"
           }

    send(second.pid, :tick)
    assert render(second) =~ "Reviewing saved version 1"
    second |> form("#form-" <> id, params: %{params | limit: "67"}) |> render_submit()
    assert has_element?(second, "#error-" <> id, "changed after you opened")
    assert has_element?(second, "##{id}-limit[value='67']")
    second |> element("button", "Reload current values") |> render_click()
    assert has_element?(second, "##{id}-limit[value='41']")
    assert render(second) =~ "Reviewing saved version 2"
  end

  test "independent result pages keep sibling incidents and shared maintenance scope distinct" do
    definition = check("pair") |> Map.put("outputs", [output("left"), output("right")])
    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    assert {:ok, _} = connect(%{"prepared" => %{id => 1}})

    payload =
      measurement("CRIT")
      |> Map.put("assignment_id", id)
      |> Map.put("results", [
        %{
          "key" => "left",
          "health" => "CRIT",
          "summary" => "Left target failed",
          "source_at" => "2009-09-15T08:00:00.010000Z"
        },
        %{
          "key" => "right",
          "health" => "OK",
          "summary" => "Right target healthy",
          "source_at" => "2009-09-15T08:00:00.010000Z"
        }
      ])

    assert disposition(ingest(payload)) == "current"

    streams =
      Repo.all(from s in ResultStream, where: s.assignment_id == ^id)
      |> Map.new(&{&1.result_key, &1})

    {:ok, left, _} = live(build_conn(), "/checks/" <> streams["left"].id)
    {:ok, right, _} = live(build_conn(), "/checks/" <> streams["right"].id)
    assert has_element?(left, "h1", "left result")
    assert has_element?(left, ".badge", "Critical")
    assert has_element?(left, "section[id^='active-incident-']")
    assert has_element?(right, "h1", "right result")
    assert has_element?(right, ".badge", "Healthy")
    refute has_element?(right, "section[id^='active-incident-']")
    assert has_element?(right, "#maintenance-summary-" <> id)
    assert has_element?(right, "#schedule-maintenance[href*='stream_id=#{streams["right"].id}']")

    {:ok, incidents, _} = live(build_conn(), "/incidents")
    assert has_element?(incidents, "th", "Incident")
    assert has_element?(incidents, "td", "left result")
    assert has_element?(incidents, "td", "left target · Production node")
    incident = Repo.one!(from i in Incident, where: i.stream_id == ^streams["left"].id)
    {:ok, detail, _} = live(build_conn(), "/incidents/" <> incident.id)

    assert has_element?(
             detail,
             ".page-heading",
             "Target: left target · Observing runner: Production node"
           )

    occurrence = Repo.one!(from o in Occurrence, where: o.incident_id == ^incident.id)

    Repo.insert!(%Attempt{
      occurrence_id: occurrence.id,
      status: "delivered",
      http_status: 202,
      started_at: at(),
      finished_at: at()
    })

    delivery_path =
      MondekWeb.NotificationNavigation.detail_path(occurrence.id, "/notifications")

    {:ok, delivery, _} = live(build_conn(), delivery_path)
    {:ok, incident_detail, _} = live(build_conn(), "/incidents/" <> incident.id)

    for {inspection, suffix} <- [
          {delivery, "?" <> URI.encode_query(%{"return_to" => delivery_path})},
          {incident_detail, ""}
        ] do
      assert has_element?(
               inspection,
               "#notification-#{occurrence.id} a[href='/checks/#{streams["left"].id}#{suffix}']",
               "View result"
             )

      assert has_element?(
               inspection,
               "#notification-#{occurrence.id} a[href='/incidents/#{incident.id}#{suffix}']",
               "left target"
             )

      refute has_element?(
               inspection,
               "#notification-#{occurrence.id} a[href='/resources/#{id}']",
               "View check"
             )
    end

    refute has_element?(incident_detail, "#visible-attempt-count")

    assert has_element?(
             incident_detail,
             "#incident-attempts",
             "Showing 1 of 1 retained delivery attempts"
           )
  end

  test "result and shared configuration navigation returns to the filtered inventory page" do
    assert {:ok, _} = publish(for index <- 1..55, do: check("nav-#{index}"))
    path = "/checks?environment=production&page=2&search=nav-&tab=all&view=list"
    {:ok, inventory, _} = live(build_conn(), path)

    result_link =
      inventory
      |> element(
        "#check-inventory .target-group:first-of-type tbody tr:first-child .checks-result-link"
      )
      |> render_click()

    {:ok, result, _} = follow_redirect(result_link, build_conn())
    assert has_element?(result, ".back[href='#{path}']", "Back to results")
    configuration_link = result |> element("a", "Review configuration") |> render_click()
    {:ok, configuration, _} = follow_redirect(configuration_link, build_conn())
    assert has_element?(configuration, ".back", "Back to result")
    return_link = configuration |> element(".back") |> render_click()
    {:ok, returned, _} = follow_redirect(return_link, build_conn())
    assert has_element?(returned, ".back[href='#{path}']")

    {:ok, returned, _} =
      returned |> element(".back") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(returned, "#inventory-search[value='nav-']")
    assert has_element?(returned, ".pagination", "Page 2 of 2")
    assert row_count(returned, "#check-inventory tbody tr") == 5
  end

  test "detail return links reject external and unrecognized paths" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("safe-navigation")])

    for unsafe <- [
          "https://example.org/checks",
          "//example.org/checks",
          "/configuration/new",
          "/checks?return_to=https://example.org"
        ] do
      {:ok, view, _} =
        live(
          build_conn(),
          "/configuration/" <>
            assignment["id"] <> "?" <> URI.encode_query(%{"return_to" => unsafe})
        )

      refute has_element?(view, ".back[href*='example.org']")
      refute has_element?(view, ".back[href='/configuration/new']")
    end
  end

  test "empty onboarding opens source setup with an installed consumer and persistent state command" do
    Repo.query!("TRUNCATE runners, assignments, oban_jobs RESTART IDENTITY CASCADE")
    {:ok, inventory, _} = live(build_conn(), "/checks")
    guide_link = inventory |> element(".checks-setup a", "Open runner setup") |> render_click()
    {:ok, guide, _} = follow_redirect(guide_link, build_conn())
    assert has_element?(guide, "h1", "Set up a runner")

    assert has_element?(
             guide,
             "#consumer-example",
             "source_id=\"application-checks\""
           )

    assert has_element?(
             guide,
             "#runner-launch-example",
             "mondek-runner validate --consumer monitoring.app:app"
           )

    assert has_element?(
             guide,
             "#runner-launch-example",
             "--controller 'http://www.example.com'"
           )

    assert has_element?(
             guide,
             "#runner-launch-example",
             "--state-dir .mondek-state"
           )

    assert has_element?(guide, "#project-starter-example", "mondek-runner init")
    assert has_element?(guide, "#runner-agent-prompts-project-copy", "Copy prompt")
    assert has_element?(guide, "#runner-agent-prompts-retirement-text", "source-removal reason")
    assert has_element?(guide, "#runner-guide", "localhost")
    refute has_element?(guide, "a[href='/configuration/new']")
  end

  test "a retired result keeps its history and links the shared check that still schedules siblings" do
    definition =
      check("pair")
      |> Map.merge(%{
        "outputs" => [output("left"), output("right")],
        "environment" => "previous-site",
        "environment_label" => "Production"
      })

    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    assert {:ok, _} = connect(%{"prepared" => %{id => 1}})

    payload =
      measurement("CRIT")
      |> Map.put("assignment_id", id)
      |> Map.put(
        "results",
        for key <- ["left", "right"] do
          %{
            "key" => key,
            "health" => "CRIT",
            "summary" => key <> " target failed",
            "source_at" => "2009-09-15T08:00:00.010000Z"
          }
        end
      )

    assert disposition(ingest(payload)) == "current"

    left =
      Repo.one!(from s in ResultStream, where: s.assignment_id == ^id and s.result_key == "left")

    replacement =
      Map.merge(definition, %{
        "outputs" => [output("right")],
        "environment" => "current-site",
        "environment_label" => "Production"
      })

    assert {:ok, _} = publish([replacement], 2)
    refute Repo.get!(Assignment, id).retired_at

    {:ok, view, _} = live(build_conn(), "/checks/" <> left.id)
    assert has_element?(view, "#retired-check-notice", "Result retired")

    assert has_element?(
             view,
             "#retired-check-notice",
             "shared check continues scheduling its remaining results"
           )

    refute has_element?(view, "#retired-check-notice", "runner stops scheduling")
    assert has_element?(view, "a[href^='/configuration/#{id}?']", "Review configuration")
    assert has_element?(view, "a[href='/resources/#{id}']", "Inspect shared check")
    assert render(view) =~ "left target failed"
    assert has_element?(view, "#check-source", "Production (previous-site)")
    refute has_element?(view, "#check-source", "current-site")
    refute has_element?(view, "#maintenance-summary-" <> id)
    view |> element("a", "Inspect shared check") |> render_click()
    assert_redirect(view, "/resources/" <> id)
  end

  defp row_count(view, selector) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp runner_facts(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#runner-last-report .fleet-facts > div")
    |> Map.new(fn fact ->
      {fact |> LazyHTML.query("dt") |> LazyHTML.text() |> String.trim(),
       fact |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim()}
    end)
  end

  defp publish(checks, revision \\ 1) do
    result =
      Inventory.reconcile(
        control()
        |> Map.merge(%{
          "runner_label" => "Production node",
          "source_id" => "consumer.demo",
          "source_revision" => String.duplicate("a", 64),
          "inventory_revision" => revision,
          "complete" => true,
          "checks" => checks
        }),
        at()
      )

    case result do
      {:ok, _receipt} ->
        assignments =
          Repo.all(
            from a in Assignment,
              where: a.source_id == "consumer.demo" and is_nil(a.retired_at),
              order_by: a.source_key
          )

        {:ok, %{"assignments" => Enum.map(assignments, &Monitoring.public/1)}}

      error ->
        error
    end
  end

  defp check(key, owner \\ "ui") do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => owner,
      "parameter_schema" => %{
        "fields" => %{
          "limit" => %{
            "type" => "integer",
            "label" => "Threshold",
            "unit" => "items",
            "minimum" => 0,
            "maximum" => 100
          },
          "enabled" => %{"type" => "boolean", "label" => "Enabled"},
          "mode" => %{"type" => "string", "label" => "Mode", "choices" => ["normal", "strict"]},
          "target" => %{"type" => "string", "label" => "Target binding", "choices" => ["node-a"]}
        }
      },
      "params" => %{"limit" => 80, "enabled" => true, "mode" => "normal", "target" => "node-a"},
      "outputs" => [output(key)],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12
    }
  end

  defp output(key),
    do: %{
      "key" => key,
      "label" => key <> " result",
      "target" => %{"key" => key, "kind" => "node", "label" => key <> " target"}
    }
end
