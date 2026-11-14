# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GuideLive do
  use MondekWeb, :live_view
  alias MondekWeb.{AgentPrompts, PreviewDetail, PreviewLayouts}
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Set up a runner", controller_url: MondekWeb.Endpoint.url())}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    origin = URI.parse(uri)

    controller_url =
      URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port})

    {:noreply, assign(socket, controller_url: controller_url)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        example: consumer_example(),
        launch: runner_launch(assigns.controller_url),
        starter: starter_commands()
      )

    ~H"""
    <PreviewLayouts.app
      active={:guide}
      page_title={@page_title}
      flash={@flash}
      main_class="setup-page"
    >
      <section class="preview-list" aria-labelledby="setup-heading" id="runner-guide">
        <header class="preview-heading">
          <h1 id="setup-heading" class="pf-v6-c-title pf-m-2xl">Set up a runner</h1>
          <.link navigate="/runners" class="pf-v6-c-button pf-m-secondary">Inspect runner connections</.link>
        </header>
        <p class="setup-intro">
          Checks live in your Python monitoring project. A runner executes them and sends results to Mondek; no UI action creates a check.
        </p>
        <div class="setup-grid">
          <PreviewDetail.card id="setup-project" title="1. Create your monitoring project" level={2}>
            <div class="setup-card-body">
              <p>
                Replace <code>&lt;SDK_VERSION&gt;</code>
                with the released SDK version matching your server. You need Python 3.13+ and uv. Generate into a new directory.
              </p>
              <pre id="project-starter-example">{@starter}</pre>
              <p class="setup-sdk-note">
                For an unreleased server, install its matching local SDK wheel with
                <code>uv tool install '&lt;PATH_TO_SDK_WHEEL&gt;'</code>
                instead of the first command.
              </p>
              <p>
                Edit <code>src/monitoring/app.py</code>
                and run the generated tests. Keep your source, <code>uv.lock</code>
                and stable check, result and target keys in your own repository.
              </p>
              <details id="minimal-check-reference" phx-mounted={JS.ignore_attributes("open")}>
                <summary>Minimal check for an existing project</summary>
                <pre id="consumer-example">{@example}</pre>
              </details>
            </div>
          </PreviewDetail.card>
          <PreviewDetail.card id="setup-runner" title="2. Validate and start the runner" level={2}>
            <div class="setup-card-body">
              <p>
                Run these commands on a host with access to the files or datasource you want to monitor.
              </p>
              <pre id="runner-launch-example">{@launch}</pre>
              <p>
                <code>validate</code>
                checks declarations. <code>run --all --results</code>
                collects locally without registering; inspect the reported health even when collection completes.
              </p>
              <p>
                Use a server address reachable from the runner. <code>localhost</code>
                refers to that runner's own host. Give each deployed runner its own persistent state directory, and reuse it across restarts.
              </p>
            </div>
          </PreviewDetail.card>
          <PreviewDetail.card
            id="setup-verify"
            title="3. Confirm collection"
            level={2}
            class="setup-wide"
          >
            <PreviewDetail.facts label="Verify runner setup">
              <tr>
                <th scope="row">Runner contact</th><td>
                  <.link navigate="/runners">Runners</.link>
                  shows whether the server can hear from the runner. Contact alone does not prove collection.
                </td>
              </tr>
              <tr>
                <th scope="row">Measurements</th><td>
                  <.link navigate="/checks">Browse results</.link>
                  and wait for a fresh measurement for each expected result. Fresh Critical or Warning means collection is working and a check found a problem.
                </td>
              </tr>
              <tr>
                <th scope="row">Saved settings</th><td>
                  <.link navigate="/configuration">Configuration</.link>
                  edits parameters delegated by your check code. A save still needs runner preparation, activation and a new measurement.
                </td>
              </tr>
            </PreviewDetail.facts>
          </PreviewDetail.card>
          <PreviewDetail.card
            id="setup-placement"
            title="Deployment and later changes"
            level={2}
            class="setup-wide"
          >
            <PreviewDetail.facts label="Deployment choices">
              <tr>
                <th scope="row">Node checks</th><td>
                  Run an observer on each node whose local data it needs. A container sees its own filesystem unless you mount host data.
                </td>
              </tr>
              <tr>
                <th scope="row">Datasource checks</th><td>
                  Use a runner with network access and local credentials. The monitored target and environment are separate from the runner's execution context.
                </td>
              </tr>
              <tr>
                <th scope="row">Project changes</th><td>
                  Change code, targets, schedules and datasource settings in your project, then restart the runner to publish the complete inventory. Failed imports or rejected inventories preserve accepted checks.
                </td>
              </tr>
              <tr>
                <th scope="row">Notification controls</th><td>
                  Acknowledgement and maintenance pause failure notifications; checks and recovery notifications continue.
                </td>
              </tr>
            </PreviewDetail.facts>
            <details class="setup-disclosure" phx-mounted={JS.ignore_attributes("open")}>
              <summary>Removing or restoring a result</summary>
              <p>
                A successfully accepted inventory retires any removed checks or outputs. Open incidents close as “Source removed”, not measured recovery. Their history remains available through the Retired filter in Checks. A restored result starts a new history; unchanged results keep theirs.
              </p>
            </details>
          </PreviewDetail.card>
        </div>
      </section>
      <div class="setup-agent-help">
        <AgentPrompts.library
          id="runner-agent-prompts"
          context={%{"controller_url" => @controller_url}}
        />
      </div>
    </PreviewLayouts.app>
    """
  end

  defp consumer_example do
    """
    # my_checks/app.py — install this module with your consumer package
    from pathlib import Path
    from mondek_runner import App, Environment, check, crit, ok

    @check(id="export-present", name="Application export", expected_keys=("present",))
    def export_present():
        if Path("/srv/application/export.json").is_file():
            return ok("present", "Export file exists")
        return crit("present", "Expected export file is missing")

    app = App(
        source_id="application-checks",
        environment=Environment("node-a", "Production node"),
        checks=[export_present],
    )
    """
  end

  defp runner_launch(controller_url) do
    quoted_url = "'" <> String.replace(controller_url, "'", "'\\''") <> "'"

    """
    uv run --locked mondek-runner validate --consumer monitoring.app:app
    uv run --locked mondek-runner run --consumer monitoring.app:app --all --results
    uv run --locked mondek-runner --consumer monitoring.app:app \\
      --controller #{quoted_url} --state-dir .mondek-state
    """
  end

  defp starter_commands do
    """
    uv tool install 'mondek==<SDK_VERSION>'
    mondek-runner init my-monitoring
    cd my-monitoring
    uv sync
    """
  end
end
