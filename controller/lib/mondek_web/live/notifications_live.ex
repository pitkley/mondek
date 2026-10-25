# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationsLive do
  use MondekWeb, :live_view

  alias Mondek.{Inspection, Monitoring}

  alias MondekWeb.{
    InvestigationNavigation,
    Layouts,
    NotificationComponents,
    NotificationNavigation
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)

    {:ok,
     assign(socket,
       selected_id: nil,
       filters: %{},
       return_to: nil,
       retry_drafts: %{},
       snapshot: %{},
       inspection: nil,
       now: Monitoring.now(),
       page_title: "Notifications"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    drafts =
      if socket.assigns.live_action == :notification && socket.assigns.selected_id == params["id"],
        do: socket.assigns.retry_drafts,
        else: %{}

    {:noreply,
     socket
     |> assign(
       selected_id: params["id"],
       filters: NotificationNavigation.filters(params),
       return_to: InvestigationNavigation.safe_return_path(params["return_to"]),
       retry_drafts: drafts,
       page_title: if(params["id"], do: "Notification detail", else: "Notifications")
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("notification_filter", params, socket) do
    filters = NotificationNavigation.filters(Map.take(params, ~w(notification_status)))
    current = get_in(socket.assigns.snapshot, ["notification_page", "status"])

    if (filters["notification_status"] || "unresolved") == current,
      do: {:noreply, socket},
      else:
        {:noreply, push_patch(socket, to: NotificationNavigation.path(filters), replace: true)}
  end

  def handle_event("edit_notification_retry", %{"_id" => id, "reason" => reason}, socket),
    do: {:noreply, keep_retry_draft(socket, id, reason)}

  def handle_event("retry_notification", %{"_id" => id, "reason" => reason}, socket) do
    socket = keep_retry_draft(socket, id, reason)

    case Monitoring.retry_notification(id, reason) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(retry_drafts: Map.delete(socket.assigns.retry_drafts, id))
         |> refresh()
         |> clear_flash(:error)
         |> put_flash(:info, MondekWeb.NotificationRetry.success_message())}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:error, MondekWeb.NotificationRetry.error_message(reason))}
    end
  end

  defp keep_retry_draft(socket, id, reason) do
    occurrences = List.wrap(get_in(socket.assigns.inspection || %{}, ["occurrence"]))

    assign(socket,
      retry_drafts:
        MondekWeb.NotificationRetry.keep_draft(
          socket.assigns.retry_drafts,
          occurrences,
          id,
          reason
        )
    )
  end

  defp refresh(socket) do
    now = Monitoring.now()
    snapshot = Map.put(Inspection.navigation_counts(now), "now", Monitoring.iso(now))

    {snapshot, inspection} =
      if socket.assigns.live_action == :notifications do
        {Map.merge(snapshot, Monitoring.delivery_inspection(socket.assigns.filters, now)), nil}
      else
        {snapshot, Inspection.notification_detail(socket.assigns.selected_id, now)}
      end

    assign(socket, snapshot: snapshot, inspection: inspection, now: now)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      active={@live_action}
      page_title={@page_title}
      snapshot={@snapshot}
      now={@now}
      flash={@flash}
    >
      <NotificationComponents.notifications
        :if={@live_action == :notifications}
        snapshot={@snapshot}
        now={@now}
        filters={@filters}
        retry_drafts={@retry_drafts}
      />
      <NotificationComponents.notification_detail
        :if={@live_action == :notification}
        inspection={@inspection}
        now={@now}
        retry_drafts={@retry_drafts}
        return_to={@return_to}
      />
    </Layouts.app>
    """
  end
end
