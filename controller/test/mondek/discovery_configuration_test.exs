# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DiscoveryConfigurationTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint

  alias Mondek.{ConfigurationRules, DiscoveryConfiguration, Inventory, DiscoveryChange}

  test "typed ownership is scoped to one source/observer and malformed relationships reject atomically" do
    p = inventory()
    assert Inventory.validate(p) == :ok
    assert {:ok, _} = Monitoring.inventory(p, at())
    resource = assignment(p, "eth0")
    assert DiscoveryConfiguration.context(resource.id).manager["source_key"] == "manager"

    for bad <- [
          put_in(p, ["checks", Access.at(1), "discovery", "manager_key"], "missing"),
          put_in(p, ["checks", Access.at(1), "environment"], "elsewhere"),
          put_in(p, ["checks", Access.at(1), "discovery", "origin"], "guessed")
        ] do
      assert {:error, {:invalid, _}} =
               Monitoring.inventory(Map.put(bad, "inventory_revision", 2), at())

      assert Repo.get!(Assignment, resource.id).retired_at == nil
    end

    old = Map.update!(p, "checks", &Enum.map(&1, fn c -> Map.delete(c, "discovery") end))
    assert Inventory.validate(old) == :ok
    assert {:ok, _} = Monitoring.inventory(Map.put(old, "inventory_revision", 2), at())
    assert DiscoveryConfiguration.context(resource.id) == nil
  end

  test "retirement receipt requires accepted inventory under the saved generation, independently of measurements" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    context = DiscoveryConfiguration.context(child.id)
    params = %{"interface_exclude" => "lo,eth0"}

    assert {:ok, preview} =
             ConfigurationRules.preview_instance(
               context.manager["id"],
               context.manager["revision"],
               params
             )

    assert {:ok, change} = DiscoveryConfiguration.save(context, "local", preview)
    manager = assignment(p, "manager")

    assert DiscoveryConfiguration.receipt(change.id).members |> hd() |> Map.get(:status) ==
             "activation_pending"

    selection = %{
      "status" => "failed",
      "params" => params,
      "assignment_id" => manager.id,
      "generation" => manager.desired_generation
    }

    failed =
      Map.merge(p, %{"inventory_revision" => 2, "catalog_selections" => %{"manager" => selection}})

    assert {:ok, _} = Monitoring.inventory(failed, DateTime.add(at(), 1))
    assert hd(DiscoveryConfiguration.receipt(change.id).members).status == "refresh_failed"
    assert Repo.get!(Assignment, child.id).retired_at == nil

    accepted =
      failed
      |> Map.put("inventory_revision", 3)
      |> Map.update!("checks", &Enum.take(&1, 1))
      |> put_in(["catalog_selections", "manager", "status"], "accepted")

    assert {:ok, _} = Monitoring.inventory(accepted, DateTime.add(at(), 2))
    receipt = hd(DiscoveryConfiguration.receipt(change.id).members)
    assert receipt.status == "inventory_accepted"
    assert receipt.receipt["resource_present"] == false
    assert receipt.assignment["observed_generation"] == nil
    assert Repo.get!(Assignment, child.id).retired_at
    assert Repo.get!(DiscoveryChange, change.id).pending == false

    assert {:ok, _} =
             Monitoring.save_assignment(manager.id, manager.revision, %{
               "interface_exclude" => "lo"
             })

    assert hd(DiscoveryConfiguration.receipt(change.id).members).status == "inventory_accepted"
  end

  test "host policy covers two observers of one host, preserves masks and excludes a second host" do
    p = inventory()

    second =
      Map.merge(p, %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "runner_label" => "Second observer"
      })

    other =
      Map.merge(p, %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate()
      })
      |> put_in(["checks", Access.at(0), "outputs", Access.at(0), "target", "key"], "other-host")

    for payload <- [p, second, other], do: assert({:ok, _} = Monitoring.inventory(payload, at()))
    manager = assignment(p, "manager")

    assert {:ok, _} =
             Monitoring.save_assignment(manager.id, manager.revision, %{
               "interface_exclude" => "lo,veth*"
             })

    context = DiscoveryConfiguration.context(assignment(p, "eth0").id)
    assert DiscoveryConfiguration.observer_count(context.manager) == 2
    params = %{"interface_exclude" => "lo,eth0"}
    assert {:ok, proposal} = DiscoveryConfiguration.host_proposal(context.manager, params)
    assert {:ok, preview} = ConfigurationRules.preview(proposal)
    assert preview["counts"]["matched"] == 2
    assert preview["counts"]["exceptions"] == 1
    assert {:ok, change} = DiscoveryConfiguration.save(context, "host", preview, proposal)
    assert Enum.any?(DiscoveryConfiguration.receipt(change.id).members, &(&1.status == "masked"))
    assert assignment(other, "manager").params == %{"interface_exclude" => "lo"}
    manager = assignment(p, "manager")
    assert {:ok, reset} = ConfigurationRules.preview_reset(manager.id, manager.revision)
    assert {:ok, _} = ConfigurationRules.reset_exception(reset["review_token"])

    for payload <- [p, second] do
      manager = assignment(payload, "manager")

      selected = %{
        "status" => "accepted",
        "params" => params,
        "assignment_id" => manager.id,
        "generation" => manager.desired_generation
      }

      refreshed =
        payload
        |> Map.put("inventory_revision", 2)
        |> Map.update!("checks", &Enum.take(&1, 1))
        |> Map.put("catalog_selections", %{"manager" => selected})

      assert {:ok, _} = Monitoring.inventory(refreshed, DateTime.add(at(), 1))
    end

    assert Enum.all?(
             DiscoveryConfiguration.receipt(change.id).members,
             &(&1.status == "inventory_accepted")
           )

    assert assignment(other, "eth0").retired_at == nil
  end

  test "the real resource entry leads to subject-first scope, review and a durable receipt" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    stream = Repo.get_by!(Mondek.ResultStream, assignment_id: child.id)

    for suffix <- ["", "/full"] do
      {:ok, result, _} = live(build_conn(), "/results/" <> stream.id <> suffix)
      surface = if suffix == "", do: "#overview-panel", else: "#preview-result-page"

      assert has_element?(
               result,
               surface <> " #resource-discovery-settings",
               "Automatically discovered"
             )

      assert has_element?(
               result,
               surface <> " #resource-discovery-settings a",
               "Configure resource discovery"
             )

      navigation =
        result |> element(surface <> " #resource-discovery-settings a") |> render_click()

      {:ok, settings, _} = follow_redirect(navigation, build_conn())
      assert has_element?(settings, "#discovery-config-subject", "node-a.example")
      assert has_element?(settings, "#discovery-config-form")
    end

    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)
    assert has_element?(view, "#discovery-config-subject", "node-a.example")
    assert has_element?(view, "#discovery-scope-local[checked]")
    assert has_element?(view, "small", "1 current observer")
    view |> element("#toggle-discovered-resource") |> render_click()
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    view |> form("#discovery-config-form") |> render_submit()
    assert has_element?(view, "#discovery-config-review", "Changed")
    assert assignment(p, "manager").params == %{"interface_exclude" => "lo"}

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#save-discovery-change") |> render_click()

    {:ok, receipt, _} = live(build_conn(), path)
    assert has_element?(receipt, "#discovery-change-receipt", "Waiting for runner activation")
    {:ok, reloaded, _} = live(build_conn(), path)
    assert has_element?(reloaded, "#discovery-change-receipt", "Waiting for runner activation")
  end

  test "a higher-priority broad rule cannot masquerade as an effective host policy" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    context = DiscoveryConfiguration.context(assignment(p, "eth0").id)
    assert {:ok, seed} = ConfigurationRules.seed(context.manager["id"])

    broad =
      Map.merge(seed, %{
        "name" => "Broad high policy",
        "priority" => 10,
        "target_key" => nil,
        "target_kind" => nil
      })

    assert {:ok, preview} = ConfigurationRules.preview(broad)
    assert {:ok, _} = ConfigurationRules.apply(preview["review_token"], broad)
    context = DiscoveryConfiguration.context(assignment(p, "eth0").id)

    assert {:ok, proposal} =
             DiscoveryConfiguration.host_proposal(context.manager, %{
               "interface_exclude" => "lo,eth0"
             })

    assert {:ok, reviewed} = ConfigurationRules.preview(proposal)
    assert DiscoveryConfiguration.host_shadowed?(reviewed, proposal)

    assert {:error, {:conflict, _}} =
             DiscoveryConfiguration.save(context, "host", reviewed, proposal)

    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "exact exclusion cannot trim a valid filesystem name into another resource" do
    p = filesystem_inventory([{"plain", "/data"}, {"space", "/data "}])
    assert {:ok, _} = Monitoring.inventory(p, at())
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> assignment(p, "space").id)
    refute has_element?(view, "#toggle-discovered-resource")
    # Hidden controls are not a server-side guard: a direct event must also refuse.
    render_hook(view, "toggle_resource", %{})
    assert has_element?(view, "#discovery-config-error", "cannot be represented")
    assert has_element?(view, "#discovery-param-filesystem_exclude[value='']")
    assert assignment(p, "manager").params["filesystem_exclude"] == ""
    assert Repo.aggregate(DiscoveryChange, :count) == 0

    {:ok, plain, _} = live(build_conn(), "/configuration/discovery/" <> assignment(p, "plain").id)
    plain |> element("#toggle-discovered-resource") |> render_click()
    assert has_element?(plain, "#discovery-param-filesystem_exclude[value='/data']")
  end

  test "exact exclusion preserves glob metacharacters with combining marks" do
    cases =
      __DIR__
      |> Path.join("../../../tests/fixtures/exact_glob_patterns.json")
      |> File.read!()
      |> Jason.decode!()

    for entry <- cases do
      p =
        filesystem_inventory([{"exact", entry["name"]}, {"other", entry["other"]}])
        |> Map.merge(%{
          "installation_id" => Ecto.UUID.generate(),
          "session_id" => Ecto.UUID.generate()
        })

      assert {:ok, _} = Monitoring.inventory(p, at())
      other = assignment(p, "other")

      {:ok, view, _} =
        live(build_conn(), "/configuration/discovery/" <> assignment(p, "exact").id)

      view |> element("#toggle-discovered-resource") |> render_click()

      assert has_element?(
               view,
               "#discovery-param-filesystem_exclude[value='#{entry["pattern"]}']"
             )

      view |> form("#discovery-config-form") |> render_submit()

      assert {:error, {:live_redirect, %{to: _}}} =
               view |> element("#save-discovery-change") |> render_click()

      assert assignment(p, "manager").params["filesystem_exclude"] == entry["pattern"]
      assert Repo.get!(Assignment, other.id).retired_at == nil
    end
  end

  test "settings preserve reviewed scope and values through result links and presentation switches" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)
    view |> element("#toggle-discovered-resource") |> render_click()
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    view |> element("#discovery-config-current-result") |> render_click()

    assert has_element?(
             view,
             "#overview-panel #resource-discovery-settings a[data-phx-link='patch']"
           )

    view |> element("#overview-panel #resource-discovery-settings a") |> render_click()
    refute has_element?(view, "#overview-panel")
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    view |> form("#discovery-config-form") |> render_submit()
    assert has_element?(view, "#discovery-config-review", "lo,eth0")

    assert has_element?(
             view,
             "#discovery-config-editor[hidden] #discovery-config-form[phx-auto-recover='recover']"
           )

    view |> element("#discovery-config-current-result") |> render_click()
    assert has_element?(view, "#discovery-config-workflow[inert]")
    view |> element("#overview-panel [data-overview-close]") |> render_click()
    refute has_element?(view, "#overview-panel")
    assert has_element?(view, "#discovery-config-review", "lo,eth0")
    view |> element("#discovery-config-current-result") |> render_click()

    render_hook(view, "save", %{})
    render_hook(view, "reload", %{})
    render_hook(view, "edit", %{"params" => %{"interface_exclude" => "lo,forged*"}})
    assert has_element?(view, "#discovery-config-review", "lo,eth0")
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
    view |> element("#overview-panel a", "Open as page") |> render_click()
    assert has_element?(view, "#discovery-config-workflow[hidden][inert]")
    assert has_element?(view, "#discovery-config-shell[data-panel-heading='full-result-heading']")
    render_hook(view, "save", %{})
    assert Repo.aggregate(DiscoveryChange, :count) == 0
    view |> element("#preview-result-page a", "Open fly-over") |> render_click()
    view |> element("#overview-panel #resource-discovery-settings a") |> render_click()
    send(view.pid, :tick)
    assert has_element?(view, "#save-discovery-change")
    assert has_element?(view, "#discovery-config-review", "lo,eth0")

    assert {:error, {:live_redirect, %{to: receipt_path}}} =
             view |> element("#save-discovery-change") |> render_click()

    assert Repo.aggregate(DiscoveryChange, :count) == 1
    {:ok, receipt, _} = live(build_conn(), receipt_path)

    assert has_element?(
             receipt,
             "table[aria-label='Saved discovery change']",
             "One discovery check"
           )

    assert has_element?(
             receipt,
             "table[aria-label='Observer discovery outcome']",
             "Reviewed generation"
           )

    assert has_element?(receipt, "#discovery-change-receipt", "Waiting for runner activation")

    receipt
    |> element("#discovery-receipt-result-" <> assignment(p, "manager").id)
    |> render_click()

    assert has_element?(receipt, "#overview-panel")
  end

  test "remote changes keep frozen review facts and reject stale save after investigation" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    manager = assignment(p, "manager")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)
    view |> element("#toggle-discovered-resource") |> render_click()
    view |> form("#discovery-config-form") |> render_submit()

    assert {:ok, _} =
             Monitoring.save_assignment(manager.id, manager.revision, %{
               "interface_exclude" => "lo,remote*"
             })

    send(view.pid, :tick)

    values =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("table[aria-label='Reviewed discovery values'] tbody td")
      |> LazyHTML.text()

    assert values =~ "lo,eth0"
    refute values =~ "remote"
    view |> element("#discovery-config-current-result") |> render_click()
    render_hook(view, "reload", %{})
    view |> element("#overview-panel #resource-discovery-settings a") |> render_click()
    view |> element("#save-discovery-change") |> render_click()
    assert has_element?(view, "#discovery-config-error", "changed after review")
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    assert assignment(p, "manager").params == %{"interface_exclude" => "lo,remote*"}
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "recovery retains captured values and revision but requires a new review" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    manager = assignment(p, "manager")

    assert {:ok, _} =
             Monitoring.save_assignment(manager.id, manager.revision, %{
               "interface_exclude" => "lo,current*"
             })

    {:ok, recovered, _} = live(build_conn(), "/configuration/discovery/" <> child.id)

    render_hook(recovered, "recover", %{
      "_manager_id" => manager.id,
      "_revision" => to_string(manager.revision),
      "scope" => "host",
      "params" => %{"interface_exclude" => "lo,old-draft*"}
    })

    assert has_element?(recovered, "#discovery-param-interface_exclude[value='lo,old-draft*']")
    assert has_element?(recovered, "#discovery-scope-host[checked]")
    refute has_element?(recovered, "#save-discovery-change")
    recovered |> form("#discovery-config-form") |> render_submit()
    assert has_element?(recovered, "#discovery-config-error", "review again")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
    refute assignment(p, "manager").params == %{"interface_exclude" => "lo,old-draft*"}

    render_hook(recovered, "recover", %{
      "_manager_id" => %{"bad" => "shape"},
      "_revision" => %{},
      "params" => %{"interface_exclude" => "lo,malformed*"}
    })

    recovered |> form("#discovery-config-form") |> render_submit()
    assert has_element?(recovered, "#discovery-config-error", "review again")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "unknown settings and receipts are useful unavailable views and reject crafted actions" do
    unknown = Ecto.UUID.generate()
    {:ok, settings, _} = live(build_conn(), "/configuration/discovery/" <> unknown)

    assert has_element?(
             settings,
             "#discovery-config-workflow",
             "Discovery relationship unavailable"
           )

    render_hook(settings, "review", %{"params" => %{}})
    assert has_element?(settings, "#discovery-config-error", "unavailable")
    render_hook(settings, "reload", %{})
    refute has_element?(settings, "#discovery-config-form")
    {:ok, receipt, _} = live(build_conn(), "/configuration/discovery/changes/" <> unknown)
    assert has_element?(receipt, "#discovery-config-workflow", "receipt is not available")
    render_hook(receipt, "save", %{})
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "saved host-policy receipts retain masked observers and independent inventory evidence" do
    p = inventory()

    other =
      Map.merge(p, %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "runner_label" => "Second observer"
      })

    for payload <- [p, other], do: assert({:ok, _} = Monitoring.inventory(payload, at()))
    manager = assignment(p, "manager")

    assert {:ok, _} =
             Monitoring.save_assignment(manager.id, manager.revision, %{
               "interface_exclude" => "lo,local*"
             })

    child = assignment(p, "eth0")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)

    view
    |> form("#discovery-config-form", scope: "host", params: %{"interface_exclude" => "lo,eth0"})
    |> render_submit()

    assert has_element?(
             view,
             "table[aria-label='Checks reviewed for host policy']",
             "Local override remains in force"
           )

    assert {:error, {:live_redirect, %{to: receipt_path}}} =
             view |> element("#save-discovery-change") |> render_click()

    {:ok, receipt, _} = live(build_conn(), receipt_path)

    assert has_element?(
             receipt,
             "#discovery-change-receipt",
             "Local override blocks this host policy"
           )

    assert has_element?(receipt, ".pf-v6-c-label.pf-m-orange", "Local override")
    assert has_element?(receipt, "#discovery-change-receipt a", "Review local override removal")
    refute has_element?(receipt, "#discovery-change-receipt", "Successful inventory accepted")
  end

  test "review keeps a rendered recovery form with exact scope values and captured revision" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    manager = assignment(p, "manager")
    path = "/configuration/discovery/" <> child.id
    {:ok, view, _} = live(build_conn(), path)

    view
    |> form("#discovery-config-form", scope: "host", params: %{"interface_exclude" => "lo,eth0"})
    |> render_submit()

    assert has_element?(
             view,
             "#discovery-config-editor[hidden][inert] #discovery-config-form[phx-auto-recover='recover']"
           )

    recovered_form = rendered_draft(view)
    assert recovered_form["scope"] == "host"
    assert recovered_form["params"]["interface_exclude"] == "lo,eth0"
    assert recovered_form["_revision"] == to_string(manager.revision)
    {:ok, reconnected, _} = live(build_conn(), path)
    render_hook(reconnected, "recover", recovered_form)
    assert has_element?(reconnected, "#discovery-scope-host[checked]")
    assert has_element?(reconnected, "#discovery-param-interface_exclude[value='lo,eth0']")
    refute has_element?(reconnected, "#save-discovery-change")
    refute has_element?(reconnected, "#discovery-config-editor[hidden]")
    assert assignment(p, "manager").params == %{"interface_exclude" => "lo"}
    reconnected |> form("#discovery-config-form") |> render_submit()

    assert {:error, {:live_redirect, _}} =
             reconnected |> element("#save-discovery-change") |> render_click()
  end

  test "scope changes accept LiveView unused-input metadata and retain the reviewed host policy" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    manager = assignment(p, "manager")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)

    render_change(view, "edit", %{
      "_manager_id" => manager.id,
      "_revision" => to_string(manager.revision),
      "scope" => "host",
      "params" => %{"interface_exclude" => "lo", "_unused_interface_exclude" => ""},
      "_target" => ["scope"]
    })

    assert has_element?(view, "#discovery-scope-host[checked]")
    refute has_element?(view, "#discovery-config-error")
    view |> element("#toggle-discovered-resource") |> render_click()
    assert has_element?(view, "#discovery-scope-host[checked]")
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    view |> form("#discovery-config-form") |> render_submit()

    assert has_element?(
             view,
             "#discovery-config-review",
             "Current and future compatible observers"
           )

    assert has_element?(view, "#save-discovery-change")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "malformed review recovery and edits retain the last safe draft without terminating" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)
    view |> element("#toggle-discovered-resource") |> render_click()

    for event <- ["edit", "recover", "review"],
        bad <- [
          %{"params" => "not-a-map"},
          %{"params" => %{"interface_exclude" => true}},
          %{"params" => %{"interface_exclude" => 42}},
          %{"params" => %{"unknown" => "value"}},
          %{"params" => %{"_unused_unknown" => ""}},
          %{"params" => %{"_unused_interface_exclude" => "not-metadata"}},
          %{"params" => %{"interface_exclude" => %{"nested" => "map"}}},
          %{"_revision" => %{}, "params" => %{"interface_exclude" => "lo,bad"}},
          %{"_manager_id" => %{}, "params" => %{"interface_exclude" => "lo,bad"}}
        ] do
      render_hook(view, event, bad)
      assert Process.alive?(view.pid)
      assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
      assert has_element?(view, "#discovery-config-error", "could not be recovered")
      refute has_element?(view, "#save-discovery-change")
    end

    view |> element("#toggle-discovered-resource") |> render_click()
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo']")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "source schema and relationship changes invalidate the captured discovery review" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)
    view |> element("#toggle-discovered-resource") |> render_click()
    view |> form("#discovery-config-form") |> render_submit()

    revised =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(
        ["checks", Access.at(0), "parameter_schema", "fields", "interface_exclude", "max_length"],
        2047
      )

    assert {:ok, _} = Monitoring.inventory(revised, DateTime.add(at(), 1))
    send(view.pid, :tick)

    assert has_element?(
             view,
             "#discovery-param-interface_exclude[maxlength='2048'][value='lo,eth0']"
           )

    view |> element("#save-discovery-change") |> render_click()
    assert has_element?(view, "#discovery-config-error", "changed after review")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
    view |> element("button", "Reload current values") |> render_click()
    view |> element("#toggle-discovered-resource") |> render_click()
    view |> form("#discovery-config-form") |> render_submit()

    removed =
      revised
      |> Map.put("inventory_revision", 3)
      |> Map.update!("checks", fn checks ->
        Enum.map(checks, fn check ->
          if check["key"] == "eth0", do: Map.delete(check, "discovery"), else: check
        end)
      end)

    assert {:ok, _} = Monitoring.inventory(removed, DateTime.add(at(), 2))
    send(view.pid, :tick)
    render_hook(view, "save", %{})
    assert has_element?(view, "#discovery-config-error", "relationship changed")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
  end

  test "a new matching observer after host review requires a new review before save" do
    p = inventory()
    assert {:ok, _} = Monitoring.inventory(p, at())
    child = assignment(p, "eth0")
    {:ok, view, _} = live(build_conn(), "/configuration/discovery/" <> child.id)

    view
    |> form("#discovery-config-form", scope: "host", params: %{"interface_exclude" => "lo,eth0"})
    |> render_submit()

    second =
      Map.merge(p, %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "runner_label" => "Late observer"
      })

    assert {:ok, _} = Monitoring.inventory(second, DateTime.add(at(), 1))
    view |> element("#save-discovery-change") |> render_click()
    assert has_element?(view, "#discovery-config-error", "changed after review")
    assert has_element?(view, "#discovery-scope-host[checked]")
    assert has_element?(view, "#discovery-param-interface_exclude[value='lo,eth0']")
    assert Repo.aggregate(DiscoveryChange, :count) == 0
    assert assignment(second, "manager").params == %{"interface_exclude" => "lo"}
  end

  defp rendered_draft(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#discovery-config-form input")
    |> Enum.filter(fn input ->
      type = LazyHTML.attribute(input, "type") |> List.first()
      type not in ["radio", "checkbox"] || LazyHTML.attribute(input, "checked") != []
    end)
    |> Enum.map(fn input ->
      {hd(LazyHTML.attribute(input, "name")),
       List.first(LazyHTML.attribute(input, "value")) || ""}
    end)
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
  end

  defp filesystem_inventory(names) do
    p = inventory()
    [manager, template] = p["checks"]

    schema =
      put_in(manager["parameter_schema"], ["fields", "filesystem_exclude"], %{
        "type" => "string",
        "max_length" => 2048
      })

    manager =
      manager
      |> Map.put("parameter_schema", schema)
      |> Map.update!("params", &Map.put(&1, "filesystem_exclude", ""))

    resources =
      for {key, name} <- names do
        template
        |> Map.put("key", key)
        |> Map.put("label", "Filesystem " <> name)
        |> Map.put("discovery", %{
          "version" => 1,
          "kind" => "resource",
          "manager_key" => "manager",
          "resource_kind" => "filesystem",
          "resource_name" => name,
          "origin" => "discovered"
        })
      end

    Map.put(p, "checks", [manager | resources])
  end

  defp assignment(p, key),
    do:
      Repo.get_by!(Assignment,
        runner_id: p["installation_id"],
        source_id: p["source_id"],
        source_key: key
      )

  defp inventory do
    schema = %{"fields" => %{"interface_exclude" => %{"type" => "string", "max_length" => 2048}}}

    base = %{
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "example-site",
      "params_owner" => "ui",
      "params" => %{"interface_exclude" => "lo"},
      "parameter_schema" => schema,
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => "health",
          "label" => "Host",
          "target" => %{"key" => "node-a.example", "kind" => "host", "label" => "node-a.example"}
        }
      ]
    }

    manager =
      Map.merge(base, %{
        "key" => "manager",
        "label" => "Linux resource discovery",
        "parameter_contract" => "mondek.linux.discovery.v1",
        "discovery" => %{
          "version" => 1,
          "kind" => "manager",
          "capability" => "linux.resources.v1"
        }
      })

    resource =
      Map.merge(base, %{
        "key" => "eth0",
        "label" => "Interface eth0",
        "discovery" => %{
          "version" => 1,
          "kind" => "resource",
          "manager_key" => "manager",
          "resource_kind" => "interface",
          "resource_name" => "eth0",
          "origin" => "discovered"
        }
      })

    control()
    |> Map.merge(%{
      "runner_label" => "Example observer",
      "source_id" => "linux",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => [manager, resource]
    })
  end
end
