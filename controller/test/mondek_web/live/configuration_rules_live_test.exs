# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationRulesLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{ConfigurationRules, Inventory}

  @endpoint MondekWeb.Endpoint

  test "shared settings preserve the originating result through review, save and reload" do
    [check] = publish([check("volume")])

    stream =
      Repo.get_by!(Mondek.ResultStream, assignment_id: check["id"]) |> Monitoring.public()

    result_path =
      "/checks/" <>
        stream["id"] <>
        "?" <> URI.encode_query(%{"return_to" => "/checks?search=volume&tab=all&view=list"})

    path =
      "/configuration/rules/new?" <>
        URI.encode_query(%{"check_id" => check["id"], "return_to" => result_path})

    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, ".back", "Back to result")

    view
    |> form("#configuration-rule-form", rule: %{name: "Journey limits"}, params: %{limit: "70"})
    |> render_submit()

    assert has_element?(view, "#rule-preview-summary", "1 configurations will change")
    view |> form("#configuration-rule-form") |> render_submit()
    saved_path = assert_patch(view)
    assert URI.decode_query(URI.parse(saved_path).query)["return_to"] == result_path
    {:ok, reopened, _} = live(build_conn(), saved_path)
    assert has_element?(reopened, ".back[href='#{result_path}']", "Back to result")

    {:ok, result, _} =
      reopened |> element(".back") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(result, "h1")
    assert has_element?(result, ".back", "Back to results")
  end

  test "opening rule creation without a check offers a useful starting point" do
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new")
    assert has_element?(view, "a[href='/configuration']", "Choose a scheduled check")
    refute has_element?(view, "#configuration-rule-form")
    refute has_element?(view, "#rule-error")
  end

  test "creating from a check previews stable scope and shows effective rule provenance" do
    [check] = publish([check("volume")])
    {:ok, detail, _} = live(build_conn(), "/configuration/" <> check["id"])
    assert has_element?(detail, "#configuration-origin", "Defaults from code")
    assert has_element?(detail, "#create-durable-rule")
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])
    assert has_element?(view, "#rule-target-key[value='volume-uid']")
    refute has_element?(view, "[name='rule[runner_id]']")

    view
    |> form("#configuration-rule-form",
      rule: %{name: "Production volume"},
      params: %{limit: "70"}
    )
    |> render_submit()

    assert has_element?(view, "#rule-preview-summary", "1 checks reviewed")
    assert has_element?(view, "#rule-preview-summary", "1 configurations will change")
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 80
    view |> form("#configuration-rule-form") |> render_submit()
    assert_patch(view)
    assert has_element?(view, "h1", "Production volume")
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 70

    {:ok, effective, _} = live(build_conn(), "/configuration/" <> check["id"])
    assert has_element?(effective, "#configuration-origin", "From rule")
    assert has_element?(effective, "#configuration-origin a", "Production volume")
    assert has_element?(effective, "button", "Review settings for this check")
  end

  test "dormant rules remain visible, editable and disableable after source withdrawal" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    publish([], 2)
    {:ok, listing, _} = live(build_conn(), "/configuration/rules")
    assert has_element?(listing, "#rule-row-#{rule["id"]}", "0 current checks")

    assert has_element?(
             listing,
             "#rule-row-#{rule["id"]}",
             "Applies when compatible checks appear"
           )

    {:ok, view, _} = live(build_conn(), "/configuration/rules/" <> rule["id"])
    assert has_element?(view, "#rule-zero-matches", "retained")
    view |> form("#configuration-rule-form", rule: %{enabled: "false"}) |> render_submit()
    assert has_element?(view, "#rule-preview-summary", "0 checks reviewed")
    view |> form("#configuration-rule-form") |> render_submit()
    assert_patch(view)
    assert {:ok, %{"enabled" => false}} = ConfigurationRules.get(rule["id"])
  end

  test "background updates and reconnect preserve an old reviewed revision and typed draft" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    path = "/configuration/rules/" <> rule["id"]
    {:ok, view, _} = live(build_conn(), path)

    view
    |> form("#configuration-rule-form",
      rule: %{name: "Unsaved operator name"},
      params: %{limit: "65"}
    )
    |> render_change()

    captured = hidden(view, "_proposal")
    {:ok, current} = ConfigurationRules.get(rule["id"])
    {:ok, preview} = ConfigurationRules.preview(Map.put(current, "name", "Saved elsewhere"))
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], preview["proposal"])
    send(view.pid, :tick)
    assert has_element?(view, "#rule-name[value='Unsaved operator name']")
    assert has_element?(view, "#rule-param-limit[value='65']")

    {:ok, recovered, _} = live(build_conn(), path)

    recovered
    |> render_change("recover", %{
      "_proposal" => captured,
      "rule" => %{"name" => "Unsaved operator name"},
      "params" => %{"limit" => "65"}
    })

    assert has_element?(recovered, "#rule-notice", "reviewed revision is preserved")
    recovered |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(recovered, "#rule-error", "draft is preserved")
    assert has_element?(recovered, "#rule-name[value='Unsaved operator name']")
    refute has_element?(recovered, "#rule-save")
    assert {:ok, %{"name" => "Saved elsewhere"}} = ConfigurationRules.get(rule["id"])
  end

  test "an inventory change invalidates a reviewed save without losing draft values" do
    [check] = publish([check("volume")])
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])
    view |> form("#configuration-rule-form", params: %{limit: "61"}) |> render_submit()
    publish([check("volume"), check("new-observer")], 2)
    view |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(view, "#rule-error", "changed")
    assert has_element?(view, "#rule-param-limit[value='61']")
    assert ConfigurationRules.list()["total"] == 0
    view |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(view, "#rule-preview-summary", "2 checks reviewed")
  end

  test "reconnect during preview restores the proposal but requires a fresh review" do
    [check] = publish([check("volume")])
    path = "/configuration/rules/new?check_id=" <> check["id"]
    {:ok, view, _} = live(build_conn(), path)

    view
    |> form("#configuration-rule-form",
      rule: %{name: "Previewed proposal"},
      params: %{limit: "62"}
    )
    |> render_submit()

    assert has_element?(view, "#rule-preview")
    captured = hidden(view, "_proposal")
    token = hidden(view, "_review_token")
    assert has_element?(view, "#configuration-rule-form[phx-auto-recover='recover']")
    {:ok, recovered, _} = live(build_conn(), path)
    recovered |> render_change("recover", %{"_proposal" => captured, "_review_token" => token})
    assert has_element?(recovered, "#rule-name[value='Previewed proposal']")
    assert has_element?(recovered, "#rule-param-limit[value='62']")
    refute has_element?(recovered, "#rule-preview")
    refute has_element?(recovered, "#rule-save")
    assert ConfigurationRules.list()["total"] == 0
  end

  test "schema refresh selects a current check and preserves values until reviewed save" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    {:ok, stored} = ConfigurationRules.get(rule["id"])
    {:ok, preview} = ConfigurationRules.preview(Map.put(stored, "enabled", false))
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], preview["proposal"])
    updated = put_in(check("volume"), ["parameter_schema", "fields", "limit", "maximum"], 99)
    publish([updated], 2)
    {:ok, view, _} = live(build_conn(), "/configuration/rules/" <> rule["id"])
    assert has_element?(view, "#rule-param-limit[max='100']")
    view |> form("#rule-refresh-schema", check_id: check["id"]) |> render_submit()
    assert has_element?(view, "#rule-param-limit[max='99'][value='70']")
    assert has_element?(view, "#rule-notice", "schema for review")
    assert {:ok, before_save} = ConfigurationRules.get(rule["id"])
    assert before_save["parameter_schema"]["fields"]["limit"]["maximum"] == 100
    view |> form("#configuration-rule-form", rule: %{enabled: "true"}) |> render_submit()
    view |> form("#configuration-rule-form") |> render_submit()
    assert_patch(view)
    assert {:ok, after_save} = ConfigurationRules.get(rule["id"])
    assert after_save["parameter_schema"]["fields"]["limit"]["maximum"] == 99
    assert after_save["enabled"]
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 70
  end

  test "equal priorities block saving and show the conflicting match" do
    [check] = publish([check("volume")])
    save_rule(check)
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])
    view |> form("#configuration-rule-form", params: %{limit: "66"}) |> render_submit()
    assert has_element?(view, "#rule-preview-summary", "1 conflicts")
    assert has_element?(view, "#rule-save[disabled]", "Save rule")
    assert has_element?(view, "#rule-preview-#{check["id"]} .form-error")
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 70
  end

  test "paging a preview detects changed membership instead of renewing the old review" do
    definitions = for index <- 1..26, do: check("volume-#{index}")
    [check | _] = publish(definitions)
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])
    view |> form("#configuration-rule-form", params: %{limit: "61"}) |> render_submit()
    assert has_element?(view, "#rule-preview-summary", "26 checks reviewed")
    publish(definitions ++ [check("new")], 2)
    view |> element("button[phx-click='preview_page']", "Next") |> render_click()
    assert has_element?(view, "#rule-error", "inventory changed")
    assert has_element?(view, "#rule-param-limit[value='61']")
    refute has_element?(view, "#rule-save")
  end

  test "scope changes explicitly show checks that leave the rule" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    {:ok, view, _} = live(build_conn(), "/configuration/rules/" <> rule["id"])

    view
    |> form("#configuration-rule-form", rule: %{target_key: "different-volume"})
    |> render_submit()

    assert has_element?(view, "#rule-preview-summary", "1 checks reviewed")
    assert has_element?(view, "#rule-preview-#{check["id"]}", "Leaving this rule's scope")
    assert has_element?(view, "#rule-preview-#{check["id"]}", "Defaults from code")
    assert has_element?(view, "#rule-preview th", "Currently saved values")
  end

  test "instance exception removal is previewed and stale review cannot replace newer settings" do
    [check] = publish([check("volume")])
    save_rule(check)
    row = Monitoring.assignment_detail(check["id"])
    assert {:ok, _} = Monitoring.save_assignment(row["id"], row["revision"], %{"limit" => 90})
    {:ok, view, _} = live(build_conn(), "/configuration/" <> row["id"])
    assert has_element?(view, "#configuration-origin", "instance exception")
    view |> element("#remove-instance-exception") |> render_click()
    assert has_element?(view, "#exception-reset-preview", "70")
    row = Monitoring.assignment_detail(check["id"])
    assert {:ok, _} = Monitoring.save_assignment(row["id"], row["revision"], %{"limit" => 95})
    view |> form("#exception-reset-form") |> render_submit()
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 95
    refute has_element?(view, "#exception-reset-preview")

    {:ok, fresh, _} = live(build_conn(), "/configuration/" <> row["id"])
    fresh |> element("#remove-instance-exception") |> render_click()
    fresh |> form("#exception-reset-form") |> render_submit()
    assert has_element?(fresh, "#configuration-origin", "From rule")
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 70
    assert Repo.get!(Assignment, check["id"]).instance_exception == nil
  end

  test "rejected source schema diagnostics become visible without replacing an edit draft" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    {:ok, view, _} = live(build_conn(), "/configuration/rules/" <> rule["id"])
    view |> form("#configuration-rule-form", rule: %{name: "Draft stays"}) |> render_change()
    incompatible = put_in(check("volume"), ["parameter_schema", "fields", "limit", "maximum"], 99)
    assert {:error, _} = Inventory.reconcile(inventory([incompatible], 2), at())
    send(view.pid, :tick)
    assert has_element?(view, "#rule-diagnostics", "rejected")
    assert has_element?(view, "#rule-name[value='Draft stays']")
  end

  defp save_rule(check) do
    {:ok, seed} = ConfigurationRules.seed(check["id"])
    {:ok, preview} = ConfigurationRules.preview(Map.put(seed, "params", %{"limit" => 70}))
    {:ok, saved} = ConfigurationRules.apply(preview["review_token"], preview["proposal"])
    saved["rule"]
  end

  test "source defaults need no policy and overridden values explain what a code edit will do" do
    [check] = publish([check("volume")])
    {:ok, defaults, _} = live(build_conn(), "/configuration/" <> check["id"])
    refute has_element?(defaults, "#configuration-value-comparison")
    assert has_element?(defaults, "#configuration-as-code", "Rules are optional")

    save_rule(check)
    [updated] = publish([put_in(check("volume"), ["params", "limit"], 85)], 2)
    assert updated["params"] == %{"limit" => 70}
    {:ok, view, _} = live(build_conn(), "/configuration/" <> check["id"])
    assert has_element?(view, "#configuration-value-comparison", "Changing defaults in Python")
    assert has_element?(view, ".configuration-difference", "85")
    assert has_element?(view, ".configuration-difference h4", "items")
    assert has_element?(view, ".configuration-difference", "70")
    assert has_element?(view, "#configuration-value-comparison", "last measurement")

    {:ok, _} = Monitoring.save_assignment(updated["id"], updated["revision"], %{"limit" => 90})
    send(view.pid, :tick)
    assert has_element?(view, "#configuration-under-exception", "rule")
    assert has_element?(view, ".configuration-difference", "Without exception")
    assert has_element?(view, ".configuration-difference", "90")
    assert has_element?(view, ".configuration-difference", "70")
    assert has_element?(view, "#configuration-editor-updated", "Your draft has been kept")
    assert has_element?(view, "input[name='params[limit]'][value='70']")
    view |> element("#configuration-editor-updated button") |> render_click()
    refute has_element?(view, "#configuration-editor-updated")
    assert has_element?(view, "input[name='params[limit]'][value='90']")
  end

  test "project rules remain editable and retain provenance after reconnect" do
    [check] = publish([check("volume")])
    rule = save_rule(check)
    path = "/configuration/rules/" <> rule["id"]
    {:ok, view, _} = live(build_conn(), path)
    assert has_element?(view, "#configuration-rule-form")

    manifest = %{
      "version" => 1,
      "project" => "personal-monitoring",
      "rules" => [
        %{
          "key" => "volume-limits",
          "name" => rule["name"],
          "source_id" => rule["source_id"],
          "parameter_contract" => rule["parameter_contract"],
          "params" => rule["params"],
          "adopt_rule_id" => rule["id"]
        }
      ]
    }

    {:ok, plan} = Mondek.ConfigurationPolicy.plan(manifest)
    assert {:ok, _} = Mondek.ConfigurationPolicy.apply(plan["review_token"], manifest)
    send(view.pid, :tick)
    assert has_element?(view, "#managed-rule", "personal-monitoring")
    assert has_element?(view, "#managed-rule", "volume-limits")
    assert has_element?(view, "#configuration-rule-form")
    assert has_element?(view, "#rule-schema-search")
    {:ok, reconnected, _} = live(build_conn(), path)
    assert has_element?(reconnected, "#managed-rule", "Edit here or through Git")
    assert has_element?(reconnected, "#configuration-rule-form")

    reconnected
    |> form("#configuration-rule-form", params: %{limit: "65"})
    |> render_submit()

    assert has_element?(reconnected, "#rule-preview-summary", "1 configurations will change")
    reconnected |> form("#configuration-rule-form") |> render_submit()
    assert_patch(reconnected)
    assert Repo.get!(Assignment, check["id"]).params["limit"] == 65
    {:ok, saved_project_rule} = ConfigurationRules.get(rule["id"])
    assert saved_project_rule["managed_project"] == "personal-monitoring"
    assert saved_project_rule["managed_key"] == "volume-limits"

    {:ok, detail, _} = live(build_conn(), "/configuration/" <> check["id"])
    assert has_element?(detail, "#configuration-value-comparison", "personal-monitoring")
    assert has_element?(detail, "button", "Review settings for this check")
    {:ok, listing, _} = live(build_conn(), "/configuration/rules")
    assert has_element?(listing, "#rule-row-#{rule["id"]}", "Project: personal-monitoring")

    manifest = %{manifest | "rules" => []}
    {:ok, state} = Mondek.ConfigurationRepository.state()
    {:ok, plan} = Mondek.ConfigurationPolicy.plan(manifest, state.head)
    assert {:ok, _} = Mondek.ConfigurationPolicy.apply(plan["review_token"], manifest)
    send(view.pid, :tick)
    assert has_element?(view, "#rule-notice", "rule was removed")
    assert has_element?(view, "a", "Browse saved rules")
    refute has_element?(view, "a", "Choose a scheduled check")
    refute has_element?(view, "#managed-rule")
  end

  defp hidden(view, name),
    do:
      view
      |> element("input[name='#{name}']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

  defp publish(checks, revision \\ 1) do
    assert {:ok, _} = Inventory.reconcile(inventory(checks, revision), at())

    Repo.all(
      from a in Assignment,
        where: a.source_id == "rules.consumer" and is_nil(a.retired_at),
        order_by: a.source_key
    )
    |> Enum.map(&Monitoring.public/1)
  end

  defp inventory(checks, revision) do
    control()
    |> Map.merge(%{
      "runner_label" => "Volume observer",
      "source_id" => "rules.consumer",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => revision,
      "complete" => true,
      "checks" => checks
    })
  end

  defp check(key) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
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
      "params" => %{"limit" => 80},
      "outputs" => [
        %{
          "key" => "result",
          "label" => key <> " result",
          "target" => %{"key" => "volume-uid", "kind" => "volume", "label" => "Shared volume"}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12
    }
  end
end
