# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewLayouts do
  use MondekWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title suffix=" · Mondek">Overview preview</.live_title>
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
      <span class="preview-caption">UI preview</span>
      <details id="preview-theme-picker" class="preview-theme-picker" phx-update="ignore">
        <summary class="pf-v6-c-button pf-m-plain" aria-label="Choose theme">
          <span aria-hidden="true">◐</span><span class="preview-theme-title">Theme</span>
        </summary>
        <fieldset class="preview-theme-menu">
          <legend>Light themes</legend>
          <label :for={
            {value, name, description} <- [
              {"pearl", "Pearl", "Near-white canvas · white surfaces"},
              {"clear", "Clear", "White canvas · blue accents"},
              {"mist", "Mist", "Cool canvas · white surfaces"},
              {"linen", "Linen", "Warm canvas · teal accents"},
              {"original", "Original", "Previous gray palette"}
            ]
          }>
            <input
              type="radio"
              name="preview-theme"
              value={value}
              checked={value == "pearl"}
              data-preview-theme-choice
            />
            <span><strong>{name}</strong><span class="preview-caption">{description}</span></span>
          </label>
        </fieldset>
      </details>
      <a class="pf-v6-c-button pf-m-link" href="/">Open existing UI</a>
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
                {:incidents, "Incidents", "/next/incidents", "pulse"}
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
        <h2 class="preview-nav-heading">Existing pages</h2>
        <ul class="pf-v6-c-nav__list">
          <li
            :for={
              {label, href, icon} <- [
                {"Checks", "/checks", "check"},
                {"Maintenance", "/maintenance", "clock"},
                {"Configuration", "/configuration", "sliders"},
                {"Runners", "/runners", "server"},
                {"Notifications", "/notifications", "send"}
              ]
            }
            class="pf-v6-c-nav__item"
          >
            <a href={href} class="pf-v6-c-nav__link"><MondekWeb.Layouts.icon name={icon} size={18} /><span>{label}</span></a>
          </li>
        </ul>
      </nav>
      <a href="/licenses" class="preview-credits">Licenses and credits</a>
    </aside>
    """
  end
end
