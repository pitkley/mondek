# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationHierarchyLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Inventory

  @endpoint MondekWeb.Endpoint

  test "an offline save keeps adoption ahead of the editor and provides investigation links" do
    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    view
    |> form("#form-10000000-0000-4000-8000-000000000001",
      params: %{path: "/", warn_percent: "70", crit_percent: "85"}
    )
    |> render_submit()

    assert has_element?(view, "#instance-save-review")
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 1
    view |> element("#confirm-instance-save") |> render_click()

    assert has_element?(
             view,
             "#configuration-adoption-status ~ .config-grid #form-10000000-0000-4000-8000-000000000001"
           )

    assert has_element?(
             view,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Version v2 is saved"
           )

    assert has_element?(
             view,
             "#feedback-10000000-0000-4000-8000-000000000001",
             "Inspect configuration adoption above"
           )

    refute has_element?(
             view,
             "#feedback-10000000-0000-4000-8000-000000000001",
             "must collect a new measurement"
           )

    assert has_element?(
             view,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "offline changes remain pending"
           )

    assert has_element?(view, "#configuration-adoption-status a[href='#configuration-results']")
    assert has_element?(view, "#configuration-adoption-status a[href^='/runners']")
    assert has_element?(view, "#configuration-results[tabindex='-1']")
    assert has_element?(view, "#configuration-adoption-versions:not([open]) .stages")

    refute has_element?(
             view,
             "details #configuration-progress-10000000-0000-4000-8000-000000000001"
           )

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").active_generation == nil

    {:ok, reopened, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    assert has_element?(
             reopened,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Version v2 is saved"
           )

    assert has_element?(
             reopened,
             "#10000000-0000-4000-8000-000000000001-warn_percent[value='70']"
           )
  end

  test "invalid parameters stay in the primary form without advancing saved adoption" do
    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")

    view
    |> form("#form-10000000-0000-4000-8000-000000000001",
      params: %{path: "/", warn_percent: "95", crit_percent: "80"}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#form-10000000-0000-4000-8000-000000000001 #error-10000000-0000-4000-8000-000000000001[role='alert']"
           )

    refute has_element?(view, "details #error-10000000-0000-4000-8000-000000000001")

    assert has_element?(
             view,
             "#10000000-0000-4000-8000-000000000001-warn_percent[value='95'][aria-invalid='true']"
           )

    assert has_element?(
             view,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Version v1 is saved"
           )

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 1
  end

  test "completed adoption remains a milestone when its measurement is stale" do
    assert {:ok, _} = connect()
    assert disposition(ingest(measurement("CRIT"))) == "current"

    {:ok, view, _} = live(build_conn(), "/configuration/10000000-0000-4000-8000-000000000001")
    assert has_element?(view, "#configuration-adoption-heading", "Saved version measured")

    assert has_element?(
             view,
             "#configuration-progress-10000000-0000-4000-8000-000000000001",
             "Measurement freshness is shown separately"
           )

    assert has_element?(view, "#configuration-results .badge", "Stale")
    refute has_element?(view, "#configuration-adoption-status .config-adoption-next")
    refute has_element?(view, "#configuration-adoption-status", "Fresh measurement")
    assert has_element?(view, "#config-source-context:not([open]) #check-schedule")
  end

  test "installation stage shortcuts disclose their scope and reset unrelated filters" do
    {:ok, view, _} = live(build_conn(), "/configuration?search=not-present&environment=another")
    assert has_element?(view, "#configuration-adoption-summary", "0 matching")

    assert has_element?(
             view,
             "#configuration-adoption-summary",
             "Selecting a stage clears other filters"
           )

    assert has_element?(view, "#configuration-stage-help:not([open])")

    assert has_element?(
             view,
             "#check-inventory ~ details#configuration-adoption-summary:not([open])"
           )

    view |> element(".config-adoption-count", "Saved") |> render_click()
    path = assert_patch(view)

    assert URI.decode_query(URI.parse(path).query) == %{
             "configuration_stage" => "saved",
             "status" => "active"
           }

    assert has_element?(view, "#configuration-adoption-summary", "3 matching")
  end

  test "configuration starts with durable shared settings and distinguishes selected exceptions" do
    {:ok, view, _} = live(build_conn(), "/configuration")

    assert has_element?(
             view,
             "#new-shared-rule[href='/configuration/rules/new']",
             "New shared rule"
           )

    assert has_element?(view, ".configuration-intents", "not future checks")
    assert has_element?(view, ".configuration-intents a[href='#check-inventory']")
    assert has_element?(view, "#check-inventory ~ #configuration-adoption-summary")
  end

  test "source-owned and retired checks keep their saved values without an editable form" do
    definition = definition("source")
    inventory = inventory(definition)

    assert {:ok, _} = Inventory.reconcile(inventory, at())

    assignment =
      Repo.get_by!(Assignment, source_id: "hierarchy.consumer", source_key: "fixed")
      |> Monitoring.public()

    path = "/configuration/" <> assignment["id"]
    {:ok, fixed, _} = live(build_conn(), path)
    assert has_element?(fixed, "#source-owned-parameters", "owned by the source")
    assert has_element?(fixed, "#configuration-#{assignment["id"]} .kv", "80")
    refute has_element?(fixed, "#form-#{assignment["id"]}")
    assert has_element?(fixed, "#config-source-context:not([open]) #check-source")

    {:ok, listing, _} = live(build_conn(), "/configuration?search=Source-owned")
    assert has_element?(listing, "#configuration-row-#{assignment["id"]}", "every 6 hours")
    refute has_element?(listing, "#configuration-row-#{assignment["id"]}", "2.16e4")

    assert {:ok, _} =
             Inventory.reconcile(%{inventory | "inventory_revision" => 2, "checks" => []}, at())

    {:ok, retired, _} = live(build_conn(), path)
    assert has_element?(retired, "#source-owned-parameters", "This check is retired")
    refute has_element?(retired, "#configuration-adoption-status")
    refute has_element?(retired, "#form-#{assignment["id"]}")
  end

  test "bulk selection reveals applicable actions and returns to compact guidance after clearing" do
    definition =
      definition("ui")
      |> Map.merge(%{
        "parameter_contract" => "capacity.v1",
        "parameter_schema" => %{
          "fields" => %{"limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
        }
      })

    assert {:ok, _} = Inventory.reconcile(inventory(definition), at())

    assignment =
      Repo.get_by!(Assignment, source_id: "hierarchy.consumer", source_key: "fixed")
      |> Monitoring.public()

    {:ok, view, _} = live(build_conn(), "/configuration?environment=production")
    assert has_element?(view, "#bulk-start-guidance", "select a checkbox")
    refute has_element?(view, "button[phx-click='prepare']")
    refute has_element?(view, "button[phx-click='clear']")
    refute has_element?(view, "#bulk-exception-guidance")

    view
    |> form("#bulk-configuration-form", %{
      "selected" => %{assignment["id"] => to_string(assignment["revision"])}
    })
    |> render_change(%{"_target" => ["selected", assignment["id"]]})

    assert has_element?(view, "#bulk-selection-count", "1 selected")
    assert has_element?(view, "button[phx-click='prepare']:not([disabled])")
    assert has_element?(view, "#bulk-exception-guidance", "instance exceptions")
    refute has_element?(view, "#bulk-start-guidance")
    view |> element("button[phx-click='clear']") |> render_click()
    assert has_element?(view, "#bulk-start-guidance")
    refute has_element?(view, "button[phx-click='prepare']")
  end

  defp definition(owner) do
    %{
      "key" => "fixed",
      "label" => "Source-owned check",
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => owner,
      "parameter_schema" => %{
        "fields" => %{"limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
      },
      "params" => %{"limit" => 80},
      "outputs" => [
        %{
          "key" => "result",
          "label" => "Capacity",
          "target" => %{"kind" => "host", "key" => "node", "label" => "Node"}
        }
      ],
      "interval_seconds" => 21_600,
      "timeout_seconds" => 2,
      "freshness_seconds" => 64_800
    }
  end

  defp inventory(definition) do
    control()
    |> Map.merge(%{
      "runner_label" => "Node observer",
      "source_id" => "hierarchy.consumer",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [definition]
    })
  end
end
