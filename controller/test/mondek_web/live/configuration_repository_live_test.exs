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

  test "an unavailable token file is distinguished from disabled Git access" do
    previous = Application.get_env(:mondek, :configuration_git_token_file)
    on_exit(fn -> Application.put_env(:mondek, :configuration_git_token_file, previous) end)
    path = Path.join(System.tmp_dir!(), "private-token-location-" <> Ecto.UUID.generate())
    Application.put_env(:mondek, :configuration_git_token_file, path)

    {:ok, view, html} = live(build_conn(), "/configuration/history")
    assert has_element?(view, "#configuration-repository-git .badge", "Credential unavailable")
    assert has_element?(view, "#configuration-git-unavailable")
    refute has_element?(view, "#configuration-git-disabled")
    refute html =~ path
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
    assert has_element?(view, "#main-content #configuration-change-detail")
    assert has_element?(view, ".configuration-field-changes th", "warn_percent")
    assert has_element?(view, ".configuration-field-changes th", "crit_percent")
    assert has_element?(view, "#configuration-change-detail", "1 configuration document changed")

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

  test "recent history search and numbered pages retain an immutable selected revision" do
    row = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    for value <- 60..72 do
      current = Repo.get!(Assignment, row.id)

      assert {:ok, _} =
               Monitoring.save_assignment(
                 current.id,
                 current.revision,
                 Map.put(current.params, "warn_percent", value)
               )
    end

    {:ok, state} = Mondek.ConfigurationRepository.state()
    {:ok, view, _} = live(build_conn(), "/configuration/history")
    assert has_element?(view, "nav[aria-label='Recent configuration revisions']")
    view |> element("button[phx-value-head='#{state.head}']") |> render_click()
    selected_url = assert_patch(view)
    assert has_element?(view, "#configuration-change-detail", "72")
    view |> form("#overview-search", search: "no such revision") |> render_submit()
    assert has_element?(view, "#configuration-repository-history", "No recent changes match")
    assert has_element?(view, "#configuration-change-detail", state.head)
    current = Repo.get!(Assignment, row.id)

    assert {:ok, _} =
             Monitoring.save_assignment(
               current.id,
               current.revision,
               Map.put(current.params, "warn_percent", 73)
             )

    send(view.pid, :tick)
    assert has_element?(view, "#configuration-change-detail", "72")

    refute has_element?(
             view,
             "#configuration-change-detail .configuration-field-changes td",
             "73"
           )

    view |> form("#overview-search", search: "") |> render_submit()

    view
    |> element("nav[aria-label='Recent configuration revisions'] a[aria-label='Page 2']")
    |> render_click()

    assert has_element?(
             view,
             "nav[aria-label='Recent configuration revisions'] [aria-current=page]",
             "2"
           )

    assert has_element?(view, "#configuration-change-detail", state.head)
    {:ok, restored, _} = live(build_conn(), selected_url)
    assert has_element?(restored, "#configuration-change-detail", state.head)
    restored |> render_patch("/configuration/history?change=" <> String.duplicate("f", 40))
    assert has_element?(restored, "#configuration-change-missing", "could not be found")
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

    assert has_element?(view, "nav[aria-label='Changed documents'] [aria-current=page]", "1")
    view |> element("button[phx-value-page='2'][aria-label='Page 2']") |> render_click()
    assert has_element?(view, "nav[aria-label='Changed documents'] [aria-current=page]", "2")

    assert has_element?(
             view,
             "nav[aria-label='Changed documents'] span[aria-disabled=true]",
             "Next"
           )
  end

  test "malformed revision selections are ignored without losing the history list" do
    for query <- ["change[x]=y", "change[]=x", "change=" <> String.duplicate("a", 1000)] do
      {:ok, view, _} = live(build_conn(), "/configuration/history?" <> query)
      assert has_element?(view, "#configuration-repository-state")
      refute has_element?(view, "#configuration-change-detail")
      send(view.pid, :tick)
      assert render(view) =~ "Configuration history"
      GenServer.stop(view.pid)
    end
  end
end
