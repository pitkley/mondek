# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ExecutionDetail do
  @moduledoc "One scheduled execution with independent result evidence, shared configuration and recorded history."
  use MondekWeb, :html
  alias Phoenix.LiveView.JS

  alias MondekWeb.{
    CheckDetails,
    CollectionDiagnostics,
    EvidencePresentation,
    ParameterForm,
    PreviewDetail,
    PreviewResultDetail
  }

  attr :inspection, :any, required: true
  attr :runner, :any, required: true
  attr :windows, :list, default: []
  attr :now, :any, required: true
  attr :full_page, :boolean, default: false
  attr :id_prefix, :string, default: ""
  attr :current, :string, required: true
  attr :result_path, :any, required: true
  attr :incident_path, :any, required: true
  attr :runner_path, :any, required: true
  attr :configuration_path, :string, required: true
  attr :configuration_patch, :boolean, default: false

  def body(assigns) do
    assignment = (assigns.inspection || %{})["assignment"]

    assigns =
      assign(assigns,
        assignment: assignment,
        confirmed_configuration: (assigns.inspection || %{})["confirmed_configuration"],
        current_evidence: (assignment || %{})["current"] || %{},
        streams: (assignment || %{})["streams"] || [],
        history_size: if(assigns.full_page, do: 100, else: 4)
      )

    ~H"""
    <div data-execution-body>
      <PreviewDetail.heading
        level={if @full_page, do: 1, else: 2}
        id={@id_prefix <> if(@full_page, do: "execution-heading", else: "overview-panel-title")}
      >
        {if @assignment,
          do: @assignment["label"] || @assignment["kind"],
          else: "Scheduled execution not found"}
      </PreviewDetail.heading>
      <p :if={!@assignment} class="preview-empty">This scheduled check is not in retained history.</p>
      <%= if @assignment do %>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-scope"}
          title="Scheduled execution"
        >
          <PreviewDetail.facts label="Scheduled execution identity">
            <tr>
              <th scope="row">Source</th><td>
                {@assignment["source_id"] || "Not recorded"} · {@assignment["source_key"] ||
                  @assignment["kind"]}
              </td>
            </tr>
            <tr>
              <th scope="row">Environment</th><td>
                {@assignment["environment_label"] || @assignment["environment"] || "Not declared"}
              </td>
            </tr>
            <tr>
              <th scope="row">Runner</th><td>
                <.link :if={@assignment["runner_id"]} patch={@runner_path.(@assignment["runner_id"])}>{@assignment[
                  "runner_label"
                ] || @assignment["runner_id"]}</.link><span :if={!@assignment["runner_id"]}>Not assigned</span>
              </td>
            </tr>
            <tr>
              <th scope="row">Membership</th><td>
                {if @assignment["retired_at"],
                  do: "Retired · historical evidence; retirement is not recovery",
                  else: "Active scheduled check"}
              </td>
            </tr>
            <tr>
              <th scope="row">Timing</th><td>
                Every {MondekWeb.Duration.format_seconds(@assignment["interval_seconds"])} · timeout {MondekWeb.Duration.format_seconds(
                  @assignment["timeout_seconds"]
                )} · freshness {MondekWeb.Duration.format_seconds(@assignment["freshness_seconds"])}
              </td>
            </tr>
          </PreviewDetail.facts>
          <details
            id={@id_prefix <> "execution-provenance"}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="preview-section-heading">Source identity and membership history</summary>
            <PreviewDetail.facts label="Execution source provenance">
              <tr>
                <th scope="row">Scheduled check ID</th><td>{@assignment["id"]}</td>
              </tr>
              <tr>
                <th scope="row">Source revision</th><td>
                  {@assignment["source_revision"] || "Not recorded"}
                </td>
              </tr>
              <tr>
                <th scope="row">Definition revision</th><td>
                  {@assignment["definition_revision"] || "Not recorded"}
                </td>
              </tr>
              <tr>
                <th scope="row">Parameter ownership</th><td>
                  {if @assignment["params_owner"] == "ui",
                    do: "Delegated to operator",
                    else: "Source owned"}
                </td>
              </tr>
              <tr :if={@assignment["retired_at"]}>
                <th scope="row">Retired</th><td>
                  {EvidencePresentation.time(@assignment["retired_at"])}
                </td>
              </tr>
              <tr :if={@assignment["retired_at"]}>
                <th scope="row">Retirement reason</th><td>
                  {@assignment["retirement_reason"] || "Not recorded"}
                </td>
              </tr>
            </PreviewDetail.facts>
            <p class="collection-note">
              Source removal ends monitoring without establishing recovery. Historical evidence retains its original configuration and timestamps.
            </p>
          </details>
          <div class="execution-summary-actions">
            <.link
              navigate={if !@configuration_patch, do: @configuration_path}
              patch={if @configuration_patch, do: @configuration_path}
            >Configure this scheduled check</.link>
          </div>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-results"}
          title="Independent results"
        >
          <p class="collection-note">
            One execution can report several results. Each keeps its own health, freshness and incident history.
          </p>
          <p :if={@streams == []} class="preview-empty">
            No active results are retained for this execution.
          </p>
          <table
            :if={@streams != []}
            class="pf-v6-c-table pf-m-compact preview-table execution-result-table"
            aria-label="Results from this execution"
          >
            <thead class="pf-v6-c-table__thead">
              <tr>
                <th class="pf-v6-c-table__th" scope="col">Target and result</th><th
                  class="pf-v6-c-table__th"
                  scope="col"
                >
                  Last measured health
                </th><th class="pf-v6-c-table__th" scope="col">Collection</th>
              </tr>
            </thead><tbody>
              <tr :for={stream <- @streams}>
                <td class="pf-v6-c-table__td">
                  <.link patch={@result_path.(stream["id"])} class="preview-result-link">{EvidencePresentation.target_label(
                    stream["target"]
                  )} · {stream["label"] || stream["result_key"]}</.link>
                </td>
                <td class="pf-v6-c-table__td">
                  <PreviewResultDetail.state value={
                    if get_in(stream, ["current", "confirmed_observation_id"]),
                      do: get_in(stream, ["current", "health"]),
                      else: "not_measured"
                  } />
                </td>
                <td class="pf-v6-c-table__td">
                  <PreviewResultDetail.state value={get_in(stream, ["current", "knowledge"])} />
                </td>
              </tr>
            </tbody>
          </table>
          <p class="collection-note">
            Showing up to 16 active results. Retired result histories remain available in Checks.
          </p>
        </PreviewDetail.card>
        <CollectionDiagnostics.body
          full_page={@full_page}
          inspection={@inspection}
          runner={@runner}
          now={@now}
          id_prefix={@id_prefix}
          runner_path={@runner_path}
          configuration_path={@configuration_path}
          configuration_patch={@configuration_patch}
          current={@current}
        />
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-parameters"}
          title="Shared check settings"
        >
          <.parameters
            full_page={@full_page}
            title="Saved parameters"
            params={@assignment["params"] || %{}}
            schema={@assignment["parameter_schema"] || %{}}
          />
          <.parameters
            :if={@confirmed_configuration}
            full_page={@full_page}
            title="Last fully measured execution parameters"
            params={@confirmed_configuration["params"] || %{}}
            schema={get_in(@confirmed_configuration, ["definition", "parameter_schema"]) || %{}}
          />
          <p :if={!@confirmed_configuration} class="collection-note">
            {if @current_evidence["confirmed_generation"],
              do: "The last measured configuration is no longer retained.",
              else: "No measured configuration is recorded."}
          </p>
          <p class="collection-note">
            Saved version {@assignment["desired_generation"]}. Last fully measured execution version {@current_evidence[
              "confirmed_generation"
            ] || "not recorded"}. Saving does not establish adoption or a new measurement.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-incidents"}
          title="Incident history"
        >
          <p :if={@inspection["incidents"] == []} class="preview-empty">
            No health incidents are retained for this execution.
          </p>
          <.incidents
            rows={Enum.take(@inspection["incidents"] || [], @history_size)}
            incident_path={@incident_path}
          />
          <details
            :if={length(@inspection["incidents"] || []) > @history_size}
            id={@id_prefix <> "execution-older-incidents"}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Earlier incidents</summary><.incidents
              rows={Enum.drop(@inspection["incidents"], @history_size)}
              incident_path={@incident_path}
            />
          </details>
          <EvidencePresentation.inspection_limit
            counts={get_in(@inspection, ["limits", "incidents"])}
            label="incidents"
          />
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-history"}
          title="Execution evidence"
        >
          <p class="collection-note">
            Reports in receipt order, including delayed and historical reports. Original source times are preserved.
          </p>
          <p :if={@inspection["evidence"] == []} class="preview-empty">
            No execution evidence is retained.
          </p>
          <.executions
            rows={Enum.take(@inspection["evidence"] || [], @history_size)}
            id_prefix={@id_prefix}
          />
          <details
            :if={length(@inspection["evidence"] || []) > @history_size}
            id={@id_prefix <> "execution-older-evidence"}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Earlier executions</summary><.executions
              rows={Enum.drop(@inspection["evidence"], @history_size)}
              id_prefix={@id_prefix}
            />
          </details>
          <p
            :if={get_in(@inspection, ["limits", "evidence", "missing"]) not in [nil, 0]}
            class="collection-note"
          >
            Some referenced execution evidence is no longer retained.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "execution-controls"}
          title="Operator control history"
        >
          <p :if={@inspection["controls"] == []} class="preview-empty">
            No operator controls are retained.
          </p>
          <.controls
            rows={Enum.take(@inspection["controls"] || [], @history_size)}
            result_path={@result_path}
            incident_path={@incident_path}
          />
          <details
            :if={length(@inspection["controls"] || []) > @history_size}
            id={@id_prefix <> "execution-older-controls"}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Earlier operator controls</summary>
            <.controls
              rows={Enum.drop(@inspection["controls"], @history_size)}
              result_path={@result_path}
              incident_path={@incident_path}
            />
          </details>
          <EvidencePresentation.inspection_limit
            counts={get_in(@inspection, ["limits", "controls"])}
            label="operator controls"
          />
        </PreviewDetail.card>
        <MondekWeb.PreviewMaintenanceSummary.body
          full_page={@full_page}
          assignment={@assignment}
          windows={@windows}
          current={@current}
          id={@id_prefix <> "execution-maintenance"}
        />
      <% end %>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :incident_path, :any, required: true

  defp incidents(assigns) do
    ~H"""
    <PreviewDetail.facts label="Execution incident history">
      <tr :for={incident <- @rows}>
        <th scope="row">{EvidencePresentation.time(incident["opened_at"])}</th><td>
          <PreviewResultDetail.state value={incident["health"]} />
          · {EvidencePresentation.badge_text(incident["status"])} ·
          <.link patch={@incident_path.(incident["condition_incident_id"] || incident["id"])}>View {if incident[
                                                                                                         "condition_incident_id"
                                                                                                       ],
                                                                                                       do:
                                                                                                         "shared incident",
                                                                                                       else:
                                                                                                         "incident"}</.link><span :if={
            incident["closure_reason"]
          }> · {EvidencePresentation.badge_text(incident["closure_reason"])}</span>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  attr :title, :string, required: true
  attr :params, :map, required: true
  attr :schema, :map, required: true

  attr :full_page, :boolean, default: false

  defp parameters(assigns) do
    ~H"""
    <.dynamic_tag tag_name={if @full_page, do: "h3", else: "h4"} class="preview-section-heading">
      {@title}
    </.dynamic_tag>
    <p :if={@params == %{}} class="preview-empty">No parameter values recorded.</p>
    <PreviewDetail.facts label={@title}>
      <tr :for={{key, value} <- Enum.sort(@params)}>
        <th scope="row">
          {ParameterForm.field_label(@schema, key)} <span class="preview-caption">({key})</span>
        </th>
        <td>
          {parameter(value)}<span :if={get_in(@schema, ["fields", key, "unit"])}>{" " <>
            get_in(@schema, ["fields", key, "unit"])}</span>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  attr :rows, :list, required: true
  attr :result_path, :any, required: true
  attr :incident_path, :any, required: true

  defp controls(assigns) do
    ~H"""
    <PreviewDetail.facts label="Execution operator controls">
      <tr :for={control <- @rows}>
        <th scope="row">{EvidencePresentation.time(control["inserted_at"])}</th>
        <td>
          {EvidencePresentation.badge_text(control["kind"])} · {control["reason"] || "No note"}
          <p class="preview-caption">
            By {control["actor"] || "Not recorded"}{MondekWeb.MonitoringUI.control_lifetime(control)}
          </p>
          <p class="preview-caption">
            Scope:
            <.link :if={control["stream_id"]} patch={@result_path.(control["stream_id"])}>Result {control[
              "stream_id"
            ]}</.link>
            <.link
              :if={control["condition_incident_id"] || control["incident_id"]}
              patch={@incident_path.(control["condition_incident_id"] || control["incident_id"])}
            >Incident {control["condition_incident_id"] || control["incident_id"]}</.link>
            <span :if={
              !control["stream_id"] && !control["condition_incident_id"] && !control["incident_id"]
            }>This scheduled check</span>
          </p>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  attr :rows, :list, required: true
  attr :id_prefix, :string, required: true

  defp executions(assigns) do
    ~H"""
    <PreviewDetail.facts label="Recorded executions">
      <tr :for={row <- @rows}>
        <th scope="row">{EvidencePresentation.time(row["received_at"])}</th><td>
          <details
            id={@id_prefix <> "execution-report-" <> row["id"]}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>
              Version {row["generation"]} · {if get_in(row, ["payload", "complete"]),
                do: "Complete report",
                else: "Collection incomplete"} · {if row["disposition"] == "current",
                do: "Accepted as current on receipt",
                else: "Historical report"}
            </summary>
            <p class="collection-note">Evaluated {EvidencePresentation.time(row["evaluated_at"])}</p>
            <p :if={get_in(row, ["payload", "diagnostic"])} class="collection-note">
              {row["payload"]["diagnostic"]}
            </p>
            <div
              :for={result <- get_in(row, ["payload", "results"]) || []}
              class="execution-recorded-result"
            >
              <p class="collection-note">
                <strong>{result["key"]}</strong>
                · reported {EvidencePresentation.badge_text(result["health"])} · {result["summary"]}
              </p>
              <p class="collection-note">
                Source
                <time :if={result["source_at"]} datetime={result["source_at"]}>{EvidencePresentation.time(
                  result["source_at"]
                )}</time><span :if={!result["source_at"]}>Not reported</span>
              </p>
              <CheckDetails.check_details
                :if={result["details"] not in [nil, ""]}
                text={result["details"]}
              />
            </div>
            <details
              id={@id_prefix <> "execution-raw-" <> row["id"]}
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>Original report</summary><pre class="preview-findings">{Jason.encode!(row["payload"], pretty: true)}</pre>
            </details>
          </details>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  defp parameter(value) when is_binary(value), do: value
  defp parameter(value), do: Jason.encode!(value)
end
