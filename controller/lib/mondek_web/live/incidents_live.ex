# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.IncidentsLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation
  alias Mondek.Monitoring
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

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(~w(search runner_id environment health freshness status configuration_stage))
      |> Map.merge(result_page_size_filter(socket.assigns.filters, socket.assigns.live_action))

    {:noreply,
     push_patch(socket, to: filter_path(socket.assigns.live_action, filters), replace: true)}
  end

  def handle_event("recover_filters", params, socket) do
    mode = socket.assigns.live_action

    # Recovered controls include empty inputs and the selected default status,
    # while the URL may omit both. Replaying those values is not a filter edit
    # and must not discard the current result page or rewrite its return URL.
    if comparable_inventory_filters(params, mode) ==
         comparable_inventory_filters(socket.assigns.filters, mode) do
      {:noreply, socket}
    else
      handle_event("filter", params, socket)
    end
  end

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = Monitoring.overview(at)

    socket =
      assign(socket, snapshot: snapshot, now: parse_time(snapshot["now"]) || DateTime.utc_now())

    listing = Monitoring.list_incidents(socket.assigns.filters, at)

    assign(socket,
      listing: page_projection(listing),
      snapshot:
        Map.put(snapshot, "environments", get_in(listing, [:facets, "environments"]) || [])
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
      <.incident_list
        :if={@live_action == :incidents}
        snapshot={@snapshot}
        listing={@listing}
        filters={@filters}
        now={@now}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp incident_list(assigns) do
    ~H"""
    <MondekWeb.Layouts.section_header
      section="Incidents"
      description="Investigate target health and missing monitoring, with controls for their notifications."
      nav_label="Incident views"
    >
      <:tabs>
        <.link navigate="/incidents" aria-current="page">Target health</.link><.link navigate="/monitoring-incidents">Monitoring loss</.link>
      </:tabs>
    </MondekWeb.Layouts.section_header>
    <div class="page-heading view-heading">
      <div>
        <h2>Target health</h2><p>
          Related failures share an incident when their check code declares the same condition and monitored environment. Other failures remain separate.
        </p>
      </div><span class="badge">{@snapshot["open_incident_count"] || 0} open · {@snapshot[
        "acknowledged_incident_count"
      ] || 0} acknowledged</span>
    </div>
    <.inventory_filters filters={@filters} mode={:incidents} snapshot={@snapshot} />
    <section class="panel" id="incident-list">
      <div class="panel-heading">
        <div>
          <h2>Incidents</h2>
          <p class="sub">
            Unacknowledged first. Within each acknowledgement state: severity, then open before closed, oldest first.
          </p>
        </div><span class="badge">{@listing["total"]} matching</span>
      </div>
      <.incidents_table
        incidents={@listing["items"]}
        assignments={[]}
        now={@now}
        return_to={filter_path(:incidents, @filters)}
        empty_title="No matching incidents"
        empty_description="Change the filters to inspect other retained incidents."
      />
      <.pagination listing={@listing} filters={@filters} mode={:incidents} />
    </section>
    <p class="footnote space-top">
      The navigation count includes only unacknowledged open incidents. Acknowledgement holds failure notifications; it does not resolve the failure. A stale critical measurement does not close its incident. Source removal preserves history without claiming recovery.
    </p>
    """
  end
end
