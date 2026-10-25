# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationRepositoryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MondekWeb.Endpoint

  test "history explains automatic persistence, adoption and installation-specific scope" do
    {:ok, view, _} = live(build_conn(), "/configuration/history")
    assert has_element?(view, "h1", "Configuration history")
    assert has_element?(view, "#configuration-repository-state", "Runners must still prepare")
    assert has_element?(view, "#configuration-repository-scope", "explicit review and mapping")
    assert has_element?(view, "#configuration-repository-git", "Only main accepts pushes")

    assert has_element?(
             view,
             "#configuration-git-prompt-text",
             "Do not push until I explicitly authorize"
           )

    refute has_element?(view, ".form-error")
    send(view.pid, :tick)
    assert has_element?(view, "#configuration-repository-state")
  end

  test "Git endpoint state never reveals the configured credential" do
    original = Application.get_env(:mondek, :configuration_git_token)
    on_exit(fn -> Application.put_env(:mondek, :configuration_git_token, original) end)
    Application.delete_env(:mondek, :configuration_git_token)
    {:ok, disabled, _} = live(build_conn(), "/configuration/history")
    assert has_element?(disabled, "#configuration-git-disabled")
    token = String.duplicate("private-token", 4)
    Application.put_env(:mondek, :configuration_git_token, token)
    {:ok, enabled, html} = live(build_conn(), "/configuration/history")
    refute has_element?(enabled, "#configuration-git-disabled")
    assert has_element?(enabled, "#configuration-repository-git .badge", "Enabled")
    refute html =~ token
  end

  test "configuration inventory and rules link to history" do
    {:ok, inventory, _} = live(build_conn(), "/configuration")
    assert has_element?(inventory, "a[href='/configuration/history']")
    {:ok, rules, _} = live(build_conn(), "/configuration/rules")
    assert has_element?(rules, "a[href='/configuration/history']")
  end

  test "history identifies changed settings and exposes immutable before and after evidence" do
    row = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert {:ok, _} =
             Monitoring.save_assignment(
               row.id,
               row.revision,
               Map.put(row.params, "warn_percent", 75)
             )

    {:ok, state} = Mondek.ConfigurationRepository.state()
    {:ok, view, _} = live(build_conn(), "/configuration/history")

    assert has_element?(
             view,
             "#configuration-repository-history",
             "1 configuration document changed"
           )

    view |> element("button[phx-value-head='#{state.head}']") |> render_click()

    assert has_element?(
             view,
             "#configuration-change-detail",
             "Added · exceptions/10000000-0000-4000-8000-000000000001.json"
           )

    assert has_element?(view, "#configuration-change-detail h4", "Before")
    assert has_element?(view, "#configuration-change-detail h4", "After")
    assert has_element?(view, "#configuration-repository-history li #configuration-change-detail")
    assert has_element?(view, ".configuration-field-changes dt", "warn_percent")
    assert has_element?(view, ".configuration-field-changes dt", "crit_percent")
    assert has_element?(view, "#configuration-change-detail", "1 configuration document changed.")

    assert has_element?(
             view,
             "#configuration-change-detail details summary",
             "Complete documents and scope"
           )

    html = render(view)
    assert html =~ "75"
    assert html =~ "90"
    view |> element("button[phx-click='close-change']") |> render_click()
    refute has_element?(view, "#configuration-change-detail")
  end

  test "large changes have bounded document pages with all evidence reachable" do
    assert {:ok, _} =
             Mondek.ConfigurationRepository.transaction("test", fn ->
               for i <- 1..12 do
                 {:ok, row} =
                   create_source_fixture(
                     "filesystem",
                     "Filesystem #{i}",
                     %{
                       "path" => "/#{i}",
                       "warn_percent" => 80,
                       "crit_percent" => 90
                     }
                   )

                 Monitoring.save_assignment(
                   row["id"],
                   row["revision"],
                   Map.put(row["params"], "warn_percent", 75)
                 )
               end
             end)

    {:ok, state} = Mondek.ConfigurationRepository.state()
    {:ok, view, _} = live(build_conn(), "/configuration/history")
    view |> element("button[phx-value-head='#{state.head}']") |> render_click()

    assert has_element?(
             view,
             "#configuration-change-detail",
             "12 configuration documents changed"
           )

    assert has_element?(view, "nav[aria-label='Changed documents']", "Page 1 of 2")
    view |> element("button[phx-value-page='2']") |> render_click()
    assert has_element?(view, "nav[aria-label='Changed documents']", "Page 2 of 2")
    assert has_element?(view, "button[phx-value-page='3'][disabled]")
  end
end
