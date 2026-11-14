# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GuideLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint MondekWeb.Endpoint

  test "setup keeps the code-first sequence and useful installed-project commands" do
    {:ok, view, _} = live(build_conn(), "/guide")
    assert has_element?(view, "#setup-heading", "Set up a runner")
    assert has_element?(view, "#setup-project h2", "1. Create your monitoring project")
    assert has_element?(view, "#setup-runner h2", "2. Validate and start the runner")
    assert has_element?(view, "#setup-verify h2", "3. Confirm collection")

    assert has_element?(
             view,
             "#project-starter-example",
             "uv tool install 'mondek==<SDK_VERSION>'"
           )

    assert has_element?(view, "#project-starter-example", "mondek-runner init my-monitoring")
    assert has_element?(view, ".setup-sdk-note", "matching local SDK wheel")
    assert has_element?(view, "#runner-launch-example", "--controller 'http://www.example.com'")
    assert has_element?(view, "#runner-launch-example", "--state-dir .mondek-state")
    assert has_element?(view, "#consumer-example", "source_id=\"application-checks\"")
    assert has_element?(view, "#setup-verify a[href='/runners']", "Runners")
    assert has_element?(view, "#setup-verify a[href='/checks']", "Browse results")
    assert has_element?(view, "#setup-verify", "Contact alone does not prove collection")
    assert has_element?(view, "#setup-placement", "source")
    refute has_element?(view, "button", "Create check")
  end

  test "setup prompts retain review, copy and manual selection controls" do
    {:ok, view, _} = live(build_conn(), "/guide?ignored=secret-value")
    assert has_element?(view, "#runner-agent-prompts-project[phx-hook='CopyPrompt']")

    assert has_element?(
             view,
             "#runner-agent-prompts-project-text[readonly]",
             "UNTRUSTED UI CONTEXT"
           )

    assert has_element?(view, "#runner-agent-prompts-project-copy", "Copy prompt")
    assert has_element?(view, "#runner-agent-prompts-project-select", "Select text")
    assert has_element?(view, "#runner-agent-prompts-retirement-text", "source-removal reason")
    refute render(view) =~ "secret-value"
  end

  test "setup and credits share the operator session across the legacy layout boundary" do
    session_name = fn path ->
      %{phoenix_live_view: {_, _, _, %{name: name}}} =
        Phoenix.Router.route_info(MondekWeb.Router, "GET", path, "www.example.com")

      name
    end

    assert session_name.("/guide") == :operator_ui
    assert session_name.("/licenses") == :operator_ui
    refute session_name.("/runners") == :operator_ui
  end
end
