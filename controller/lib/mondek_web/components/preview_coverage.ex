# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewCoverage do
  use MondekWeb, :html

  alias MondekWeb.PreviewDetail

  import MondekWeb.EvidencePresentation, only: [target_label: 1, time: 1]

  attr :evidence, :any, required: true
  attr :kind, :string, required: true
  attr :full_page, :boolean, default: false
  attr :id_prefix, :string, default: ""
  attr :heading_id, :string, default: "overview-panel-title"
  attr :current, :string, required: true
  attr :runner_path, :any, required: true
  attr :result_path, :any, required: true
  attr :page_path, :any, required: true

  def body(assigns) do
    ~H"""
    <%= if @evidence do %>
      <.detail
        :if={@kind == "coverage"}
        scope={@evidence.scope}
        observers={@evidence.observers}
        full_page={@full_page}
        id_prefix={@id_prefix}
        heading_id={@heading_id}
        current={@current}
        runner_path={@runner_path}
        result_path={@result_path}
        page_path={@page_path}
      />
      <.diagnostic_detail
        :if={@kind == "diagnostic"}
        item={@evidence.item}
        full_page={@full_page}
        id_prefix={@id_prefix}
        heading_id={@heading_id}
        current={@current}
        runner_path={@runner_path}
      />
    <% else %>
      <header class="preview-incident-intro">
        <PreviewDetail.heading level={if @full_page, do: 1, else: 2} id={@heading_id}>
          {if @kind == "diagnostic", do: "Diagnostic unavailable", else: "Declaration unavailable"}
        </PreviewDetail.heading>
        <p>
          The runner may have updated or withdrawn this declaration. Retained results and incident history remain available.
        </p>
      </header>
    <% end %>
    """
  end

  def list(assigns) do
    ~H"""
    <table class="pf-v6-c-table preview-table preview-coverage-table" aria-label="Declared results">
      <thead class="pf-v6-c-table__thead">
        <tr>
          <th scope="col" class="pf-v6-c-table__th">Target and result</th>
          <th scope="col" class="pf-v6-c-table__th">Coverage</th>
          <th scope="col" class="pf-v6-c-table__th">Measurements</th>
        </tr>
      </thead>
      <tbody class="pf-v6-c-table__tbody">
        <tr
          :for={scope <- @items}
          class={["pf-v6-c-table__tr", scope["id"] == @selected_id && "preview-selected"]}
          data-overview-row
        >
          <td class="pf-v6-c-table__td">
            <div class="preview-identity">
              <.link
                id={"open-coverage-" <> scope["id"]}
                patch={@open.(scope["id"])}
                class="preview-result-link"
                data-overview-open
              >{target_label(scope["target"])} <span>{title(scope)}</span></.link>
              <p class="preview-caption preview-result-context">
                {environment(scope)} · {scope["source_id"]}
              </p>
            </div>
          </td>
          <td class="pf-v6-c-table__td"><.status value={scope["status"]} /></td>
          <td class="pf-v6-c-table__td">{measurement_count(scope)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  def runner_diagnostics(assigns) do
    ~H"""
    <details
      :if={(@listing["unfiltered_total"] || @listing["total"]) > 0}
      id="preview-coverage-runner-diagnostics"
      open={@selected_id != nil}
      class="preview-table-group preview-coverage-diagnostics"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-coverage-disclosure">
        Runner diagnostics
        <span class="pf-v6-c-badge pf-m-read">
          {@listing["total"]} {if @listing["total"] == 1, do: "entry", else: "entries"}
        </span>
      </summary>
      <p class="preview-coverage-intro">
        Check these entries if you expected the runner to perform the check.
      </p>
      <p :if={@listing["total"] == 0} class="preview-empty">
        No runner diagnostics match these filters.
      </p>
      <table
        :if={@listing["items"] != []}
        class="pf-v6-c-table preview-table preview-coverage-diagnostic-table"
        aria-label="Runner diagnostics"
      >
        <thead class="pf-v6-c-table__thead">
          <tr class="pf-v6-c-table__tr">
            <th scope="col" class="pf-v6-c-table__th">Check</th>
            <th scope="col" class="pf-v6-c-table__th">Runner</th>
            <th scope="col" class="pf-v6-c-table__th">Reason</th>
          </tr>
        </thead>
        <tbody class="pf-v6-c-table__tbody">
          <tr
            :for={item <- @listing["items"]}
            class={["pf-v6-c-table__tr", to_string(item["id"]) == @selected_id && "preview-selected"]}
            data-overview-row
          >
            <th scope="row" class="pf-v6-c-table__td">
              <.link
                id={"open-diagnostic-#{item["id"]}"}
                patch={@open.(to_string(item["id"]))}
                class="preview-result-link"
                data-overview-open
              >{title(item)}</.link>
            </th>
            <td class="pf-v6-c-table__td">
              <.link patch={@runner_path.(item["runner_id"])}>{item["runner_label"] || "Runner"}</.link>
            </td>
            <td class="pf-v6-c-table__td">{diagnostic_reason(item)}</td>
          </tr>
        </tbody>
      </table>
      <MondekWeb.PreviewPagination.pagination
        page={@listing["page"]}
        size={@listing["page_size"]}
        total={@listing["total"]}
        label="Runner diagnostic pages"
        url={@page_path}
      />
    </details>
    """
  end

  def diagnostic_detail(assigns) do
    ~H"""
    <header class="preview-incident-intro">
      <p class="preview-caption">Runner diagnostic</p>
      <PreviewDetail.heading level={if @full_page, do: 1, else: 2} id={@heading_id}>
        {title(@item)}
      </PreviewDetail.heading>
      <p>{@item["runner_label"] || "Runner"}</p>
    </header>
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-diagnostic-facts"}
      title="Why this check is unresolved"
    >
      <PreviewDetail.facts label="Diagnostic details">
        <tr>
          <th scope="row">Reason</th><td>{diagnostic_reason(@item)}</td>
        </tr>
        <tr :if={@item["exclusion_reason"]}>
          <th scope="row">Placement</th><td>{@item["exclusion_reason"]}</td>
        </tr>
        <tr>
          <th scope="row">Source</th><td>{@item["source_id"]}</td>
        </tr>
        <tr :if={!@item["audit_confirmed"]}>
          <th scope="row">Declaration</th><td>
            The runner’s latest inventory did not confirm this declaration.
          </td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link patch={@runner_path.(@item["runner_id"])}>Inspect runner setup</.link>
      </div>
    </PreviewDetail.card>
    <details
      id={@id_prefix <> "preview-diagnostic-identity"}
      class="preview-table-group preview-incident-section"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-section-heading">Declaration identity</summary>
      <PreviewDetail.facts label="Declaration identity">
        <tr :if={get_in(@item, ["runner_context", "local_environment"])}>
          <th scope="row">Execution environment</th><td>
            {get_in(@item, ["runner_context", "local_environment"])}
          </td>
        </tr>
        <tr>
          <th scope="row">Declaration</th><td><code>{@item["id"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Check key</th><td><code>{@item["source_key"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Result key</th><td><code>{@item["result_key"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Monitored environment</th><td>
            {@item["environment_label"] || @item["environment"] || "Not declared"}
          </td>
        </tr>
        <tr>
          <th scope="row">Target</th><td>
            {if @item["target"], do: target_label(@item["target"]), else: "Not declared"}
          </td>
        </tr>
        <tr>
          <th scope="row">Runner</th><td><code>{@item["runner_id"]}</code></td>
        </tr>
      </PreviewDetail.facts>
    </details>
    """
  end

  defp diagnostic_reason(%{
         "scope_reason" =>
           "The excluded check inherits a monitored environment or target that this deployment does not declare."
       }),
       do: "This runner has no target or monitored environment assigned for this check."

  defp diagnostic_reason(item),
    do: item["scope_reason"] || "This check could not be matched to a target and environment."

  def detail(assigns) do
    ~H"""
    <header class="preview-incident-intro">
      <p class="preview-caption">Declared result</p>
      <PreviewDetail.heading level={if @full_page, do: 1, else: 2} id={@heading_id}>
        {target_label(@scope["target"])}
      </PreviewDetail.heading>
      <p>{title(@scope)} · {environment(@scope)}</p>
    </header>
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-coverage-facts"}
      title="Coverage status"
    >
      <PreviewDetail.facts label="Coverage">
        <tr>
          <th scope="row">State</th>
          <td><.status value={@scope["status"]} /> <span>{explanation(@scope["status"])}</span></td>
        </tr>
        <tr>
          <th scope="row">Measurements</th><td>{measurement_count(@scope)}</td>
        </tr>
        <tr :if={@scope["counts"]["unconfirmed"] > 0}>
          <th scope="row">Unconfirmed</th><td>
            {@scope["counts"]["unconfirmed"]} of {@scope["counts"]["declaring"]} runner declarations
          </td>
        </tr>
        <tr>
          <th scope="row">Source</th><td>{@scope["source_id"]}</td>
        </tr>
        <tr :if={
          Enum.any?(~w(code_variants runtime_variants definition_variants), &((@scope[&1] || 0) > 1))
        }>
          <th scope="row">Versions</th><td>
            Runners declare different versions. Each measurement is checked against that runner’s own configuration.
          </td>
        </tr>
      </PreviewDetail.facts>
    </PreviewDetail.card>
    <section class="preview-table-group preview-incident-section">
      <.dynamic_tag tag_name={if @full_page, do: "h2", else: "h3"} class="preview-section-heading">
        Runner decisions <span class="pf-v6-c-badge pf-m-read">{@observers["total"]}</span>
      </.dynamic_tag>
      <table
        class="preview-incident-fact-table preview-coverage-runners"
        aria-label="Runner decisions"
      >
        <thead>
          <tr>
            <th scope="col">Runner</th><th scope="col">What happened</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={observer <- @observers["items"]}>
            <th scope="row">
              <.link patch={@runner_path.(observer["runner_id"])}>{observer["runner_label"] ||
                "Runner"}</.link>
            </th>
            <td>
              <strong>{runner_state(observer["measurement_state"])}</strong>
              <p :if={observer["measurement_state"] == "excluded" && observer["exclusion_reason"]}>
                {observer["exclusion_reason"]}
              </p>
              <p :if={observer["older_version"]} class="preview-caption">
                The last measurement came from an earlier configuration.
              </p>
              <p :if={observer["measurement_state"] == "fresh"} class="preview-caption">
                Measured {time(get_in(observer, ["current", "source_at"]))}
              </p>
              <.link :if={observer["stream_id"]} patch={@result_path.(observer["stream_id"])}>View check result</.link>
              <details
                id={@id_prefix <> "preview-observer-identity-" <> to_string(observer["id"])}
                phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
              >
                <summary>Declaration and measurement identity</summary>
                <PreviewDetail.facts label="Observer identity">
                  <tr :if={get_in(observer, ["runner_context", "local_environment"])}>
                    <th scope="row">Execution environment</th><td>
                      {get_in(observer, ["runner_context", "local_environment"])}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Runner</th><td><code>{observer["runner_id"]}</code></td>
                  </tr>
                  <tr>
                    <th scope="row">Declared code</th><td>
                      <code>{observer["code_revision"] || "Not reported"}</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Runtime</th><td>
                      <code>{observer["runtime_revision"] || "Not reported"}</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Desired configuration</th><td>
                      {observer["desired_generation"] || "Not assigned"}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Measured configuration</th><td>
                      {get_in(observer, ["current", "generation"]) || "Not measured"}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Source declaration</th><td>
                      <.link navigate={"/coverage/publishers/" <> to_string(observer["source_inventory_id"]) <> "?" <> URI.encode_query(%{"return_to" => @current})}>Review source declaration</.link>
                    </td>
                  </tr>
                </PreviewDetail.facts>
              </details>
            </td>
          </tr>
        </tbody>
      </table>
      <MondekWeb.PreviewPagination.pagination
        page={@observers["page"]}
        size={@observers["page_size"]}
        total={@observers["total"]}
        label="Runner decision pages"
        url={@page_path}
      />
    </section>
    <details
      id={@id_prefix <> "preview-coverage-identity"}
      class="preview-table-group preview-incident-section"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-section-heading">Declaration identity</summary>
      <PreviewDetail.facts label="Declared-result identity">
        <tr>
          <th scope="row">Scope</th><td><code>{@scope["id"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Check key</th><td><code>{@scope["source_key"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Result key</th><td><code>{@scope["result_key"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Monitored environment</th><td>
            <code>{@scope["environment"] || "Not declared"}</code>
          </td>
        </tr>
        <tr>
          <th scope="row">Target kind</th><td><code>{@scope["target"]["kind"]}</code></td>
        </tr>
        <tr>
          <th scope="row">Target key</th><td><code>{@scope["target"]["key"]}</code></td>
        </tr>
      </PreviewDetail.facts>
    </details>
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "coverage-investigation-help"}
      title="Investigation help"
    >
      <div class="preview-incident-evidence">
        <MondekWeb.AgentPrompts.prompt
          id={@id_prefix <> "coverage-agent-prompts-coverage"}
          kind={:coverage}
          context={
            %{
              "controller_url" => MondekWeb.Endpoint.url(),
              "source_id" => @scope["source_id"],
              "check_key" => @scope["source_key"],
              "result_key" => @scope["result_key"],
              "target_id" => @scope["target"]["key"],
              "target_kind" => @scope["target"]["kind"],
              "monitored_environment" => @scope["environment"]
            }
          }
        />
      </div>
    </PreviewDetail.card>
    """
  end

  defp status(assigns) do
    ~H"""
    <span class={["pf-v6-c-label", tone(@value)]}><span class="pf-v6-c-label__content">{label(@value)}</span></span>
    """
  end

  defp tone("observed"), do: "pf-m-green"
  defp tone("missing"), do: "pf-m-red"
  defp tone(_), do: "pf-m-orange"

  defp label("missing"), do: "No runner selected"
  defp label("observed"), do: "Reporting"
  defp label("partial"), do: "Partial coverage"
  defp label("awaiting"), do: "Waiting for measurement"
  defp label("stale"), do: "Measurements overdue"
  defp label("unavailable"), do: "Collection unavailable"
  defp label("unconfirmed"), do: "Declarations unconfirmed"

  defp explanation("missing"),
    do: "No runner is selected to send measurements. Review the runner decisions below."

  defp explanation("observed"), do: "Every selected runner has a current measurement."

  defp explanation("partial"),
    do: "Some coverage is confirmed. Review the runner decisions below for the remaining gaps."

  defp explanation("awaiting"),
    do:
      "At least one selected runner is still waiting to report a measurement for the current configuration."

  defp explanation("stale"), do: "Selected runners have no measurement current enough to count."

  defp explanation("unavailable"),
    do: "Collection failed and no selected runner has a current measurement."

  defp explanation("unconfirmed"),
    do: "The latest runner inventories do not confirm the retained declarations."

  defp runner_state("excluded"), do: "Not selected"
  defp runner_state("fresh"), do: "Reporting"
  defp runner_state("pending"), do: "Waiting for measurement"
  defp runner_state("unadmitted"), do: "Selected, but no result is registered"
  defp runner_state("stale"), do: "Measurement overdue"
  defp runner_state("unavailable"), do: "Collection unavailable"
  defp runner_state("unconfirmed"), do: "Declaration unconfirmed"

  defp measurement_count(%{"status" => "missing"}), do: "—"

  defp measurement_count(%{"counts" => %{"selected" => 0}}), do: "Unknown"

  defp measurement_count(%{"counts" => %{"selected" => selected, "fresh" => fresh}}),
    do:
      "#{fresh} of #{selected} selected #{if selected == 1, do: "runner", else: "runners"} reporting"

  def environment(scope), do: scope["environment_label"] || scope["environment"] || "Unscoped"

  def title(scope) do
    if scope["check_label"] == scope["result_label"],
      do: scope["check_label"],
      else: scope["check_label"] <> " · " <> scope["result_label"]
  end
end
