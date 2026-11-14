# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewCoverage do
  use MondekWeb, :html

  alias MondekWeb.PreviewDetail

  import MondekWeb.EvidencePresentation, only: [target_label: 1, time: 1]

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
      :if={@listing["total"] > 0}
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
      <table
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
              <a href={MondekWeb.RunnerNavigation.detail_path(item["runner_id"])}>{item[
                "runner_label"
              ] || "Runner"}</a>
            </td>
            <td class="pf-v6-c-table__td">{diagnostic_reason(item)}</td>
          </tr>
        </tbody>
      </table>
      <div :if={length(@listing["items"]) < @listing["total"]} class="preview-coverage-audit">
        <a href="/coverage/diagnostics">See all {@listing["total"]} entries</a>
      </div>
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
    <PreviewDetail.card id="preview-diagnostic-facts" title="Why this check is unresolved">
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
        <a href={MondekWeb.RunnerNavigation.detail_path(@item["runner_id"])}>Inspect runner setup</a>
      </div>
    </PreviewDetail.card>
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
    <PreviewDetail.card id="preview-coverage-facts" title="Coverage">
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
      </PreviewDetail.facts>
    </PreviewDetail.card>
    <section class="preview-table-group preview-incident-section">
      <h3 class="preview-section-heading">
        Runner decisions <span class="pf-v6-c-badge pf-m-read">{@observers["total"]}</span>
      </h3>
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
            <th scope="row">{observer["runner_label"] || "Runner"}</th>
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
