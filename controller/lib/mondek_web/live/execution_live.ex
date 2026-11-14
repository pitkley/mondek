# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ExecutionLive do
  use MondekWeb, :live_view
  alias Mondek.Monitoring
  alias MondekWeb.{BrowserNavigation, InvestigationStack, InvestigationTrail, PreviewLayouts}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)
    {:ok, assign(socket, now: Monitoring.now(), page_title: "Scheduled execution")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    uri = URI.parse(uri)
    root = InvestigationTrail.identity({"execution", params["id"]})

    {:noreply,
     assign(socket,
       root: root,
       params: params,
       host: uri.path <> if(uri.query, do: "?" <> uri.query, else: ""),
       back: BrowserNavigation.return_path(params["return_to"]) || "/checks"
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, assign(socket, now: Monitoring.now())}
  end

  @impl true
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="execution-shell"
      phx-hook="OverviewPanel"
      data-selection={InvestigationTrail.selection(@params)}
      data-panel-heading={InvestigationTrail.heading(@params, "execution-heading")}
    >
      <PreviewLayouts.navigation active={:checks} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section :if={!@root} class="preview-list">
          <header class="preview-heading">
            <h1>Scheduled execution not found</h1>
          </header><p class="preview-empty">This scheduled check identity is not available.</p><.link navigate="/checks">Browse results</.link>
        </section>
        <.live_component
          :if={@root}
          module={InvestigationStack}
          id="investigation-stack"
          host={@host}
          params={@params}
          now={@now}
          root={@root}
          initial={[]}
          context={"execution:" <> elem(@root, 1)}
          back={@back}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end
end
