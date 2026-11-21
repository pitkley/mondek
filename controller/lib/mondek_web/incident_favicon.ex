# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.IncidentFavicon do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  @refresh_interval 5_000

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      {:cont, socket |> attach_hook(:incident_favicon, :handle_info, &refresh/2) |> publish()}
    else
      {:cont, socket}
    end
  end

  defp refresh(:refresh_incident_favicon, socket), do: {:halt, publish(socket)}
  defp refresh(_, socket), do: {:cont, socket}

  defp publish(socket) do
    Process.send_after(self(), :refresh_incident_favicon, @refresh_interval)
    count = Mondek.Inspection.navigation_counts(Mondek.Monitoring.now())["open_alert_count"]

    if socket.assigns[:incident_favicon_count] == count do
      socket
    else
      socket
      |> assign(:incident_favicon_count, count)
      |> push_event("open-alert-count", %{count: count})
    end
  end
end
