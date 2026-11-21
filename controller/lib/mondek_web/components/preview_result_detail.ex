# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewResultDetail do
  use MondekWeb, :html
  import MondekWeb.CheckDetails, only: [check_details: 1]
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias MondekWeb.PreviewDetail

  attr :panel, :map, required: true
  attr :now, :any, required: true
  attr :execution_path, :any, default: nil
  attr :diagnostic_runner, :any, default: nil
  attr :diagnostics_open, :boolean, default: false
  attr :current, :string, default: ""
  attr :configuration_path, :string, required: true
  attr :discovery_path, :string, default: nil
  attr :discovery_settings_path, :string, default: nil
  attr :discovery_settings_patch, :boolean, default: false
  attr :discovery_patch, :boolean, default: false
  attr :configuration_patch, :boolean, default: false
  attr :incident_path, :any, required: true
  attr :peer_path, :any, required: true
  attr :runner_path, :any, default: nil
  attr :full_result_path, :string, default: nil
  attr :full_result_patch, :boolean, default: false
  attr :full_page, :boolean, default: false
  attr :heading_id, :string, default: "overview-panel-title"
  attr :id_prefix, :string, default: ""

  def detail(assigns) do
    history = result_history(assigns.panel)
    current = assigns.panel.inspection["stream"]["current"] || %{}

    confirmed =
      Enum.find(
        assigns.panel.inspection["evidence"] || [],
        &(&1["id"] == current["confirmed_observation_id"])
      )

    assigns =
      assigns
      |> assign(:result, assigns.panel.selected)
      |> assign(:history, history)
      |> assign(:measurement, current)
      |> assign(:confirmed_report, confirmed || %{})
      |> assign(:confirmed_configuration, assigns.panel[:confirmed_configuration])
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
      level={if @full_page, do: 2, else: 3}
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
        <tr :if={@result["qualification"]}>
          <th scope="row">Qualified health</th>
          <td id={@id_prefix <> "result-qualified-health"}>
            <.state
              :if={@result["qualification"]["effective_health"]}
              value={@result["qualification"]["effective_health"]}
            />
            <span :if={!@result["qualification"]["effective_health"]}>Awaiting qualification</span>
            <span :if={@result["qualification"]["effective_observation_id"]} class="preview-caption">
              Supporting observation {@result["qualification"]["effective_observation_id"]}
            </span>
          </td>
        </tr>
        <tr :for={pending <- get_in(@result, ["qualification", "pending"]) || []}>
          <th scope="row">Pending sustain</th>
          <td data-sustain-severity={pending["health"]}>
            {state_text(pending["health"])} · {@result["qualification"]["duration_seconds"]} s
            · since <time datetime={pending["started_at"]}>{time(pending["started_at"])}</time>
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
        <tr :if={get_in(@result, ["current", "deferral"])} data-output-deferral>
          <th scope="row">Deferred evaluation</th>
          <td>
            {@result["current"]["deferral"]["reason"]}
            <span class="preview-caption">
              Owner check {@result["current"]["deferral"]["check_key"]} · output {@result[
                "current"
              ]["deferral"]["output_key"]}
            </span>
          </td>
        </tr>
        <tr :if={
          get_in(@result, ["current", "knowledge"]) == "unavailable" &&
            !get_in(@result, ["current", "deferral"])
        }>
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
    <details
      id={@id_prefix <> "result-measurement-provenance"}
      class="preview-table-group"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-section-heading">Measurement timing &amp; configuration</summary>
      <PreviewDetail.facts label="Result identity">
        <tr>
          <th scope="row">Result key</th><td>{@result["result_key"]}</td>
        </tr>
        <tr>
          <th scope="row">Result ID</th><td>{@result["id"]}</td>
        </tr>
        <tr>
          <th scope="row">Target kind / key</th><td>
            {get_in(@result, ["target", "kind"])} / {get_in(@result, ["target", "key"])}
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={!confirmed?(@result)} class="preview-empty">
        No confirmed measurement is recorded for this result.
      </p>
      <PreviewDetail.facts :if={confirmed?(@result)} label="Confirmed result provenance">
        <tr>
          <th scope="row">Confirmed configuration version</th><td>
            {@measurement["confirmed_generation"]}
          </td>
        </tr>
        <tr>
          <th scope="row">Source time</th><td>{time(@measurement["source_at"])}</td>
        </tr>
        <tr>
          <th scope="row">Evaluated</th><td>{time(@measurement["confirmed_evaluated_at"])}</td>
        </tr>
        <tr>
          <th scope="row">Received</th><td>{time(@confirmed_report["received_at"])}</td>
        </tr>
        <tr>
          <th scope="row">Observation ID</th><td>{@measurement["confirmed_observation_id"]}</td>
        </tr>
        <tr>
          <th scope="row">Runner session</th><td>{@measurement["confirmed_session_id"]}</td>
        </tr>
        <tr>
          <th scope="row">Current freshness limit</th><td>
            {MondekWeb.Duration.format_seconds(@panel.inspection["assignment"]["freshness_seconds"])}
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={confirmed?(@result) && !@confirmed_configuration} class="preview-caption">
        The configuration for this result's confirmed measurement is no longer retained.
      </p>
      <%= if @confirmed_configuration do %>
        <.dynamic_tag tag_name={if @full_page, do: "h3", else: "h4"} class="preview-section-heading">
          Last measured result parameters
        </.dynamic_tag>
        <PreviewDetail.facts label="Last measured result parameters">
          <tr :for={{key, value} <- Enum.sort(@confirmed_configuration["params"] || %{})}>
            <th scope="row">
              {MondekWeb.ParameterForm.field_label(
                get_in(@confirmed_configuration, ["definition", "parameter_schema"]) || %{},
                key
              )} <span class="preview-caption">({key})</span>
            </th>
            <td>
              {parameter_value(value)}<span :if={
                get_in(@confirmed_configuration, [
                  "definition",
                  "parameter_schema",
                  "fields",
                  key,
                  "unit"
                ])
              }>{" " <>
                get_in(@confirmed_configuration, [
                  "definition",
                  "parameter_schema",
                  "fields",
                  key,
                  "unit"
                ])}</span>
            </td>
          </tr>
        </PreviewDetail.facts>
        <p :if={@confirmed_configuration["params"] in [nil, %{}]} class="preview-empty">
          No parameter values recorded.
        </p>
      <% end %>
      <p class="preview-caption">
        These versions and times belong to this result's confirmed measurement. Sibling results can retain different evidence; saving settings and receiving later reports do not refresh it.
      </p>
    </details>
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-result-collection"}
      class="preview-result-source"
      title="Collection"
    >
      <PreviewDetail.facts label="Collection">
        <tr>
          <th scope="row">Runner</th><td>
            <.link
              :if={@runner_path && @result["runner_id"]}
              patch={@runner_path.(@result["runner_id"])}
            >{@result["runner_label"] || "Unnamed runner"}</.link><span :if={
              !@runner_path || !@result["runner_id"]
            }>{@result["runner_label"] || "Runner not recorded"}</span>
          </td>
        </tr>
        <tr>
          <th scope="row">Source</th><td title={@result["source_key"]}>{@result["source_id"]}</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link
          patch={if @configuration_patch, do: @configuration_path}
          href={if !@configuration_patch, do: @configuration_path}
        >
          View check configuration
        </.link>
        <.link :if={@execution_path} patch={@execution_path.(@result["assignment_id"])}>Shared execution and history</.link>
      </div>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={@panel[:discovery_settings] && @discovery_settings_path}
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "resource-discovery-settings"}
      title="Resource discovery"
    >
      <PreviewDetail.facts label="Resource discovery settings">
        <tr>
          <th scope="row">Membership</th><td>
            {case get_in(@panel.inspection, ["assignment", "discovery", "origin"]) do
              "required" ->
                "Required by code; discovery exclusions cannot remove this resource."

              "discovered" ->
                "Automatically discovered; exclusions change future selection and do not report recovery."

              _ ->
                "Discovery manager"
            end}
          </td>
        </tr>
        <tr>
          <th scope="row">Discovery check</th><td>{@panel.discovery_settings.manager["label"]}</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link
          patch={if @discovery_settings_patch, do: @discovery_settings_path}
          navigate={if !@discovery_settings_patch, do: @discovery_settings_path}
        >Configure resource discovery</.link>
      </div>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={@panel[:discovery] && @discovery_path}
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-result-discovery"}
      title="Discovered resources"
    >
      <PreviewDetail.facts label="Discovery evidence">
        <tr>
          <th scope="row">Discovery</th><td>{@panel.discovery["discovery"]["title"]}</td>
        </tr>
        <tr>
          <th scope="row">Candidates</th><td>
            {length(@panel.discovery["discovery"]["candidates"])}
          </td>
        </tr>
        <tr :if={@panel.discovery["reason"]}>
          <th scope="row">Review availability</th><td>{@panel.discovery["reason"]}</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link
          navigate={if !@discovery_patch, do: @discovery_path}
          patch={if @discovery_patch, do: @discovery_path}
          id={@id_prefix <> "result-discovery-review"}
        >{if @panel.discovery["reviewable"],
          do: "Review discovered resources",
          else: "Inspect recorded discovery"}</.link>
      </div>
    </PreviewDetail.card>
    <details
      :if={@execution_path}
      id={@id_prefix <> "result-collection-diagnostics"}
      class="preview-table-group result-diagnostic-disclosure"
      open={
        @diagnostics_open ||
          get_in(@result, ["current", "knowledge"]) in ["unavailable", "stale", "awaiting"]
      }
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="preview-section-heading">Collection diagnostics</summary>
      <MondekWeb.CollectionDiagnostics.body
        full_page={@full_page}
        inspection={@panel.inspection}
        runner={@diagnostic_runner}
        now={@now}
        id_prefix={@id_prefix}
        runner_path={@runner_path}
        configuration_path={@configuration_path}
        configuration_patch={@configuration_patch}
        current={@current}
      />
    </details>
    <PreviewDetail.card
      :if={@history != [] || @result["predecessor_stream_id"]}
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-result-history"}
      title="Measurement history"
    >
      <div :if={@result["predecessor_stream_id"]} class="preview-recorded-actions">
        <.link navigate={"/results/" <> @result["predecessor_stream_id"] <> "/full"}>
          View preceding result stream
        </.link>
      </div>
      <.measurement_rows :if={@history != []} rows={@visible_history} label="Previous measurements" />
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
          <.link
            patch={if @full_result_patch, do: @full_result_path}
            navigate={if !@full_result_patch, do: @full_result_path}
          >View more measurements</.link>
        </div>
      </details>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={Enum.any?(@panel.inspection["incidents"], &(&1["status"] == "open"))}
      level={if @full_page, do: 2, else: 3}
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
    <MondekWeb.PreviewMaintenanceSummary.body
      full_page={@full_page}
      assignment={@panel.inspection["assignment"]}
      stream={@panel.inspection["stream"]}
      windows={@panel[:maintenance_windows] || []}
      current={@current}
      id={@id_prefix <> "result-maintenance"}
    />
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
        Showing {length(@panel.items) - 1} of {@panel.total - 1} other results. <a href="/checks">Browse all results</a>.
      </p>
    </details>
    """
  end

  defp parameter_value(value) when is_binary(value), do: value
  defp parameter_value(value), do: Jason.encode!(value)

  defp result_history(panel) do
    current = get_in(panel.selected, ["current", "confirmed_observation_id"])

    for measurement <- panel.inspection["measurement_history"] || [],
        measurement["observation_id"] != current do
      %{
        at: measurement["source_at"] || measurement["evaluated_at"],
        received_at: measurement["received_at"],
        generation: measurement["generation"],
        stream_id: measurement["stream_id"],
        health: measurement["health"],
        summary: measurement["summary"],
        predecessor?: measurement["stream_id"] != panel.selected["id"],
        historical?: measurement["disposition"] == "historical"
      }
    end
  end

  attr(:value, :any, required: true)

  def state(assigns) do
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
        <th scope="row">
          Received <time datetime={measurement.received_at}>{time(measurement.received_at)}</time>
          <small :if={measurement.at != measurement.received_at}>
            Measurement time <time datetime={measurement.at}>{time(measurement.at)}</time>
          </small>
        </th>
        <td>
          <.state value={measurement.health} /> {measurement.summary}
          <.link
            :if={measurement.predecessor?}
            navigate={"/results/" <> measurement.stream_id <> "/full"}
          >Previous stream · Generation {measurement.generation}</.link>
          <small :if={!measurement.predecessor?}>Generation {measurement.generation}</small>
          <small :if={measurement.historical?}>Historical receipt</small>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end
end
