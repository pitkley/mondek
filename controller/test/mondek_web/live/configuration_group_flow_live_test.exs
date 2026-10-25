# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationGroupFlowLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.Inventory
  @endpoint MondekWeb.Endpoint

  test "shared entry discovers declared groups and does not borrow its example's target scope" do
    [first, _] = publish([check("Disk alpha"), check("Disk beta")])
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new")
    assert has_element?(view, "#configuration-group-chooser", "2 scheduled checks")
    assert has_element?(view, "#configuration-group-chooser", "Threshold")
    assert has_element?(view, "#configuration-group-chooser", "other check names")
    view |> form("#configuration-group-search", search: "Threshold") |> render_submit()
    assert_patch(view, "/configuration/rules/new?page=1&search=Threshold")
    assert has_element?(view, "#configuration-group-chooser", "2 scheduled checks")

    {:ok, group, _} =
      live(build_conn(), "/configuration/rules/new?group=1&check_id=" <> first["id"])

    assert has_element?(group, "#rule-environment-scope option[value='all'][selected]")
    assert has_element?(group, "#rule-target-scope option[value='all'][selected]")
    assert has_element?(group, "#rule-seed-context", "one example check")
    refute has_element?(group, "#rule-target-key")
    group |> form("#configuration-rule-form", params: %{limit: "70"}) |> render_submit()
    assert has_element?(group, "#rule-preview-summary", "2 checks reviewed")
    assert has_element?(group, "#rule-preview", "All environments")
  end

  test "individual entry preserves exact scope and offers stable identities with labels" do
    [check] = publish([check("Disk alpha")])
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])
    assert has_element?(view, "#rule-environment[value='production']")
    assert has_element?(view, "#rule-target-key[value='volume-uid']")
    assert has_element?(view, "#rule-environment-scope option[value='one'][selected]")
    assert has_element?(view, "#rule-target-options option[value='volume-uid']", "Shared volume")

    view
    |> form("#configuration-rule-form", scope: %{environment: "all", target: "all"})
    |> render_change()

    refute has_element?(view, "#rule-environment")
    refute has_element?(view, "#rule-target-key")
    view |> form("#configuration-rule-form", params: %{limit: "60"}) |> render_submit()
    assert has_element?(view, "#rule-preview-summary", "1 checks reviewed")
  end

  test "incompatible schema preview preserves the current field meaning and blocks save" do
    incompatible =
      put_in(
        check("Other units"),
        ["parameter_schema", "fields", "limit", "label"],
        "Duration seconds"
      )
      |> put_in(["parameter_schema", "fields", "limit", "unit"], "seconds")

    [first, other] = publish([check("Disk alpha"), incompatible])

    {:ok, view, _} =
      live(build_conn(), "/configuration/rules/new?group=1&check_id=" <> first["id"])

    view |> form("#configuration-rule-form", params: %{limit: "65"}) |> render_submit()

    assert has_element?(
             view,
             "#rule-preview-#{other["id"]} td[headers='rule-review-current']",
             "Duration seconds"
           )

    assert has_element?(
             view,
             "#rule-preview-#{other["id"]} td[headers='rule-review-current'] dt",
             "(seconds)"
           )

    assert has_element?(view, "#rule-preview-summary", "1 conflicts")
    assert has_element?(view, "#rule-save[disabled]")
  end

  test "future-only exact scope requires IDs and remains valid without current matches" do
    [check] = publish([check("Disk alpha")])

    {:ok, view, _} =
      live(build_conn(), "/configuration/rules/new?group=1&check_id=" <> check["id"])

    view
    |> form("#configuration-rule-form", scope: %{environment: "one", target: "one"})
    |> render_change()

    view |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(view, "#rule-error", "Choose or enter one monitored environment")

    view
    |> form("#configuration-rule-form",
      rule: %{environment: "future-env", target_kind: "volume", target_key: "future-volume"}
    )
    |> render_submit()

    assert has_element?(view, "#rule-preview-summary", "0 checks reviewed")
    assert has_element?(view, "#rule-save:not([disabled])")
  end

  test "recovery restores exact scope and keeps operator draft rather than reseeding all" do
    [check] = publish([check("Disk alpha")])
    path = "/configuration/rules/new?group=1&check_id=" <> check["id"]
    {:ok, view, _} = live(build_conn(), path)

    view
    |> form("#configuration-rule-form", scope: %{environment: "one", target: "one"})
    |> render_change()

    view
    |> form("#configuration-rule-form",
      rule: %{environment: "future-env", target_kind: "volume", target_key: "future-volume"},
      params: %{limit: "55"}
    )
    |> render_change()

    proposal =
      view
      |> element("input[name='_proposal']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    {:ok, recovered, _} = live(build_conn(), path)
    render_hook(recovered, "recover", %{"_proposal" => proposal})
    assert has_element?(recovered, "#rule-environment[value='future-env']")
    assert has_element?(recovered, "#rule-target-key[value='future-volume']")
    recovered |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(recovered, "#rule-preview-summary", "0 checks reviewed")
  end

  test "recovery keeps explicit one-scope intent even before required identities are entered" do
    [check] = publish([check("Disk alpha")])
    path = "/configuration/rules/new?group=1&check_id=" <> check["id"]
    {:ok, view, _} = live(build_conn(), path)

    proposal =
      view
      |> element("input[name='_proposal']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    render_hook(view, "recover", %{
      "_proposal" => proposal,
      "_environment_scope" => "one",
      "_target_scope" => "one"
    })

    assert has_element?(view, "#rule-environment")
    assert has_element?(view, "#rule-target-key")
    view |> form("#configuration-rule-form") |> render_submit()
    assert has_element?(view, "#rule-error", "Choose or enter one monitored environment")
    refute has_element?(view, "#rule-save")
  end

  test "saved change follows its exact versions through reconnect and later supersession" do
    [check] = publish([check("Disk alpha")])

    {:ok, view, _} =
      live(build_conn(), "/configuration/rules/new?group=1&check_id=" <> check["id"])

    view |> form("#configuration-rule-form", params: %{limit: "65"}) |> render_submit()
    view |> form("#configuration-rule-form") |> render_submit()
    path = assert_patch(view)
    assert has_element?(view, "#rule-saved-change-summary", "1 waiting for runner")

    receipt =
      view
      |> element("input[name='_saved_change']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    {:ok, recovered, _} = live(build_conn(), path)
    refute has_element?(recovered, "#rule-saved-change")
    render_hook(recovered, "recover_saved", %{"_saved_change" => receipt})
    assert has_element?(recovered, "#rule-saved-change-summary", "1 waiting for runner")
    row = Repo.get!(Assignment, check["id"])

    Repo.update_all(from(a in Assignment, where: a.id == ^row.id),
      set: [
        prepared_generation: row.desired_generation,
        active_generation: row.desired_generation,
        observed_generation: row.desired_generation
      ]
    )

    send(recovered.pid, :tick)
    assert has_element?(recovered, "#rule-saved-change-summary", "1 measured")
    {:ok, other, _} = live(build_conn(), path)
    other |> form("#configuration-rule-form", params: %{limit: "55"}) |> render_submit()
    other |> form("#configuration-rule-form") |> render_submit()
    assert_patch(other)
    send(recovered.pid, :tick)
    assert has_element?(recovered, "#rule-saved-change-summary", "1 superseded")
    assert has_element?(recovered, "#rule-saved-change .badge", "Rule revision 1")
    refute has_element?(recovered, "#rule-saved-change-summary", "measured")
    render_patch(recovered, "/configuration/rules")
    refute has_element?(recovered, "#rule-saved-change")
  end

  test "future-only rule save has no invented adoption version" do
    [check] = publish([check("Disk alpha")])
    {:ok, view, _} = live(build_conn(), "/configuration/rules/new?check_id=" <> check["id"])

    view
    |> form("#configuration-rule-form", rule: %{target_key: "future-volume"})
    |> render_submit()

    view |> form("#configuration-rule-form") |> render_submit()
    assert_patch(view)
    assert has_element?(view, "#rule-saved-change", "No check received a new desired version")
    refute has_element?(view, "#rule-saved-change-summary")
  end

  defp publish(checks) do
    inventory =
      control()
      |> Map.merge(%{
        "runner_label" => "Disk observer",
        "source_id" => "group.flow",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => checks
      })

    assert {:ok, _} = Inventory.reconcile(inventory, at())

    Repo.all(from a in Assignment, where: a.source_id == "group.flow", order_by: a.source_key)
    |> Enum.map(&Monitoring.public/1)
  end

  defp check(key) do
    %{
      "key" => String.replace(key, " ", "-"),
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
