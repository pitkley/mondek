# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LicensesLive do
  use MondekWeb, :live_view
  alias Mondek.Licenses
  alias MondekWeb.{PreviewDetail, PreviewLayouts}
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Licenses and credits",
       components: Licenses.components(),
       application_license: Licenses.application_license()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PreviewLayouts.app
      active={:licenses}
      page_title={@page_title}
      flash={@flash}
      main_class="credits-page"
    >
      <section class="preview-list" aria-labelledby="credits-heading">
        <header class="preview-heading">
          <h1 id="credits-heading" class="pf-v6-c-title pf-m-2xl">Licenses and credits</h1>
          <a href="/licenses/notices" class="pf-v6-c-button pf-m-secondary">Download third-party notices</a>
        </header>
        <PreviewDetail.card id="application-license" title="Application license" level={2}>
          <PreviewDetail.facts label="Application attribution">
            <tr>
              <th scope="row">License</th><td>Apache License, Version 2.0</td>
            </tr>
            <tr>
              <th scope="row">Copyright</th><td>Copyright 2026 Pit Kleyersburg.</td>
            </tr>
          </PreviewDetail.facts>
          <details class="credits-disclosure" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Read the Apache License, Version 2.0</summary>
            <pre>{@application_license}</pre>
          </details>
        </PreviewDetail.card>
        <PreviewDetail.card id="third-party-credits" title="Third-party components" level={2}>
          <p class="credits-intro">
            These notices cover the controller, bundled browser code, icons and scaffold adaptations. Container operating systems and language runtimes retain their own notices in their distributions.
          </p>
          <div class="credits-components">
            <details
              :for={component <- @components}
              id={"credit-" <> component["name"]}
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>
                <strong>{component["name"]}</strong>
                <span>{component["version"]} · {component["license"]}</span>
              </summary>
              <div :for={notice <- component["notices"]} class="credit-notice">
                <h3>{notice["path"]}</h3>
                <pre>{notice["text"]}</pre>
              </div>
            </details>
          </div>
        </PreviewDetail.card>
      </section>
    </PreviewLayouts.app>
    """
  end
end
