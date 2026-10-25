# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ChecksLive do
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

    socket =
      if connected?(socket) && CheckInventory.view(socket.assigns.filters) == "targets" &&
           socket.assigns.filters["target"] not in [nil, ""] &&
           socket.assigns.filters["target"] != params["target"],
         do: push_patch(socket, to: CheckInventory.path(socket.assigns.filters), replace: true),
         else: socket

    {:noreply, socket}
  end

  @impl true

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    previous_target = socket.assigns.filters["target"]
    socket = refresh(socket)

    if socket.assigns.live_action == :checks &&
         CheckInventory.view(socket.assigns.filters) == "targets" &&
         socket.assigns.filters["target"] not in [nil, ""] &&
         socket.assigns.filters["target"] != previous_target do
      {:noreply,
       push_patch(socket, to: CheckInventory.path(socket.assigns.filters), replace: true)}
    else
      {:noreply, socket}
    end
  end

  # A large inventory can publish hundreds of changes per second. The existing
  # one-second tick coalesces background updates, including saved bulk progress;
  # reloading on every broadcast competes with ingestion and runner preparation.
  # Explicit user actions still refresh immediately in their event handlers.
  def handle_info(:changed, socket), do: {:noreply, socket}

  @impl true
  def handle_event("checks_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(socket,
       to: CheckInventory.path(CheckInventory.change_tab(socket.assigns.filters, tab))
     )}
  end

  def handle_event("checks_view", %{"view" => view}, socket) do
    filters = selected_target_filters(socket) |> CheckInventory.change_view(view)
    {:noreply, push_patch(socket, to: CheckInventory.path(filters))}
  end

  def handle_event("select_target", %{"target" => target}, socket) do
    filters = socket.assigns.filters |> Map.delete("page") |> Map.put("target", target)
    {:noreply, push_patch(socket, to: CheckInventory.path(filters))}
  end

  def handle_event("group_search", params, socket) do
    search = params["group_search"] || ""

    if search == (socket.assigns.filters["group_search"] || "") do
      {:noreply, socket}
    else
      filters =
        selected_target_filters(socket)
        |> Map.drop(~w(group_limit target_page))
        |> Map.put("group_search", search)
        |> CheckInventory.normalize()

      {:noreply, push_patch(socket, to: CheckInventory.path(filters), replace: true)}
    end
  end

  def handle_event("load_more_groups", _, socket) do
    if socket.assigns.listing["group_has_more"] do
      limit = min((socket.assigns.listing["group_limit"] || 100) + 100, 1000)

      filters =
        selected_target_filters(socket)
        |> Map.delete("target_page")
        |> Map.put("group_limit", to_string(limit))

      {:noreply, push_patch(socket, to: CheckInventory.path(filters), replace: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_checks_scope", _, socket) do
    {:noreply,
     push_patch(socket,
       to: CheckInventory.path(CheckInventory.clear_scope(socket.assigns.filters))
     )}
  end

  def handle_event("clear_checks_all", _, socket) do
    {:noreply,
     push_patch(socket, to: CheckInventory.path(CheckInventory.clear_all(socket.assigns.filters)))}
  end

  def handle_event("filter", params, %{assigns: %{live_action: :checks}} = socket) do
    filters = selected_target_filters(socket) |> CheckInventory.change_scope(params)
    {:noreply, push_patch(socket, to: CheckInventory.path(filters), replace: true)}
  end

  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(~w(search runner_id environment health freshness status configuration_stage))
      |> Map.merge(result_page_size_filter(socket.assigns.filters, socket.assigns.live_action))

    {:noreply,
     push_patch(socket, to: filter_path(socket.assigns.live_action, filters), replace: true)}
  end

  def handle_event("page_size", params, %{assigns: %{live_action: :checks}} = socket) do
    if result_page_size(params["page_size"]) ==
         result_page_size(socket.assigns.filters["page_size"]) do
      {:noreply, socket}
    else
      filters =
        socket.assigns.filters
        |> Map.drop(~w(page page_size))
        |> Map.merge(result_page_size_filter(params, :checks))

      {:noreply, push_patch(socket, to: filter_path(:checks, filters), replace: true)}
    end
  end

  def handle_event("recover_page_size", params, %{assigns: %{live_action: :checks}} = socket),
    do: handle_event("page_size", params, socket)

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

    filters = socket.assigns.filters

    listing =
      if CheckInventory.view(filters) == "targets",
        do: Monitoring.list_target_streams(filters),
        else: Monitoring.list_grouped_streams(filters)

    filters =
      if listing[:selected_target],
        do: Map.put(filters, "target", listing[:selected_target]["id"]),
        else: filters

    assign(socket,
      filters: filters,
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
      <CheckInventory.page
        :if={@live_action == :checks}
        listing={@listing}
        filters={@filters}
        snapshot={@snapshot}
        now={@now}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp selected_target_filters(socket) do
    case get_in(socket.assigns.listing || %{}, ["selected_target", "id"]) do
      nil -> socket.assigns.filters
      target -> Map.put(socket.assigns.filters, "target", target)
    end
  end

  defp result_page_size(value), do: MondekWeb.InvestigationNavigation.result_page_size(value)
end
