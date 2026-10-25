# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.LicensesLive do
  use MondekWeb, :live_view
  alias Mondek.Licenses
  alias MondekWeb.Layouts

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Licenses and credits",
       now: DateTime.utc_now(),
       components: Licenses.components(),
       application_license: Licenses.application_license()
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      active={:licenses}
      page_title={@page_title}
      now={@now}
      flash={@flash}
      main_class="credits"
    >
      <div class="page-heading">
        <div>
          <h1>Licenses and credits</h1>
          <p>
            Mondek is licensed under Apache-2.0. Third-party components retain their own licenses and attribution.
          </p>
        </div>
      </div>
      <section class="panel" aria-labelledby="application-license-heading">
        <h2 id="application-license-heading">Application license</h2>
        <p>Copyright 2026 Pit Kleyersburg.</p>
        <details>
          <summary>Read the Apache License, Version 2.0</summary><pre>{@application_license}</pre>
        </details>
      </section>
      <section aria-labelledby="third-party-heading" id="third-party-credits">
        <h2 id="third-party-heading">Third-party components</h2>
        <p>
          These notices cover the controller, its bundled browser code, icons and scaffold adaptations. Container operating systems and language runtimes retain their own notices in their distributions.
        </p>
        <p><a href="/licenses/notices">Download controller third-party notices</a></p>
        <details :for={component <- @components} class="panel" id={"credit-" <> component["name"]}>
          <summary>
            <strong>{component["name"]}</strong> {component["version"]} · {component["license"]}
          </summary>
          <div :for={notice <- component["notices"]} class="credit-notice">
            <h3>{notice["path"]}</h3><pre>{notice["text"]}</pre>
          </div>
        </details>
      </section>
    </Layouts.app>
    """
  end
end
