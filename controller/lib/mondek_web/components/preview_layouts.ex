# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewLayouts do
  use MondekWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-preview-theme="pearl">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title suffix=" · Mondek">{assigns[:page_title] || "Mondek"}</.live_title>
        <link rel="stylesheet" href={MondekWeb.Endpoint.static_path("/assets/preview.css")} />
        <script defer type="module" src={MondekWeb.Endpoint.static_path("/assets/preview.js")}>
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  attr :active, :atom, required: true
  attr :overview_path, :string, default: "/next"

  def navigation(assigns) do
    ~H"""
    <a class="preview-skip pf-v6-c-button pf-m-link" href="#main-content">Skip to content</a>
    <header class="preview-masthead">
      <.link href="/next" class="preview-brand">mondek</.link>
      <span class="preview-caption">Monitoring</span>
      <.link href="/guide" class="pf-v6-c-button pf-m-link">Help &amp; setup</.link>
    </header>
    <aside class="preview-sidebar">
      <.link href="/next" class="preview-sidebar-brand"><span
        class="preview-brand-mark"
        aria-hidden="true"
      >m</span><span>mondek<span class="preview-caption">Monitoring</span></span></.link>
      <nav class="pf-v6-c-nav" aria-label="Main navigation">
        <ul class="pf-v6-c-nav__list">
          <li
            :for={
              {page, label, href, icon} <- [
                {:overview, "Overview", @overview_path, "grid"},
                {:incidents, "Incidents", "/next/incidents", "pulse"},
                {:checks, "Checks", "/next/checks", "check"},
                {:maintenance, "Maintenance", "/next/maintenance", "clock"}
              ]
            }
            class="pf-v6-c-nav__item"
          >
            <.link
              href={href}
              class={["pf-v6-c-nav__link", @active == page && "pf-m-current"]}
              aria-current={if @active == page, do: "page"}
            ><MondekWeb.Layouts.icon name={icon} size={18} /><span>{label}</span></.link>
          </li>
        </ul>
        <h2 class="preview-nav-heading">Manage</h2>
        <ul class="pf-v6-c-nav__list">
          <li
            :for={
              {page, label, href, icon} <- [
                {:configuration, "Configuration", "/configuration", "sliders"},
                {:runners, "Runners", "/runners", "server"},
                {:notifications, "Notifications", "/notifications", "send"},
                {:coverage, "Coverage", "/next/coverage", "shield"}
              ]
            }
            class="pf-v6-c-nav__item"
          >
            <a
              href={href}
              class={["pf-v6-c-nav__link", @active == page && "pf-m-current"]}
              aria-current={if @active == page, do: "page"}
            ><MondekWeb.Layouts.icon name={icon} size={18} /><span>{label}</span></a>
          </li>
        </ul>
      </nav>
      <a href="/licenses" class="preview-credits">Licenses and credits</a>
    </aside>
    """
  end

  attr :active, :atom, required: true
  attr :page_title, :string, required: true
  attr :flash, :map, default: %{}
  attr :main_class, :string, default: ""
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="preview-shell">
      <.navigation active={@active} />
      <main
        id="main-content"
        class={["preview-main", @main_class]}
        tabindex="-1"
        aria-label={@page_title}
      >
        <div
          :for={key <- [:info, :error]}
          :if={Phoenix.Flash.get(@flash, key)}
          class={["ui-feedback", key == :error && "ui-error"]}
          role={if key == :error, do: "alert", else: "status"}
        >
          <span>{Phoenix.Flash.get(@flash, key)}</span>
          <button
            type="button"
            phx-click="lv:clear-flash"
            phx-value-key={key}
            aria-label="Dismiss message"
          >×</button>
        </div>
        {render_slot(@inner_block)}
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end
end
