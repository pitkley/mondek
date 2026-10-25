# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Layouts do
  use MondekWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><meta
          name="csrf-token"
          content={Plug.CSRFProtection.get_csrf_token()}
        /><.live_title suffix=" · Mondek">
          {assigns[:page_title] || "Local monitoring"}
        </.live_title><link
          rel="stylesheet"
          href={MondekWeb.Endpoint.static_path("/assets/app.css")}
        /><script
          defer
          type="module"
          src={MondekWeb.Endpoint.static_path("/assets/app.js")}
        >
        </script>
      </head><body>
        {@inner_content}
        <footer class="license-footer"><a href="/licenses">Licenses and credits</a></footer>
      </body>
    </html>
    """
  end

  attr :active, :atom, required: true
  attr :page_title, :string, required: true
  attr :snapshot, :map, default: %{}
  attr :now, :any, required: true
  attr :flash, :map, default: %{}
  attr :main_class, :string, default: ""
  attr :updated_time_id, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app-shell">
      <a class="skip-link" href="#main-content">Skip to content</a>
      <aside class="sidebar" aria-label="Main navigation">
        <.link navigate="/" class="brand" aria-label="Mondek overview">
          <span class="brand-mark" aria-hidden="true"><i></i><i></i><i></i></span>mondek
        </.link>
        <div class="workspace">
          <div class="eyebrow">Workspace</div><strong>Current installation</strong>
        </div>
        <div class="nav-label">MONITORING</div>
        <nav class="nav">
          <.link
            navigate="/"
            aria-current={nav_current(@active, [:overview])}
            class={nav_class(@active, [:overview])}
          ><.icon name="grid" />Overview</.link>
          <.link
            navigate="/checks"
            aria-current={
              nav_current(@active, [
                :checks,
                :check,
                :resource,
                :check_diagnostics,
                :resource_diagnostics
              ])
            }
            class={
              nav_class(@active, [
                :checks,
                :check,
                :resource,
                :check_diagnostics,
                :resource_diagnostics
              ])
            }
          ><.icon name="shield" />Checks</.link>
          <.link
            navigate="/coverage"
            class={nav_class(@active, [:coverage])}
            aria-current={nav_current(@active, [:coverage])}
          ><.icon name="grid" />Coverage</.link>
          <.link
            navigate="/incidents"
            id="incident-navigation"
            aria-label={"Incidents · #{@snapshot["unacknowledged_incident_count"] || 0} unacknowledged open incidents" <> if((get_in(@snapshot, ["monitoring_loss", "unacknowledged_count"]) || 0) > 0, do: " · #{get_in(@snapshot, ["monitoring_loss", "unacknowledged_count"])} monitoring loss incidents need attention", else: "")}
            aria-current={nav_current(@active, [:incidents, :incident])}
            class={nav_class(@active, [:incidents, :incident])}
          ><.icon name="pulse" />Incidents<span
            id="incident-attention-count"
            class="count"
            title="Unacknowledged open incidents"
            aria-hidden="true"
          >{@snapshot["unacknowledged_incident_count"] || 0}</span><span
            :if={(get_in(@snapshot, ["monitoring_loss", "unacknowledged_count"]) || 0) > 0}
            class="count monitoring-loss-count"
            title="Unacknowledged monitoring loss incidents"
            aria-hidden="true"
          >+{get_in(@snapshot, ["monitoring_loss", "unacknowledged_count"])}</span></.link>
          <.link
            navigate="/maintenance"
            class={nav_class(@active, [:maintenance])}
            aria-current={nav_current(@active, [:maintenance])}
          ><.icon name="clock" />Maintenance</.link>
          <.link
            navigate="/configuration"
            aria-current={nav_current(@active, [:configuration, :configuration_detail])}
            class={nav_class(@active, [:configuration, :configuration_detail])}
          ><.icon name="sliders" />Configuration</.link>
          <.link
            navigate="/runners"
            aria-current={nav_current(@active, [:runners])}
            class={nav_class(@active, [:runners])}
          ><.icon name="server" />Runners</.link>
          <.link
            navigate="/notifications"
            aria-current={nav_current(@active, [:notifications, :notification])}
            class={nav_class(@active, [:notifications, :notification])}
          ><.icon name="send" />Notifications</.link>
          <.link
            navigate="/guide"
            aria-current={nav_current(@active, [:guide])}
            class={nav_class(@active, [:guide])}
          ><.icon name="code" />Runner setup</.link>
        </nav>
        <div class="sidebar-bottom">
          <span class="local-label"><.icon name="terminal" size={12} />Local development</span>
          <p>One installation.<br />A clear view of every check.</p>
          <div class="operator">
            <div class="avatar">LO</div><div>
              <strong>Local operator</strong><br /><small>Single operator workspace</small>
            </div>
          </div>
        </div>
      </aside>
      <div class="body">
        <header class="topbar">
          <div class="breadcrumbs">
            <span>Workspace</span><span>/</span><b>{@page_title}</b>
          </div>
          <div class="live-indicator">
            <span class="dot"></span>Live updates
            <span aria-hidden="true">·</span><time
              id={@updated_time_id}
              datetime={DateTime.to_iso8601(@now)}
            >{Calendar.strftime(
              @now,
              "%H:%M:%S"
            )} UTC</time>
          </div>
        </header>
        <main id="main-content" class={["main", @main_class]} tabindex="-1">
          <div :if={Phoenix.Flash.get(@flash, :info)} role="status" class="notice flash">
            <span>{Phoenix.Flash.get(@flash, :info)}</span><button
              phx-click="lv:clear-flash"
              phx-value-key="info"
              aria-label="Dismiss message"
            >×</button>
          </div>
          <div :if={Phoenix.Flash.get(@flash, :error)} role="alert" class="notice error flash">
            <span>{Phoenix.Flash.get(@flash, :error)}</span><button
              phx-click="lv:clear-flash"
              phx-value-key="error"
              aria-label="Dismiss error"
            >×</button>
          </div>
          {render_slot(@inner_block)}
        </main>
      </div>
      <div class="connection-lost" role="status">
        Live connection interrupted. Displayed information may be out of date. Reconnecting…
      </div>
    </div>
    """
  end

  attr :section, :string, required: true
  attr :description, :string, required: true
  attr :nav_label, :string, required: true
  slot :tabs, required: true

  def section_header(assigns) do
    ~H"""
    <div class="page-heading section-heading">
      <div>
        <h1>{@section}</h1><p>{@description}</p>
      </div>
    </div>
    <nav class="coverage-tabs" aria-label={@nav_label}>{render_slot(@tabs)}</nav>
    """
  end

  defp nav_class(action, actions), do: if(action in actions, do: "active", else: "")
  defp nav_current(action, actions), do: if(action in actions, do: "page")

  attr :name, :string, required: true
  attr :size, :integer, default: 18

  def icon(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <use href={"/assets/icons.svg#" <> @name} />
    </svg>
    """
  end
end
