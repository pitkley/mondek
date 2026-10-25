# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BulkConfigurationLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Inventory

  @endpoint MondekWeb.Endpoint

  test "active bulk work and feedback precede a full inventory page without losing selection controls" do
    [first, second | _] =
      publish(
        for index <- 1..53, do: check("order-#{String.pad_leading(to_string(index), 2, "0")}")
      )

    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    assert row_count(view, "[id^='configuration-row-']") == 50
    select_check(view, first)
    click(view, "prepare")
    assert_before_inventory(view, "bulk-editor", first["id"])
    assert has_element?(view, "#bulk-select-#{second["id"]}:not([disabled])")
    view |> form("#bulk-configuration-form", params: %{limit: "101"}) |> render_submit()
    assert_before_inventory(view, "bulk-error", first["id"])
    assert_before_inventory(view, "bulk-editor", first["id"])
    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()
    assert_before_inventory(view, "bulk-preview", first["id"])
    assert has_element?(view, "#bulk-select-#{first["id"]}[checked][disabled]")
    click(view, "back")
    select_check(view, second)
    assert has_element?(view, "#bulk-selection-count", "2 selected")
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()
    view |> form("#bulk-configuration-form") |> render_submit()
    assert_before_inventory(view, "bulk-notice", first["id"])
    assert_before_inventory(view, "bulk-progress", first["id"])
    assert row_count(view, "[id^='configuration-row-']") == 50
    assert Repo.get!(Assignment, first["id"]).params["limit"] == 70
    assert Repo.get!(Assignment, second["id"]).params["limit"] == 70
  end

  defp assert_before_inventory(view, id, check_id) do
    html = render(view)
    {task_position, _} = :binary.match(html, ~s(id="#{id}"))
    {inventory_position, _} = :binary.match(html, ~s(id="configuration-row-#{check_id}"))
    assert task_position < inventory_position
  end

  test "an empty adoption filter offers filtering guidance and preserves off-page selection" do
    [check] = publish([check("waiting")])

    {:ok, empty, html} =
      live(build_conn(), "/configuration?environment=bulk-test&configuration_stage=measured")

    assert has_element?(empty, "#configuration-adoption-summary", "0 matching")
    assert has_element?(empty, "#bulk-configuration", "No matching checks")
    refute has_element?(empty, "#bulk-individual-guidance")
    refute html =~ "Open a check below"
    refute html =~ "Your existing selection is preserved"

    {:ok, selected, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(selected, check)
    selected |> form("#inventory-filters", configuration_stage: "measured") |> render_change()
    assert has_element?(selected, "#configuration-adoption-summary", "0 matching")
    assert has_element?(selected, "#bulk-selection-count", "1 selected")
    assert has_element?(selected, "button[phx-click='prepare']:not([disabled])")
    assert has_element?(selected, "#bulk-configuration", "Your existing selection is preserved")
    refute has_element?(selected, "#bulk-individual-guidance")
  end

  test "adoption filters page the desired stage and survive reload and detail navigation" do
    assignments =
      publish(
        for index <- 1..53, do: check("phase-#{String.pad_leading(to_string(index), 2, "0")}")
      )

    first = hd(assignments)

    Repo.update_all(from(a in Assignment, where: a.id == ^first["id"]),
      set: [prepared_generation: 1]
    )

    path = "/configuration?configuration_stage=saved&environment=bulk-test"
    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, "#inventory-configuration-stage option[value='saved'][selected]")
    assert has_element?(view, "#configuration-adoption-summary", "52 matching")
    assert has_element?(view, "#configuration-adoption-summary", "53 before the adoption filter")

    assert has_element?(
             view,
             "#configuration-adoption-summary",
             "56 active checks across the installation"
           )

    assert has_element?(
             view,
             "#configuration-adoption-summary",
             "Measured means fresh complete evidence arrived"
           )

    assert row_count(view, "[id^='configuration-row-']") == 50
    view |> element("#check-inventory > .pagination a", "Next") |> render_click()
    page_path = assert_patch(view)
    assert URI.decode_query(URI.parse(page_path).query)["configuration_stage"] == "saved"
    assert row_count(view, "[id^='configuration-row-']") == 2

    {:ok, reloaded, _} = live(build_conn(), page_path)

    assert has_element?(
             reloaded,
             "#inventory-configuration-stage option[value='saved'][selected]"
           )

    assert has_element?(reloaded, "#check-inventory > .pagination", "Page 2 of 2")
    navigation = reloaded |> element("[id^='configuration-row-']:first-child a") |> render_click()
    {:ok, detail, _} = follow_redirect(navigation, build_conn())
    assert has_element?(detail, ".back[href='#{page_path}']")

    view |> form("#inventory-filters", configuration_stage: "prepared") |> render_change()
    filtered_path = assert_patch(view)
    filters = URI.decode_query(URI.parse(filtered_path).query)
    assert filters["configuration_stage"] == "prepared"
    refute Map.has_key?(filters, "page")
    assert row_count(view, "[id^='configuration-row-']") == 1
    assert has_element?(view, "#configuration-row-#{first["id"]}", "Prepared")
  end

  test "changing adoption filters keeps an off-page reviewed draft through reconnect" do
    [first, second] = publish([check("first"), check("second")])

    Repo.update_all(from(a in Assignment, where: a.id == ^second["id"]),
      set: [prepared_generation: 1, active_generation: 1, observed_generation: 1]
    )

    {:ok, view, _} =
      live(build_conn(), "/configuration?configuration_stage=saved&environment=bulk-test")

    select_check(view, first)
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "73"}) |> render_change()
    original_selection = hidden(view, "_selection")
    original_token = hidden(view, "_prepare_token")
    view |> form("#inventory-filters", configuration_stage: "measured") |> render_change()
    filtered_path = assert_patch(view)
    assert has_element?(view, "#configuration-row-#{second["id"]}", "Measured")
    refute has_element?(view, "#configuration-row-#{first["id"]}")
    assert has_element?(view, "#bulk-param-limit[value='73']")
    assert hidden(view, "_selection") == original_selection
    recovered = recovery_form(view)
    {:ok, reconnected, _} = live(build_conn(), filtered_path)
    reconnected |> with_target("#bulk-configuration") |> render_change("recover", recovered)

    assert has_element?(
             reconnected,
             "#inventory-configuration-stage option[value='measured'][selected]"
           )

    assert has_element?(reconnected, "#bulk-param-limit[value='73']")
    assert hidden(reconnected, "_selection") == original_selection
    assert hidden(reconnected, "_prepare_token") == original_token
    assert Repo.get!(Assignment, first["id"]).params["limit"] == 80
  end

  test "a page of source-owned or individual checks offers usable individual guidance" do
    checks =
      [
        Map.delete(check("first"), "parameter_contract"),
        Map.delete(check("second"), "parameter_contract"),
        check("third") |> Map.delete("parameter_contract") |> Map.put("params_owner", "source")
      ]

    [first | _] = publish(checks)
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    assert has_element?(view, "#bulk-individual-guidance", "Configure these checks individually")
    assert has_element?(view, "#bulk-individual-guidance", "source-owned settings")
    refute has_element?(view, "button[phx-click='select_matching']")
    refute has_element?(view, "button[phx-click='prepare']")
    refute render(view) =~ "Select the first check below"
    assert row_count(view, "[id^='configuration-row-'] a") == 3
    assert row_count(view, "[id^='bulk-select-'][disabled]") == 3
    view |> element("#configuration-row-#{first["id"]} a") |> render_click()

    assert_redirect(
      view,
      "/configuration/" <> first["id"] <> "?return_to=%2Fconfiguration%3Fenvironment%3Dbulk-test"
    )
  end

  test "an ineligible page preserves off-page selection and saved progress until explicitly cleared" do
    checks = [
      check("a-shared")
      | for(
          index <- 1..51,
          do:
            Map.delete(
              check("b-#{String.pad_leading(to_string(index), 2, "0")}"),
              "parameter_contract"
            )
        )
    ]

    [shared | _] = publish(checks)
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, shared)
    view |> element("#check-inventory > .pagination a", "Next") |> render_click()
    assert has_element?(view, "#bulk-selection-count", "1 selected")
    refute has_element?(view, "#bulk-individual-guidance")
    assert has_element?(view, "button[phx-click='prepare']:not([disabled])")
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()
    view |> form("#bulk-configuration-form") |> render_submit()
    assert has_element?(view, "#bulk-progress", "Saved configuration progress")
    refute has_element?(view, "#bulk-individual-guidance")
    click(view, "clear")
    assert has_element?(view, "#bulk-individual-guidance")
    refute has_element?(view, "#bulk-progress")
    view |> element("#check-inventory > .pagination a", "Previous") |> render_click()
    refute has_element?(view, "#bulk-individual-guidance")
    assert has_element?(view, "#bulk-start-guidance", "select a checkbox")
    refute has_element?(view, "button[phx-click='select_matching']")
    assert has_element?(view, "#bulk-select-#{shared["id"]}:not([disabled])")
  end

  test "selection stays fixed across inventory pages and preview pages show exact targets" do
    checks =
      for index <- 1..53, do: check("batch-#{String.pad_leading(to_string(index), 2, "0")}")

    assignments = publish(checks)
    first = hd(assignments)
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    click(view, "select_matching")
    assert has_element?(view, "#bulk-selection-count", "53 selected")

    view |> element("#check-inventory > .pagination a", "Next") |> render_click()
    assert_patch(view, "/configuration?environment=bulk-test&page=2")
    assert has_element?(view, "#bulk-selection-count", "53 selected")
    assert has_element?(view, "#bulk-select-#{List.last(assignments)["id"]}[checked]")

    publish(checks ++ [check("batch-54")], 2)
    send(view.pid, :tick)
    assert has_element?(view, "#bulk-selection-count", "53 selected")
    click(view, "prepare")
    assert has_element?(view, "#bulk-editor", "53 expected results")
    assert has_element?(view, "#bulk-param-limit[value='80']")

    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()
    assert has_element?(view, "#bulk-preview-summary", "53 checks will change")
    assert row_count(view, "#bulk-preview tbody tr") == 25
    assert has_element?(view, "#bulk-preview", "target")
    original_token = hidden(view, "_review_token")
    view |> element("#bulk-preview button", "Next review page") |> render_click()
    assert has_element?(view, "#bulk-preview .pagination", "Page 2 of 3")
    assert hidden(view, "_review_token") == original_token
    assert row_count(view, "#bulk-preview tbody tr") == 25
    refute render(view) =~ "batch-54 target"
  end

  test "mixed values require a deliberate complete proposal before the atomic save" do
    [first, second] = publish([check("first", 80), check("second", 90)])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    select_check(view, second)
    click(view, "prepare")
    assert has_element?(view, "#bulk-param-limit[disabled]")
    refute has_element?(view, "#bulk-param-limit[value='80']")
    refute has_element?(view, "#bulk-param-limit[value='90']")
    view |> form("#bulk-configuration-form") |> render_submit()
    assert has_element?(view, "#bulk-error", "Choose one proposed value")
    assert Repo.get!(Assignment, first["id"]).revision == first["revision"]

    view |> form("#bulk-configuration-form", resolved: %{limit: "true"}) |> render_change()
    refute has_element?(view, "#bulk-param-limit[disabled]")
    view |> form("#bulk-configuration-form", params: %{limit: "80"}) |> render_submit()
    assert has_element?(view, "#bulk-preview-summary", "1 checks will change; 1 already")
    assert has_element?(view, "#bulk-preview", "Saving updates this complete set together")
    view |> form("#bulk-configuration-form") |> render_submit()
    assert has_element?(view, "#bulk-notice", "Saved 1 checks together. 1 already")
    assert Repo.get!(Assignment, first["id"]).revision == first["revision"]
    changed = Repo.get!(Assignment, second["id"])
    assert changed.revision == second["revision"] + 1
    assert changed.params["limit"] == 80
    assert has_element?(view, "#bulk-progress", "2 pending")

    assert {:ok, _} = Monitoring.save_assignment(first["id"], first["revision"], %{"limit" => 65})
    send(view.pid, :tick)
    assert has_element?(view, "#bulk-progress-#{first["id"]}", "Superseded")
    assert has_element?(view, "#bulk-progress", "1 pending")
  end

  test "review distinguishes same-named targets and singular result counts" do
    checks =
      for key <- ["first", "second"] do
        check(key)
        |> Map.put("outputs", [
          %{
            "key" => "result",
            "label" => "Shared result label",
            "target" => %{"key" => key, "label" => "Same target name", "kind" => "node"}
          }
        ])
      end

    [first, _second] = publish(checks)
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    assert has_element?(view, "#configuration-row-#{first["id"]}", "1 expected result ·")
    refute render(view) =~ "1 expected results"
    select_check(view, first)
    click(view, "select_matching")
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()
    assert has_element?(view, "#bulk-preview", "Same target name (first)")
    assert has_element?(view, "#bulk-preview", "Same target name (second)")
  end

  test "a stale reviewed member rejects the whole save and preserves proposed values" do
    [first, second] = publish([check("first"), check("second")])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    select_check(view, second)
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "70"}) |> render_submit()

    assert {:ok, _} =
             Monitoring.save_assignment(second["id"], second["revision"], %{"limit" => 60})

    view |> form("#bulk-configuration-form") |> render_submit()
    assert has_element?(view, "#bulk-error", "selected checks changed")
    assert Repo.get!(Assignment, first["id"]).params["limit"] == 80
    assert Repo.get!(Assignment, second["id"]).params["limit"] == 60
    click(view, "back")
    assert has_element?(view, "#bulk-param-limit[value='70']")
    click(view, "prepare")
    assert has_element?(view, "#bulk-error", "selected checks changed")
    assert has_element?(view, "#bulk-param-limit[value='70']")
    assert has_element?(view, "#bulk-affected-checks", "1 selected checks changed")
    assert has_element?(view, "#bulk-affected-checks a[target='_blank']", second["id"])
    click(view, "remove_affected")
    assert has_element?(view, "#bulk-selection-count", "1 selected")
    assert Jason.decode!(hidden(view, "_draft"))["limit"] in [70, "70"]
    click(view, "prepare")
    assert has_element?(view, "#bulk-param-limit[value='70']")
    view |> form("#bulk-configuration-form") |> render_submit()
    assert has_element?(view, "#bulk-preview a[target='_blank']", "opens in a new tab")
    view |> form("#bulk-configuration-form") |> render_submit()
    assert Repo.get!(Assignment, first["id"]).params["limit"] == 70
    assert Repo.get!(Assignment, second["id"]).params["limit"] == 60
  end

  test "component recovery restores exact selection and draft without renewing its prepare token" do
    [assignment] = publish([check("first")])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, assignment)
    click(view, "prepare")
    view |> form("#bulk-configuration-form", params: %{limit: "73"}) |> render_change()
    recovered = recovery_form(view)
    original_token = recovered["_prepare_token"]
    {:ok, reconnected, _} = live(build_conn(), "/configuration?environment=bulk-test")
    reconnected |> with_target("#bulk-configuration") |> render_change("recover", recovered)
    assert has_element?(reconnected, "#bulk-selection-count", "1 selected")
    assert has_element?(reconnected, "#bulk-param-limit[value='73']")
    assert has_element?(reconnected, "#bulk-notice", "Review changes again")
    assert hidden(reconnected, "_prepare_token") == original_token
    assert hidden(reconnected, "_review_token") == ""

    assert {:ok, _} =
             Monitoring.save_assignment(assignment["id"], assignment["revision"], %{"limit" => 65})

    {:ok, stale, _} = live(build_conn(), "/configuration?environment=bulk-test")
    stale |> with_target("#bulk-configuration") |> render_change("recover", recovered)
    assert has_element?(stale, "#bulk-error", "selected checks changed")
    assert Jason.decode!(hidden(stale, "_draft"))["limit"] == "73"

    assert Jason.decode!(hidden(stale, "_selection")) == [
             %{"id" => assignment["id"], "revision" => assignment["revision"]}
           ]

    refute has_element?(stale, "#bulk-preview")
  end

  test "adding a page never refreshes an already selected revision" do
    [first, second] = publish([check("first"), check("second")])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    assert {:ok, _} = Monitoring.save_assignment(first["id"], first["revision"], %{"limit" => 60})
    send(view.pid, :tick)
    click(view, "select_page")

    assert Jason.decode!(hidden(view, "_selection")) |> Enum.sort_by(& &1["id"]) ==
             Enum.sort_by(
               [Map.take(first, ["id", "revision"]), Map.take(second, ["id", "revision"])],
               & &1["id"]
             )

    click(view, "prepare")
    assert has_element?(view, "#bulk-error", "selected checks changed")
  end

  test "recovery includes the last browser checkbox changes while preserving off-page selections" do
    [first, second, third] = publish([check("first"), check("second"), check("third")])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    select_check(view, third)
    click(view, "prepare")
    recovered = recovery_form(view)
    # The socket closes before these visible-page changes reach the server.
    recovered =
      Map.put(recovered, "selected", %{
        first["id"] => "",
        second["id"] => to_string(second["revision"])
      })

    {:ok, reconnected, _} = live(build_conn(), "/configuration?environment=bulk-test")
    reconnected |> with_target("#bulk-configuration") |> render_change("recover", recovered)
    assert has_element?(reconnected, "#bulk-selection-count", "2 selected")
    refute has_element?(reconnected, "#bulk-select-#{first["id"]}[checked]")
    assert has_element?(reconnected, "#bulk-select-#{second["id"]}[checked]")
    assert has_element?(reconnected, "#bulk-select-#{third["id"]}[checked]")
    assert hidden(reconnected, "_prepare_token") == ""
    refute has_element?(reconnected, "#bulk-editor")

    assert {:ok, changed} =
             Monitoring.save_assignment(third["id"], third["revision"], %{"limit" => 60})

    stale_form = Map.put(recovered, "selected", %{third["id"] => to_string(changed["revision"])})
    {:ok, stale, _} = live(build_conn(), "/configuration?environment=bulk-test")
    stale |> with_target("#bulk-configuration") |> render_change("recover", stale_form)
    assert has_element?(stale, "#bulk-error", "selected checks changed")

    assert Enum.find(Jason.decode!(hidden(stale, "_selection")), &(&1["id"] == third["id"]))[
             "revision"
           ] == third["revision"]
  end

  test "adding all matches never replaces a stale selection with current revisions" do
    [first, _second] = publish([check("first"), check("second")])
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    select_check(view, first)
    assert {:ok, _} = Monitoring.save_assignment(first["id"], first["revision"], %{"limit" => 60})
    send(view.pid, :tick)
    click(view, "select_matching")
    assert Jason.decode!(hidden(view, "_selection")) == [Map.take(first, ["id", "revision"])]
    assert has_element?(view, "#bulk-error", "selected checks changed")
  end

  test "shared-schema checks without declared meaning remain individually editable" do
    checks = [
      check("shared"),
      Map.delete(check("individual"), "parameter_contract"),
      check("source") |> Map.put("params_owner", "source") |> Map.delete("parameter_contract"),
      Map.put(check("other"), "parameter_contract", "other.v1")
    ]

    assignments = publish(checks) |> Map.new(&{&1["label"], &1})
    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    assert has_element?(view, "#bulk-select-#{assignments["individual"]["id"]}[disabled]")
    assert has_element?(view, "#bulk-select-#{assignments["source"]["id"]}[disabled]")
    select_check(view, assignments["shared"])
    assert has_element?(view, "#bulk-select-#{assignments["other"]["id"]}[disabled]")
    click(view, "select_matching")
    assert has_element?(view, "#bulk-selection-count", "1 selected")

    {:ok, individual, _} =
      live(build_conn(), "/configuration/" <> assignments["individual"]["id"])

    assert has_element?(individual, "#form-#{assignments["individual"]["id"]}")
    assert has_element?(individual, "input[name='params[limit]'][value='80']")
  end

  test "scheduled check rows use complete group measurement progress" do
    [assignment] = publish([check("measured")])
    id = assignment["id"]
    generation = assignment["desired_generation"]

    Repo.update_all(from(a in Assignment, where: a.id == ^id),
      set: [active_generation: generation, observed_generation: generation]
    )

    {:ok, view, _} = live(build_conn(), "/configuration?environment=bulk-test")
    assert has_element?(view, "#configuration-row-#{id}", "Measured")
  end

  defp select_check(view, assignment) do
    view
    |> form("#bulk-configuration-form")
    |> render_change(%{
      "_target" => ["selected", assignment["id"]],
      "selected" => %{assignment["id"] => to_string(assignment["revision"])}
    })
  end

  defp click(view, event),
    do: view |> element("#bulk-configuration-form button[phx-click='#{event}']") |> render_click()

  defp hidden(view, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#bulk-configuration-form input[name='#{name}']")
    |> LazyHTML.attribute("value")
    |> List.first() || ""
  end

  defp recovery_form(view) do
    for name <-
          ~w(_selection _schema_fingerprint _prepare_token _review_token _draft _resolved _receipts _phase),
        into: %{},
        do: {name, hidden(view, name)}
  end

  defp row_count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

  defp publish(checks, revision \\ 1) do
    assert {:ok, _} =
             Inventory.reconcile(
               control()
               |> Map.merge(%{
                 "runner_label" => "Bulk test runner",
                 "source_id" => "bulk.consumer",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => revision,
                 "complete" => true,
                 "checks" => checks
               }),
               at()
             )

    Repo.all(
      from a in Assignment,
        where: a.source_id == "bulk.consumer" and is_nil(a.retired_at),
        order_by: a.source_key
    )
    |> Enum.map(&Monitoring.public/1)
  end

  defp check(key, limit \\ 80) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "bulk-test",
      "params_owner" => "ui",
      "parameter_contract" => "capacity.v1",
      "parameter_schema" => %{
        "fields" => %{
          "limit" => %{
            "type" => "integer",
            "label" => "Threshold",
            "unit" => "items",
            "minimum" => 0,
            "maximum" => 100
          }
        }
      },
      "params" => %{"limit" => limit},
      "outputs" => [
        %{
          "key" => "result",
          "label" => key <> " result",
          "target" => %{"key" => key, "kind" => "node", "label" => key <> " target"}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12
    }
  end
end
