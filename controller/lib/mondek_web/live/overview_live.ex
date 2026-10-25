# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.OverviewLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation
  alias Mondek.Monitoring
  alias MondekWeb.CheckInventory
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

    assign(socket,
      listing:
        page_projection(
          Monitoring.list_streams(
            %{"page_size" => 8, "attention" => true, "unacknowledged" => true},
            at
          )
        )
    )
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
      <.overview
        :if={@live_action == :overview}
        snapshot={@snapshot}
        listing={@listing}
        now={@now}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp overview(assigns) do
    items = (assigns.listing || %{})["items"] || []

    assigns =
      assign(assigns,
        coverage: assigns.snapshot["coverage"] || %{},
        pending_count: backlog_total(assigns.snapshot),
        attention_group: %{
          "id" => "overview-attention",
          "label" => "results needing attention",
          "items" => items
        },
        runner_names: CheckInventory.runner_names(assigns.snapshot["runners"] || [], items)
      )

    ~H"""
    <div class="page-heading">
      <div>
        <div class="eyebrow">Your monitoring at a glance</div><h1>Monitoring overview</h1>
        <p>Measured health, coverage gaps, and incidents across your runners.</p>
      </div>
      <.link navigate="/checks" class="button">Browse checks <.icon name="arrow" size={14} /></.link>
    </div>
    <div class="stats">
      <div class="stat" id="coverage-summary">
        <div class="stat-label">Fresh measurements</div>
        <div class="stat-value">
          {@coverage["fresh"] || 0}<span>/ {@coverage["active"] || 0}</span>
        </div>
        <p class="stat-foot">
          Expected results across all checks. Coverage comes from scheduled evidence.
        </p>
      </div>
      <div class="stat">
        <div class="stat-label">Open target health incidents</div>
        <div class="stat-value">
          <.link navigate="/incidents">{@snapshot["open_incident_count"] || 0}</.link>
        </div>
        <p class="stat-foot">
          {@snapshot["unacknowledged_incident_count"] || 0} unacknowledged · {@snapshot[
            "acknowledged_incident_count"
          ] || 0} acknowledged
        </p>
      </div>
      <div class="stat" id="notification-work">
        <div class="stat-label">Outstanding notifications</div>
        <div class="stat-value">{@pending_count}</div>
        <.link navigate="/notifications" class="text-link">Inspect delivery</.link>
      </div>
    </div>
    <.setup :if={(@coverage["active"] || 0) == 0} />
    <div class="stack space-top">
      <section class="panel" id="overview-attention">
        <div class="panel-heading">
          <div>
            <h2 id="target-heading-overview-attention">Results needing attention</h2>
            <p>
              Unacknowledged failures and missing fresh evidence. Acknowledged problems remain in Checks.
            </p>
          </div>
        </div>
        <CheckInventory.result_rows
          :if={@attention_group["items"] != []}
          group={@attention_group}
          now={@now}
          runner_names={@runner_names}
          return_to="/"
          show_scope={true}
        />
        <div :if={@attention_group["items"] == []} class="empty">
          <h3>
            {if (@coverage["active"] || 0) > 0,
              do: "No results currently need attention",
              else: "No active results"}
          </h3>
          <p>Browse all results to inspect the monitoring inventory and measurements.</p>
        </div>
        <div class="panel-footer">
          <.link navigate="/checks" class="text-link">Browse all results</.link>
          <span>Showing {length(@attention_group["items"])} of {@listing["total"]} needing attention</span>
        </div>
      </section>
      <aside class="section-grid">
        <section class="panel panel-body" id="history-retention">
          <h2>History retention</h2>
          <p>{Mondek.Retention.summary()}</p>
        </section>
        <.runner_summary snapshot={@snapshot} now={@now} />
        <div class="notice info notice-copy">
          <p>
            A scheduled check can produce several results. Each result keeps its own health and incident history.
          </p>
          <p class="space-top">
            An unavailable runner does not remove its expected coverage. Last confirmed health keeps its original age.
          </p>
        </div>
      </aside>
    </div>
    """
  end

  defp runner_summary(assigns) do
    counts = assigns.snapshot["runner_counts"] || %{}
    assigns = assign(assigns, total: counts["total"] || 0, connected: counts["recent"] || 0)

    ~H"""
    <section class="panel">
      <div class="panel-heading">
        <h2>Runner connections</h2><.icon name="server" size={16} />
      </div><div class="panel-body">
        <p>
          <strong>{@connected} of {@total}</strong> runners have recent controller contact.
        </p>
        <p class="footnote space-top">
          Contact confirms transport, not fresh measurements or complete inventory.
        </p>
        <.link navigate="/runners" class="text-link space-top">Inspect runners</.link>
      </div>
    </section>
    """
  end
end
