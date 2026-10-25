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
    {:ok, result, _} = live(build_conn(), "/checks/" <> stream.id)
    assert has_element?(result, "#resource-discovery-settings", "Automatically discovered")
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
