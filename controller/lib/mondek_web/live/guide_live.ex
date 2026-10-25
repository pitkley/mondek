# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GuideLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation
  alias Mondek.Monitoring
  alias MondekWeb.AgentPrompts
  alias Phoenix.LiveView.JS
  import MondekWeb.MonitoringUI
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1000)

    {:ok,
     socket
     |> assign(
       selected_id: nil,
       return_to: nil,
       controller_url: MondekWeb.Endpoint.url(),
       filters: %{},
       listing: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(
        selected_id: params["id"],
        return_to: safe_return_path(params["return_to"]),
        controller_url: controller_origin(uri),
        filters: inventory_params(params, socket.assigns.live_action),
        page_title: page_name(socket.assigns.live_action)
      )

    socket = refresh(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = Monitoring.overview(at)

    socket =
      assign(socket, snapshot: snapshot, now: parse_time(snapshot["now"]) || DateTime.utc_now())

    socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={@live_action}
      page_title={page_name(@live_action)}
      snapshot={@snapshot}
      now={@now}
      flash={@flash}
    >
      <.authoring_guide :if={@live_action == :guide} controller_url={@controller_url} />
    </MondekWeb.Layouts.app>
    """
  end

  defp authoring_guide(assigns) do
    assigns =
      assign(assigns,
        example: consumer_example(),
        launch: runner_launch(assigns.controller_url),
        starter: starter_commands()
      )

    ~H"""
    <div class="page-heading">
      <div>
        <div class="eyebrow">Runner-provided monitoring</div><h1>Set up a runner</h1><p>
          Create a Python monitoring project, run it where its data is reachable, and inspect its published results here. Mondek calls an installed monitoring project a consumer package.
        </p>
      </div>
    </div>
    <div class="details-grid" id="runner-guide">
      <div class="stack">
        <section class="panel">
          <div class="panel-heading">
            <h2>1. Create your monitoring project</h2>
          </div>
          <div class="panel-body">
            <p>
              Install the selected Mondek SDK release with Python 3.13+ and uv, then generate a monitoring project with a small file-backed backlog check, editable limits and tests. No Mondek source checkout is required.
            </p>
            <pre class="space-top" id="project-starter-example">{@starter}</pre>
            <p class="space-top">
              Open the generated README and <code>src/monitoring/app.py</code>.
              Your project owns the Python logic, dependencies and datasource settings.
              A <code>Parameter</code> declaration exposes a setting in Configuration;
              it does not move the check's logic into the Mondek server.
            </p>
            <p class="footnote space-top">
              Choose a new project directory.
              For ongoing monitoring, keep your project in its own repository and commit its code and <code>uv.lock</code>.
            </p>
            <details
              id="minimal-check-reference"
              class="disclosure space-top"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>Minimal check reference for an existing project</summary>
              <pre id="consumer-example">{@example}</pre>
            </details>
            <p class="space-top">
              Keep source, check, result, and target keys stable across deployments. Display names may change. A check can declare several outputs; each result has its own target, health, and incident history.
            </p>
          </div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <h2>2. Validate, then collect</h2>
          </div>
          <div class="panel-body">
            <p>
              Run these commands from your generated monitoring project on the runner host. Validation imports the project; the local run executes its checks without registering with the Mondek server. The final command starts the persistent runner and publishes its inventory.
            </p>
            <pre class="space-top" id="runner-launch-example">{@launch}</pre>
            <p class="space-top">
              A complete local run can still report failing health; inspect the reported results. For a larger project, select one check with
              <code>--check CHECK_ID</code>
              instead of <code>--all</code>.
            </p>
            <p class="space-top">
              The Mondek server address above is the address used by this browser. For a different machine or container, replace it with an address reachable from that runner.
              <code>localhost</code>
              refers to the runner's own host.
            </p>
            <p class="space-top">
              Reuse this state directory for this runner's restarts. It contains its installation identity, accepted code and private datasource settings, and buffered reports. Give each independently deployed runner its own persistent directory or volume.
            </p>
          </div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <h2>3. Verify and evolve</h2>
          </div>
          <div class="panel-body">
            <p>
              Open Runners to confirm contact, then Checks to inspect expected results. Contact alone does not establish coverage: wait for a fresh measurement for each result.
            </p>
            <p class="space-top">
              Change code, targets, schedule and datasource settings in your project, then restart the runner to publish its complete inventory. A failed import, rejected inventory or disconnected runner preserves the accepted checks.
            </p>
            <p class="space-top">
              Removing a check or output from a successfully accepted inventory retires it. Any open incident closes as “Source removed”, with its history retained; this is not measured recovery. Find it with the Retired filter in Checks. Restoring a retired result starts a new result history, while unchanged results keep theirs.
            </p>
            <.link navigate="/runners" class="button space-top">Inspect runner connections</.link>
            <.link navigate="/checks" class="button space-top">Browse results</.link>
          </div>
        </section>
      </div>
      <aside class="stack">
        <section class="panel">
          <div class="panel-heading">
            <h2>Where a check runs</h2>
          </div>
          <div class="panel-body">
            <p>
              <strong>Node monitoring:</strong>
              deploy a runner on each node whose local files, processes, or disks it should inspect. A container sees its own filesystem unless you explicitly mount host data.
            </p>
            <p class="space-top">
              <strong>Datasource monitoring:</strong>
              deploy a dedicated runner with network access and locally configured credentials for the datasource. Declare the monitored service as the result's target; it is distinct from the runner collecting it.
            </p>
            <p class="space-top">
              Monitored environment identifies where a target belongs, using a stable ID and a separate display name. The observing runner can execute in a different environment. Target identifies what a result measures; renaming a display label keeps its identity.
            </p>
          </div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <h2>What the UI can change</h2>
          </div>
          <div class="panel-body">
            <p>
              Configuration edits only a complete parameter set explicitly delegated by the consumer through
              <code>Parameter</code>
              declarations. Source-owned values remain read-only. Saved changes still need runner preparation, activation, and a new measurement.
            </p>
            <p class="space-top">
              Acknowledgement and notification maintenance hold future failure notifications. They do not stop collection or remove expected results.
            </p>
          </div>
        </section>
      </aside>
    </div>
    <AgentPrompts.library id="runner-agent-prompts" context={%{"controller_url" => @controller_url}} />
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
    uv tool install mondek
    mondek-runner init my-monitoring
    cd my-monitoring
    uv sync
    """
  end
end
