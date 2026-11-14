# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InventoryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "five hundred results are paged before rendering and exact filters survive navigation" do
    assert {:ok, _} =
             publish(
               for index <- 1..500,
                   do: check("check-#{String.pad_leading(to_string(index), 3, "0")}")
             )

    {:ok, view, html} = live(build_conn(), "/checks?search=check-&environment=production")
    assert html =~ "500 results"
    assert row_count(view, "#preview-check-results tbody > tr") == 30
    refute has_element?(view, "#preview-check-results", "check-500 result")
    view |> element("nav[aria-label='Check results'] a[aria-label='Page 2']") |> render_click()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["environment"] == "production"
    assert row_count(view, "#preview-check-results tbody > tr") == 30
    {:ok, reopened, _} = live(build_conn(), path)
    assert row_count(reopened, "#preview-check-results tbody > tr") == 30
    {:ok, overview, _} = live(build_conn(), "/")
    assert row_count(overview, "#preview-attention tbody > tr") <= 30
  end

  test "runner inspection links its independent scheduled inventory" do
    assert {:ok, _} = publish([check("local-node")])
    runner = control()["installation_id"]
    {:ok, view, _} = live(build_conn(), "/runners/#{runner}/full")
    assert has_element?(view, "#runner-heading", "Production node")
    {:ok, inventory, _} = live(build_conn(), "/configuration?runner_id=#{runner}")
    assert has_element?(inventory, "#check-inventory", "local-node")
    assert has_element?(view, "a[href*='runner_id=#{runner}']")
  end

  test "reported scheduling backlog is distinct from buffered reports and does not age between reports" do
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
    {:ok, view, _} = live(build_conn(), "/runners/#{control()["installation_id"]}/full")
    facts = runner_facts(view)
    assert facts["Active checks on runner"] == "500"
    assert facts["Due, waiting for a slot"] == "497"
    assert facts["Buffered reports"] == "11"
    assert facts["Oldest due wait"] == "32.1 seconds"
    send(view.pid, :tick)
    assert runner_facts(view) == facts
    idle = %{scheduler | "due_waiting_checks" => 0, "oldest_due_seconds" => 0.0}
    assert {:ok, _} = connect(%{"status" => %{status | "scheduler" => idle}})
    send(view.pid, :tick)
    assert runner_facts(view)["Due, waiting for a slot"] == "0"
  end

  test "same-named runner chips retain stable IDs and exact result filtering" do
    assert {:ok, _} = publish([check("first-observer")])
    first = control()["installation_id"]
    second = Ecto.UUID.generate()

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

    options = Mondek.ChecksFilters.options("runner_id", "Production node")
    for id <- [first, second], do: assert(Enum.any?(options, &(&1.key == id)))
    {:ok, view, _} = live(build_conn(), "/checks?runner_id=#{second}")
    assert has_element?(view, "#preview-check-results", "second-observer")
    refute has_element?(view, "#preview-check-results", "first-observer")
  end

  test "source-owned values stay read-only while shared execution remains inspectable" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("owned", "source")])
    id = assignment["id"]
    {:ok, view, _} = live(build_conn(), "/configuration/#{id}")
    assert has_element?(view, "#source-owned-parameters", "owned by the source")
    refute has_element?(view, "form[id^='form-']")
    assert has_element?(view, "#config-source-context", "consumer.demo")
    {:ok, execution, _} = live(build_conn(), "/executions/#{id}")
    assert has_element?(execution, "[data-execution-body]", "consumer.demo")
    refute has_element?(execution, "#retire-check-form")
  end

  test "configuration keeps shared editing separate from results source context and retirement" do
    definition = check("shared") |> Map.put("outputs", [output("left"), output("right")])
    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    {:ok, view, _} = live(build_conn(), "/configuration/#{id}")
    assert has_element?(view, "#form-#{id} input[name='params[limit]']")
    assert row_count(view, "#configuration-results tbody > tr") == 2
    assert has_element?(view, "#config-source-context", "3 seconds")
    assert has_element?(view, "#config-source-context", "12 seconds")
    assert has_element?(view, "#check-source-revisions", String.duplicate("a", 64))
    assert has_element?(view, "#configuration-origin")
    assert {:ok, %{"assignments" => []}} = publish([], 2)
    {:ok, retired, _} = live(build_conn(), "/configuration/#{id}")
    refute has_element?(retired, "#form-#{id}")
    assert has_element?(retired, "#source-owned-parameters", "retired")
  end

  test "source schedules keep readable units and fractional precision" do
    definition =
      check("long-schedule")
      |> Map.merge(%{
        "interval_seconds" => 21_600,
        "timeout_seconds" => 0.25,
        "freshness_seconds" => 86_400.001
      })

    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    {:ok, view, _} = live(build_conn(), "/configuration/#{assignment["id"]}")
    assert has_element?(view, "#config-source-context", "6 hours")
    assert has_element?(view, "#config-source-context", "0.25 seconds")
    assert has_element?(view, "#config-source-context", "1 day 0.001 seconds")
    refute has_element?(view, "#config-source-context", "2.16e4")
  end

  test "inventory pages consistently expose the shared accessible chip picker" do
    for path <- ["/checks", "/configuration", "/incidents"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "form[phx-hook='PreviewFilterPicker'][aria-label]")
      assert has_element?(view, "form[phx-hook='PreviewFilterPicker'] input[aria-label]")
      GenServer.stop(view.pid)
    end
  end

  test "same-named environments are selected by stable ID rather than display label" do
    first =
      check("environment-a")
      |> Map.merge(%{"environment" => "region-a", "environment_label" => "Production"})

    second =
      check("environment-b")
      |> Map.merge(%{"environment" => "region-b", "environment_label" => "Production"})

    assert {:ok, _} = publish([first, second])
    options = Mondek.ChecksFilters.options("environment", "Production")
    assert Enum.sort(Enum.map(options, & &1.key)) == ["region-a", "region-b"]
    {:ok, view, _} = live(build_conn(), "/checks?environment=region-a")
    assert has_element?(view, "#preview-check-results", "environment-a result")
    refute has_element?(view, "#preview-check-results", "environment-b result")
    render_click(view, "filter_open", %{"field" => "environment"})
    render_click(view, "filter_select", %{"key" => "region-b", "kind" => ""})
    assert has_element?(view, "#preview-check-results", "environment-b result")
    refute has_element?(view, "#preview-check-results", "environment-a result")
  end

  test "environment label rename preserves result identity and incident opening evidence" do
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
    assert Repo.get!(ResultStream, stream.id).id == stream.id
    {:ok, view, _} = live(build_conn(), "/checks?environment=region-a")
    assert has_element?(view, "#preview-check-results", "Primary production")
    {:ok, history, _} = live(build_conn(), "/incidents/health/#{incident.id}/full")
    assert render(history) =~ "Production"
    assert Repo.get!(Incident, incident.id).environment_label == "Production"
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

  test "independent sibling evidence and incidents remain distinct from shared execution" do
    definition = check("pair") |> Map.put("outputs", [output("left"), output("right")])
    assert {:ok, %{"assignments" => [assignment]}} = publish([definition])
    id = assignment["id"]
    assert {:ok, _} = connect(%{"prepared" => %{id => 1}})

    payload =
      measurement("CRIT")
      |> Map.put("assignment_id", id)
      |> Map.put(
        "results",
        for(
          {key, health} <- [{"left", "CRIT"}, {"right", "OK"}],
          do: %{
            "key" => key,
            "health" => health,
            "summary" => key <> " measured independently",
            "source_at" => "2009-09-15T08:00:00.010000Z"
          }
        )
      )

    assert disposition(ingest(payload)) == "current"

    streams =
      Repo.all(from s in ResultStream, where: s.assignment_id == ^id)
      |> Map.new(&{&1.result_key, &1})

    for {key, health} <- [{"left", "Critical"}, {"right", "Healthy"}] do
      {:ok, view, _} = live(build_conn(), "/results/#{streams[key].id}/full")
      assert has_element?(view, "#full-result-heading", key)
      assert render(view) =~ health
      assert render(view) =~ key <> " measured independently"
    end

    assert Repo.aggregate(from(i in Incident, where: i.assignment_id == ^id), :count) == 1
    {:ok, execution, _} = live(build_conn(), "/executions/#{id}")
    assert row_count(execution, "#execution-results tbody > tr") == 2
  end

  test "result investigation and shared configuration retain filtered inventory return" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("disk")])
    stream = Repo.one!(from s in ResultStream, where: s.assignment_id == ^assignment["id"])
    path = "/checks?search=disk&environment=production"
    {:ok, view, _} = live(build_conn(), path)
    view |> element("#open-result-#{stream.id}") |> render_click()
    panel_path = assert_patch(view)
    assert has_element?(view, "#overview-panel")
    {:ok, restored, _} = live(build_conn(), panel_path)
    assert has_element?(restored, "#overview-panel")

    assert has_element?(
             restored,
             ".preview-filter-chip button[aria-label^='Edit Environment filter']",
             "production"
           )

    assert has_element?(restored, "form[phx-hook='PreviewFilterPicker'][data-search='disk']")
    assert has_element?(restored, ".preview-search-token[title='disk']", "disk")
  end

  test "detail return links reject external and unknown browser paths" do
    assert {:ok, %{"assignments" => [assignment]}} = publish([check("disk")])

    for return_to <- ["https://other.invalid/checks", "//other.invalid/checks", "/unknown"] do
      path =
        "/configuration/#{assignment["id"]}?" <> URI.encode_query(%{"return_to" => return_to})

      {:ok, view, _} = live(build_conn(), path)
      refute has_element?(view, "a[href='#{return_to}']")
      assert has_element?(view, "a[href='/configuration']")
    end
  end

  test "empty overview directs operators to source setup and persistent runner state" do
    Repo.query!("TRUNCATE runners, assignments, oban_jobs RESTART IDENTITY CASCADE")
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#runner-onboarding", "Install your consumer package on a runner")
    assert has_element?(view, "#runner-onboarding a[href='/guide']")
    {:ok, guide, _} = live(build_conn(), "/guide")
    assert has_element?(guide, "#runner-launch-example", "--state-dir .mondek-state")
    assert has_element?(guide, "#project-starter-example", "mondek-runner init")
    assert has_element?(guide, "#runner-agent-prompts-project-copy", "Copy prompt")
    refute has_element?(guide, "a[href='/configuration/new']")
  end

  test "retired result retains historical environment and failure while siblings remain scheduled" do
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
        for(
          key <- ["left", "right"],
          do: %{
            "key" => key,
            "health" => "CRIT",
            "summary" => key <> " target failed",
            "source_at" => "2009-09-15T08:00:00.010000Z"
          }
        )
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
    {:ok, view, _} = live(build_conn(), "/results/#{left.id}/full")
    assert render(view) =~ "Retired"
    assert render(view) =~ "left target failed"
    assert Repo.get!(ResultStream, left.id).environment == "previous-site"
    assert has_element?(view, "a", "Shared execution and history")
  end

  defp row_count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

  defp runner_facts(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#runner-last-report table tbody > tr")
    |> Map.new(fn row ->
      {row |> LazyHTML.query("th") |> LazyHTML.text() |> String.trim(),
       row |> LazyHTML.query("td") |> LazyHTML.text() |> String.trim()}
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
