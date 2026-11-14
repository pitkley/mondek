# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewResultDetail do
  use MondekWeb, :html
  import MondekWeb.CheckDetails, only: [check_details: 1]
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias MondekWeb.PreviewDetail

  attr :panel, :map, required: true
  attr :now, :any, required: true
  attr :configuration_path, :string, required: true
  attr :incident_path, :any, required: true
  attr :peer_path, :any, required: true
  attr :full_result_path, :string, default: nil
  attr :full_page, :boolean, default: false
  attr :heading_id, :string, default: "overview-panel-title"
  attr :id_prefix, :string, default: ""

  def detail(assigns) do
    history = result_history(assigns.panel)

    assigns =
      assigns
      |> assign(:result, assigns.panel.selected)
      |> assign(:history, history)
      |> assign(
        :visible_history,
        if(assigns[:full_page], do: history, else: Enum.take(history, 4))
      )

    ~H"""
    <header class="preview-incident-intro">
      <p class="preview-caption">Check result</p>
      <PreviewDetail.heading level={if @full_page, do: 1, else: 2} id={@heading_id}>
        {result_title(@result)}
      </PreviewDetail.heading>
      <p>
        {target_label(@result["target"])} · {@result["environment_label"] || @result["environment"] ||
          "Unscoped"}
      </p>
      <p :if={@result["retired"]} class="preview-caption">
        This result is retired. Its last measurement is historical.
      </p>
    </header>
    <PreviewDetail.card
      id={@id_prefix <> "observer-" <> @result["id"]}
      class="preview-result-measurement"
      title="Latest measurement"
    >
      <PreviewDetail.facts label="Latest measurement">
        <tr>
          <th scope="row">Status</th>
          <td>
            <div class="preview-evidence-state">
              <.state value={measured_health(@result)} />
              <.state value={get_in(@result, ["current", "knowledge"])} />
            </div>
          </td>
        </tr>
        <tr>
          <th scope="row">Finding</th><td>{summary(@result)}</td>
        </tr>
        <tr :if={confirmed?(@result)}>
          <th scope="row">Measured at</th>
          <td>
            <time datetime={@result["current"]["source_at"]}>{time(@result["current"]["source_at"])}</time>
            · {age(@result["current"]["source_at"], @now)}
          </td>
        </tr>
        <tr :if={get_in(@result, ["current", "knowledge"]) == "unavailable"}>
          <th scope="row">Latest collection</th>
          <td>
            {MondekWeb.MonitoringUI.collection_diagnostic(@result["current"]) ||
              "Collection failed. The last confirmed measurement is retained."}
          </td>
        </tr>
        <tr :if={confirmed?(@result) && @result["current"]["details"] not in [nil, ""]}>
          <th scope="row">Check details</th>
          <td><.check_details text={@result["current"]["details"]} /></td>
        </tr>
      </PreviewDetail.facts>
    </PreviewDetail.card>
    <PreviewDetail.card
      id={@id_prefix <> "preview-result-collection"}
      class="preview-result-source"
      title="Collection"
    >
      <PreviewDetail.facts label="Collection">
        <tr>
          <th scope="row">Runner</th><td>{@result["runner_label"] || "Runner not recorded"}</td>
        </tr>
        <tr>
          <th scope="row">Source</th><td title={@result["source_key"]}>{@result["source_id"]}</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link href={@configuration_path}>
          View check configuration
        </.link>
      </div>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={@history != []}
      id={@id_prefix <> "preview-result-history"}
      title="Measurement history"
    >
      <.measurement_rows rows={@visible_history} label="Previous measurements" />
      <details
        :if={length(@visible_history) < length(@history)}
        id={@id_prefix <> "preview-more-measurements-" <> @result["id"]}
        class="preview-incident-history"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary class="preview-section-heading">More measurements</summary>
        <.measurement_rows
          rows={Enum.drop(@history, length(@visible_history))}
          label="Older measurements"
        />
        <div class="preview-recorded-actions">
          <.link navigate={@full_result_path}>View more measurements</.link>
        </div>
      </details>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={Enum.any?(@panel.inspection["incidents"], &(&1["status"] == "open"))}
      id={@id_prefix <> "preview-result-incidents"}
      title="Open incidents"
    >
      <PreviewDetail.facts label="Open incidents">
        <tr :for={incident <- Enum.filter(@panel.inspection["incidents"], &(&1["status"] == "open"))}>
          <th scope="row">{time(incident["opened_at"])}</th>
          <td>
            <.state value={incident["health"]} />
            <.link patch={@incident_path.(incident["condition_incident_id"] || incident["id"])}>
              {if incident["condition_incident_id"],
                do: "View shared incident",
                else: "View incident"}
            </.link>
          </td>
        </tr>
      </PreviewDetail.facts>
    </PreviewDetail.card>
    <details
      :if={@panel.total > 1}
      id={@id_prefix <> "preview-related-results"}
      class="preview-table-group preview-incident-section preview-incident-history"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-section-heading">
        Related results for this scope ({@panel.total - 1})
      </summary>
      <PreviewDetail.facts label="Related results">
        <tr :for={peer <- Enum.reject(@panel.items, &(&1["id"] == @result["id"]))}>
          <th scope="row">
            <.link patch={@peer_path.(peer["id"])}>{peer["runner_label"] || "Runner"} · {String.slice(
              peer["runner_id"] || "",
              0,
              8
            )}</.link>
          </th>
          <td>
            <.state value={measured_health(peer)} />
            <.state value={get_in(peer, ["current", "knowledge"])} />
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={@panel.total > length(@panel.items)} class="preview-recorded-actions preview-caption">
        Showing {length(@panel.items) - 1} of {@panel.total - 1} other results. <a href="/next/checks">Browse all results</a>.
      </p>
    </details>
    """
  end

  defp result_history(panel) do
    current = get_in(panel.selected, ["current", "confirmed_observation_id"])

    for observation <- panel.inspection["evidence"] || [],
        observation["id"] != current,
        result <- get_in(observation, ["payload", "results"]) || [],
        result["key"] == panel.selected["result_key"] do
      %{
        at: result["source_at"] || observation["evaluated_at"],
        health: result["health"],
        summary: result["summary"]
      }
    end
  end

  attr(:value, :any, required: true)

  defp state(assigns) do
    assigns = assign(assigns, text: state_text(assigns.value), tone: state_tone(assigns.value))

    ~H"""
    <span class={["pf-v6-c-label", @tone]}><span class="pf-v6-c-label__content">{@text}</span></span>
    """
  end

  defp confirmed?(row), do: get_in(row, ["current", "confirmed_observation_id"]) != nil

  defp measured_health(row),
    do: if(confirmed?(row), do: row["current"]["health"], else: "not_measured")

  defp summary(row),
    do: if(confirmed?(row), do: row["current"]["summary"], else: "No confirmed measurement yet.")

  defp result_title(row),
    do:
      if(row["label"] == row["check_label"],
        do: row["label"],
        else: row["check_label"] <> " · " <> row["label"]
      )

  defp state_text("fresh"), do: "Fresh"
  defp state_text("stale"), do: "Overdue measurement"
  defp state_text("unavailable"), do: "Collection unavailable"
  defp state_text("awaiting"), do: "Awaiting measurement"
  defp state_text("missing"), do: "No selected runner"
  defp state_text(value), do: badge_text(value)
  defp state_tone(value) when value in ["CRIT", "unavailable"], do: "pf-m-red"
  defp state_tone(value) when value in ["WARN", "stale", "missing", "awaiting"], do: "pf-m-orange"
  defp state_tone("OK"), do: "pf-m-green"
  defp state_tone(_), do: ""

  defp measurement_rows(assigns) do
    ~H"""
    <PreviewDetail.facts label={@label} class="preview-result-history">
      <tr :for={measurement <- @rows}>
        <th scope="row"><time datetime={measurement.at}>{time(measurement.at)}</time></th>
        <td><.state value={measurement.health} /> {measurement.summary}</td>
      </tr>
    </PreviewDetail.facts>
    """
  end
end
