# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewIncidentSections do
  use MondekWeb, :html
  import MondekWeb.CheckDetails, only: [check_details: 1]
  import MondekWeb.EvidencePresentation, only: [time: 1, badge_text: 1]
  alias Mondek.Monitoring
  alias MondekWeb.{NextOverviewLive, NotificationComponents, PreviewDetail}
  alias Phoenix.LiveView.JS

  def sections(assigns) do
    {measurements, recent_executions} =
      measurements(assigns.kind, assigns.incident, assigns.detail)

    assigns =
      assigns
      |> assign_new(:delivery_filter, fn -> [] end)
      |> assign_new(:current, fn -> nil end)
      |> assign_new(:id_prefix, fn -> "" end)
      |> assign(
        acknowledged: Monitoring.acknowledgement_active?(assigns.incident, assigns.now),
        measurements: measurements,
        recent_executions: recent_executions,
        earlier_attempts: Enum.group_by(assigns.detail["attempts"] || [], & &1["occurrence_id"])
      )

    ~H"""
    <section
      class="preview-table-group preview-incident-section"
      aria-labelledby={@id_prefix <> "preview-ack-heading"}
    >
      <header class="preview-section-heading preview-ack-heading">
        <h3 id={@id_prefix <> "preview-ack-heading"}>Acknowledgement</h3>
        <span
          :if={@feedback && elem(@feedback, 0) == :ok}
          class="pf-v6-c-label pf-m-green"
          role="status"
        >
          <span class="pf-v6-c-label__content">{elem(@feedback, 1)}</span>
        </span>
        <span
          :if={
            !@acknowledged && @incident["status"] == "open" &&
              !match?({:ok, _}, @feedback)
          }
          class="preview-caption"
        >
          No active acknowledgement
        </span>
      </header>
      <div :if={@acknowledged}>
        <PreviewDetail.facts label="Active acknowledgement">
          <tr>
            <th scope="row">Active until</th>
            <td>
              {if @incident["acknowledged_until"],
                do: time(@incident["acknowledged_until"]),
                else: "Incident ends"}
            </td>
          </tr>
          <tr>
            <th scope="row">Note</th>
            <td>
              <span
                :if={@incident["acknowledgement_note"] in [nil, "", "No note provided."]}
                class="preview-caption"
              >No note provided</span>
              <span :if={@incident["acknowledgement_note"] not in [nil, "", "No note provided."]}>{@incident[
                "acknowledgement_note"
              ]}</span>
            </td>
          </tr>
        </PreviewDetail.facts>
        <div class="preview-ack-active-actions">
          <button
            type="button"
            class="pf-v6-c-button pf-m-secondary"
            phx-click="toggle_acknowledgement_replacement"
            aria-expanded={to_string(@replacing)}
          >
            {if @replacing, do: "Cancel replacement", else: "Replace acknowledgement"}
          </button>
          <button type="button" class="pf-v6-c-button pf-m-secondary" phx-click="end_acknowledgement">
            End acknowledgement
          </button>
        </div>
      </div>
      <div
        :if={!@acknowledged || @replacing || (@feedback && elem(@feedback, 0) == :error)}
        class="preview-incident-evidence"
      >
        <p :if={@feedback && elem(@feedback, 0) == :error} role="alert">{elem(@feedback, 1)}</p>
        <p :if={@incident["status"] == "closed"}>This incident has ended.</p>
        <form
          :if={@incident["status"] == "open" && @review && (!@acknowledged || @replacing)}
          id={@id_prefix <> "preview-incident-ack-form"}
          class="preview-incident-form preview-ack-form"
          phx-change="edit_acknowledgement"
          phx-submit="save_acknowledgement"
          phx-auto-recover="ignore"
        >
          <% mode = @draft["mode"] || "until_incident_ends" %>
          <fieldset class="preview-ack-timing" aria-describedby={@id_prefix <> "preview-ack-effect"}>
            <legend>
              {if @acknowledged, do: "Replace acknowledgement", else: "Pause failure notifications"}
            </legend>
            <p id={@id_prefix <> "preview-ack-effect"} class="preview-caption preview-ack-effect">
              Pauses failure notifications for {acknowledgement_scope(@kind, @detail)}. Checks continue.
            </p>
            <div class="preview-ack-options">
              <div
                :for={
                  {value, label} <-
                    [
                      {"until_incident_ends", "Until incident ends"},
                      {"duration", "For a duration"},
                      {"until", "Until date and time"}
                    ]
                }
                id={@id_prefix <> "preview-ack-option-" <> value}
                class="preview-ack-option"
              >
                <label class="preview-ack-choice">
                  <input type="radio" name="mode" value={value} checked={mode == value} />
                  <span>{label}</span>
                </label>
                <div
                  :if={mode == value && value == "duration"}
                  class="preview-ack-fields preview-ack-duration"
                >
                  <label>
                    Amount
                    <input
                      type="number"
                      name="amount"
                      min="1"
                      step="1"
                      required
                      value={@draft["amount"] || "1"}
                    />
                  </label>
                  <label>
                    Unit
                    <select name="unit">
                      <option
                        :for={unit <- ~w(minutes hours days)}
                        value={unit}
                        selected={unit == (@draft["unit"] || "hours")}
                      >
                        {unit}
                      </option>
                    </select>
                  </label>
                </div>
                <div :if={mode == value && value == "until"} class="preview-ack-fields">
                  <label>
                    Date and time (UTC)
                    <input
                      type="datetime-local"
                      name="expires_at"
                      required
                      value={@draft["expires_at"]}
                    />
                  </label>
                </div>
              </div>
            </div>
          </fieldset>
          <label class="preview-ack-note">
            <span>Note <span class="preview-caption">(optional)</span></span>
            <textarea
              name="note"
              maxlength="500"
              rows="2"
              placeholder="Add context for the incident history"
            >{@draft["note"]}</textarea>
          </label>
          <div class="preview-incident-form-actions">
            <button type="submit" class="pf-v6-c-button pf-m-primary">
              {if @acknowledged, do: "Replace acknowledgement", else: "Save acknowledgement"}
            </button>
            <button
              :if={
                @review["revision"] != @incident["acknowledgement_revision"] ||
                  @review["attention_revision"] != @incident["attention_revision"]
              }
              type="button"
              class="pf-v6-c-button pf-m-link"
              phx-click="review_control"
            >Review current incident</button>
          </div>
        </form>
      </div>
    </section>

    <section
      :if={@incident["status"] == "open"}
      class="preview-table-group preview-incident-section"
      aria-labelledby={@id_prefix <> "preview-maintenance-heading"}
    >
      <h3 id={@id_prefix <> "preview-maintenance-heading"} class="preview-section-heading">
        Maintenance
      </h3>
      <PreviewDetail.facts labelledby={@id_prefix <> "preview-maintenance-heading"}>
        <tr :for={window <- @maintenance_windows}>
          <th scope="row">Active window</th>
          <td>
            <.link href={with_incident_return("/next/maintenance/" <> window["id"], @current)}>
              {window["name"] || window["reason"] || "View maintenance window"}
            </.link>
            <span class="preview-caption"> · Ends {time(window["ends_at"])}</span>
          </td>
        </tr>
        <tr :if={@kind == "loss"}>
          <th scope="row">Monitoring loss notifications</th>
          <td>
            Maintenance pauses a monitoring loss notification only if the window covers every result in that notification’s scope.
          </td>
        </tr>
        <tr :if={@detail["contributions"]}>
          <th scope="row">Active coverage</th>
          <td>
            {@detail["counts"]["maintained"]} of {@detail["counts"]["open"]} failing results in maintenance
          </td>
        </tr>
        <tr :if={@kind == "health" && !@detail["contributions"] && @maintenance_windows == []}>
          <th scope="row">Active windows</th>
          <td>No active maintenance for this result.</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link href={with_incident_return(maintenance_href(@kind, @incident, true), @current)}>Schedule maintenance</.link>
        <.link href={maintenance_href(@kind, @incident, false)}>Review maintenance</.link>
      </div>
    </section>

    <PreviewDetail.card id={@id_prefix <> "preview-history"} title="Incident history">
      <PreviewDetail.facts label="Incident history">
        <tr>
          <th scope="row">Opened</th><td>{time(@incident["opened_at"])}</td>
        </tr>
        <tr :if={@incident["closed_at"]}>
          <th scope="row">Ended</th><td>{time(@incident["closed_at"])}</td>
        </tr>
        <tr :if={@incident["closure_reason"]}>
          <th scope="row">Closure reason</th><td>{badge_text(@incident["closure_reason"])}</td>
        </tr>
      </PreviewDetail.facts>
      <details
        id={@id_prefix <> "preview-measurements-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>
          {if @kind == "loss", do: "Restoration evidence", else: "Measurement history"}
        </summary>
        <div class="preview-incident-history-content">
          <p :if={@measurements == []} class="preview-incident-evidence">
            No linked measurements are retained here.
          </p>
          <p
            :if={(get_in(@detail, ["limits", "evidence", "missing"]) || 0) > 0}
            class="preview-incident-evidence"
          >
            {get_in(@detail, ["limits", "evidence", "missing"])} referenced measurements are unavailable.
          </p>
          <.measurement_list
            :if={@kind == "health"}
            measurements={@measurements}
          />
          <div
            :for={evidence <- @measurements}
            :if={@kind == "loss"}
            class="preview-incident-evidence"
          >
            <strong>{evidence["label"] || "Restored measurement"}</strong>
            <PreviewDetail.facts label="Restoration measurement">
              <tr>
                <th scope="row">Result</th>
                <td>
                  {if evidence["health"],
                    do: badge_text(evidence["health"]),
                    else: "Coverage observed"}
                </td>
              </tr>
              <tr>
                <th scope="row">Measured at</th><td>{time(evidence["source_at"])}</td>
              </tr>
              <tr :if={evidence["generation"]}>
                <th scope="row">Configuration version</th><td>{evidence["generation"]}</td>
              </tr>
              <tr :if={evidence["observation_id"]}>
                <th scope="row">Observation</th><td><code>{evidence["observation_id"]}</code></td>
              </tr>
            </PreviewDetail.facts>
            <.link
              :if={evidence["stream_id"]}
              href={
                NextOverviewLive.path(
                  %{"incident_return" => @current},
                  :result,
                  evidence["stream_id"]
                )
              }
            >
              Open current result evidence
            </.link>
            <.link
              :if={evidence["coverage_id"]}
              href={
                NextOverviewLive.path(
                  %{"incident_return" => @current},
                  :expected,
                  evidence["coverage_id"]
                )
              }
            >
              Review expected monitoring
            </.link>
          </div>
        </div>
      </details>
      <details
        :if={@recent_executions != []}
        id={@id_prefix <> "preview-recent-executions-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Other recent check executions</summary>
        <div class="preview-incident-history-content">
          <p class="preview-incident-evidence">
            These measurements are outside the incident’s linked history and may include executions after it ended.
          </p>
          <.measurement_list measurements={@recent_executions} />
        </div>
      </details>
      <details
        id={@id_prefix <> "preview-operator-history-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Operator control history</summary>
        <div class="preview-incident-history-content">
          <p :if={(@detail["controls"] || []) == []} class="preview-incident-evidence">
            No operator controls are recorded.
          </p>
          <div :for={control <- @detail["controls"] || []} class="preview-incident-evidence">
            <p><strong>{badge_text(control["kind"])}</strong></p>
            <p :if={control["reason"]}>{control["reason"]}</p>
            <p class="preview-caption">{control["actor"]} · {time(control["inserted_at"])}</p>
          </div>
        </div>
        <.history_limit limit={get_in(@detail, ["limits", "controls"])} label="operator controls" />
      </details>
    </PreviewDetail.card>

    <section
      class="preview-table-group preview-incident-section"
      aria-labelledby={@id_prefix <> "preview-delivery-heading"}
    >
      <h3 id={@id_prefix <> "preview-delivery-heading"} class="preview-section-heading">
        Notification delivery
      </h3>
      {render_slot(@delivery_filter)}
      <p
        :if={@delivery_feedback}
        class="preview-incident-evidence"
        role={if elem(@delivery_feedback, 0) == :error, do: "alert", else: "status"}
      >
        {elem(@delivery_feedback, 1)}
      </p>
      <p :if={(@detail["occurrences"] || []) == []} class="preview-incident-evidence">
        {if (get_in(@detail, ["notification_page", "all_total"]) || 0) > 0,
          do: "No notifications match this status.",
          else: "No notifications are recorded for this incident."}
      </p>
      <table
        :if={(@detail["occurrences"] || []) != []}
        class="preview-incident-fact-table"
        aria-labelledby={@id_prefix <> "preview-delivery-heading"}
      >
        <tbody>
          <tr :for={notice <- @detail["occurrences"]}>
            <th scope="row">
              {badge_text(notice["kind"])}
              <div class="preview-caption">{time(notice["inserted_at"])}</div>
            </th>
            <td class="preview-incident-nested-facts">
              <table class="preview-delivery-details" aria-label="Delivery details">
                <colgroup><col class="preview-delivery-label-column" /><col /></colgroup>
                <tbody>
                  <tr>
                    <th scope="row">Status</th>
                    <td>
                      <span class={["pf-v6-c-label", delivery_status_color(notice["status"])]}>
                        <span class="pf-v6-c-label__content">{badge_text(notice["status"])}</span>
                      </span>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Details</th>
                    <td>{NotificationComponents.notification_explanation(notice)}</td>
                  </tr>
                  <tr>
                    <th scope="row">Attempts</th>
                    <td>{notice["attempt_count"] || 0}</td>
                  </tr>
                  <tr :if={notice["waiting_on_gates"]}>
                    <th scope="row">Waiting on</th>
                    <td>{NotificationComponents.notification_gate_summary(notice)}</td>
                  </tr>
                  <tr :if={notice["next_retry_at"]}>
                    <th scope="row">Next eligible attempt</th>
                    <td>{NotificationComponents.retry_time(notice["next_retry_at"], @now)}</td>
                  </tr>
                  <tr :if={
                    notice["waiting_on_gates"] && notice["maintenance_windows"] not in [nil, []]
                  }>
                    <th scope="row">Maintenance</th>
                    <td>
                      <div :for={window <- notice["maintenance_windows"]}>
                        <.link href={
                          with_incident_return("/next/maintenance/" <> window["id"], @current)
                        }>{window["name"] ||
                          window["reason"] || "View window"}</.link>
                      </div>
                    </td>
                  </tr>
                  <tr :if={notice["latest_attempt"]}>
                    <th scope="row">Latest attempt</th>
                    <td>
                      {NotificationComponents.attempt_result(notice["latest_attempt"])}
                    </td>
                  </tr>
                  <% earlier =
                    Enum.reject(
                      @earlier_attempts[notice["id"]] || [],
                      &(&1["id"] == get_in(notice, ["latest_attempt", "id"]))
                    ) %>
                  <tr :if={earlier != []}>
                    <th scope="row">Attempt history</th>
                    <td>
                      <details
                        id={@id_prefix <> "preview-attempts-" <> notice["id"]}
                        phx-mounted={JS.ignore_attributes("open")}
                      >
                        <summary>Earlier attempts ({length(earlier)})</summary>
                        <table aria-label="Earlier delivery attempts">
                          <tbody>
                            <tr :for={attempt <- earlier}>
                              <th scope="row">{time(attempt["started_at"])}</th>
                              <td>{NotificationComponents.attempt_result(attempt)}</td>
                            </tr>
                          </tbody>
                        </table>
                      </details>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Original delivery</th>
                    <td>
                      <details
                        id={@id_prefix <> "preview-payload-" <> notice["id"]}
                        phx-mounted={JS.ignore_attributes("open")}
                      >
                        <summary>Original notification payload</summary>
                        <pre class="preview-findings">{Jason.encode!(Map.drop(notice["payload"], ["webhook_delivery"]), pretty: true)}</pre>
                      </details>
                    </td>
                  </tr>
                  <tr :if={notice["can_retry"]}>
                    <th scope="row">Retry</th>
                    <td>
                      <form
                        id={@id_prefix <> "preview-retry-" <> notice["id"]}
                        class="preview-incident-form"
                        phx-submit="retry_delivery"
                        phx-auto-recover="ignore"
                      >
                        <input type="hidden" name="_id" value={notice["id"]} />
                        <label>Reason for retry
                        <input
                          name="reason"
                          required
                          maxlength="500"
                          value={@retry_drafts[notice["id"]]}
                        /></label>
                        <p class="preview-caption">
                          Retrying starts a new attempt budget and can deliver a duplicate. Acknowledgements and maintenance still apply.
                        </p>
                        <div class="preview-incident-form-actions">
                          <button type="submit" class="pf-v6-c-button pf-m-secondary">Retry notification</button>
                        </div>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </td>
          </tr>
        </tbody>
      </table>
      <.history_limit limit={get_in(@detail, ["limits", "occurrences"])} label="notifications" />
      <.history_limit limit={get_in(@detail, ["limits", "attempts"])} label="delivery attempts" />
      {render_slot(@delivery_pagination)}
    </section>
    """
  end

  defp history_limit(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        assigns.limit && (assigns.limit["shown"] || assigns.limit["returned"])
      )

    ~H"""
    <p
      :if={is_integer(@shown) && @shown < @limit["total"]}
      class="preview-recorded-actions preview-caption"
    >
      Showing {@shown} of {@limit["total"]} {@label}.
    </p>
    """
  end

  defp maintenance_href("health", %{"assignment_id" => id} = incident, schedule?)
       when is_binary(id) do
    params = %{if(schedule?, do: "check_id", else: "assignment_id") => id}

    params =
      if incident["stream_id"],
        do: Map.put(params, "stream_id", incident["stream_id"]),
        else: params

    if(schedule?, do: "/next/maintenance/new?", else: "/next/maintenance?") <>
      URI.encode_query(params)
  end

  defp maintenance_href(_, _, true), do: "/next/maintenance/new"
  defp maintenance_href(_, _, false), do: "/next/maintenance"

  defp with_incident_return(path, nil), do: path

  defp with_incident_return(path, current) do
    uri = URI.parse(path)
    params = URI.decode_query(uri.query || "") |> Map.put("return_to", current)
    uri.path <> "?" <> URI.encode_query(params)
  end

  defp delivery_status_color("delivered"), do: "pf-m-green"
  defp delivery_status_color("exhausted"), do: "pf-m-red"
  defp delivery_status_color("retrying"), do: "pf-m-orange"
  defp delivery_status_color("delivering"), do: "pf-m-blue"
  defp delivery_status_color(_), do: nil

  defp acknowledgement_scope("loss", %{"scope_kind" => "runner"}),
    do: "this runner’s monitoring loss incident"

  defp acknowledgement_scope("loss", _), do: "this source’s monitoring loss incident"

  defp acknowledgement_scope("health", %{"contributions" => _}),
    do: "this shared health incident"

  defp acknowledgement_scope("health", _), do: "this result’s health incident"

  defp measurement_list(assigns) do
    ~H"""
    <div :for={measurement <- @measurements} class="preview-incident-evidence">
      <p><strong>{measurement.summary}</strong></p>
      <p class="preview-caption">{measurement.state} · {time(measurement.at)}</p>
      <.check_details text={measurement.details} />
    </div>
    """
  end

  defp measurements("loss", incident, _), do: {incident["closing_evidence"] || [], []}

  defp measurements("health", incident, detail) do
    ids = [
      incident["opening_observation_id"],
      incident["latest_observation_id"],
      incident["closing_observation_id"]
      | Enum.map(detail["occurrences"] || [], &get_in(&1, ["payload", "observation_id"]))
    ]

    {linked, recent} =
      Enum.split_with(detail["evidence"] || [], fn evidence ->
        detail["evidence_projection"] == "referenced_result_excerpts" || evidence["id"] in ids
      end)

    {result_measurements(linked, incident["result_key"]),
     result_measurements(recent, incident["result_key"])}
  end

  defp result_measurements(evidence, result_key) do
    for observation <- evidence,
        result <- get_in(observation, ["payload", "results"]) || [],
        !result_key || result["key"] == result_key do
      %{
        summary: result["summary"],
        state: badge_text(result["health"]),
        at: result["source_at"] || observation["evaluated_at"],
        details: result["details"]
      }
    end
  end
end
