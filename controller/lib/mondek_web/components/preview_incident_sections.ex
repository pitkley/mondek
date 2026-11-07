# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewIncidentSections do
  use MondekWeb, :html
  import MondekWeb.EvidencePresentation, only: [time: 1, badge_text: 1]
  alias Mondek.Monitoring
  alias Phoenix.LiveView.JS

  def sections(assigns) do
    assigns =
      assign(assigns,
        acknowledged: Monitoring.acknowledgement_active?(assigns.incident, assigns.now),
        measurements: measurements(assigns.kind, assigns.incident, assigns.detail)
      )

    ~H"""
    <section
      class="preview-table-group preview-incident-section"
      aria-labelledby="preview-ack-heading"
    >
      <header class="preview-section-heading preview-ack-heading">
        <h3 id="preview-ack-heading">Acknowledgement</h3>
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
        <table
          class="preview-incident-fact-table"
          aria-label="Active acknowledgement"
        >
          <tbody>
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
          </tbody>
        </table>
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
          id="preview-incident-ack-form"
          class="preview-incident-form preview-ack-form"
          phx-change="edit_acknowledgement"
          phx-submit="save_acknowledgement"
          phx-auto-recover="ignore"
        >
          <% mode = @draft["mode"] || "until_incident_ends" %>
          <fieldset class="preview-ack-timing" aria-describedby="preview-ack-effect">
            <legend>
              {if @acknowledged, do: "Replace acknowledgement", else: "Pause failure notifications"}
            </legend>
            <p id="preview-ack-effect" class="preview-caption preview-ack-effect">
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
                id={"preview-ack-option-" <> value}
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
      class="preview-table-group preview-incident-section"
      aria-labelledby="preview-delivery-heading"
    >
      <h3 id="preview-delivery-heading" class="preview-section-heading">Notification delivery</h3>
      <p
        :if={@delivery_feedback}
        class="preview-incident-evidence"
        role={if elem(@delivery_feedback, 0) == :error, do: "alert", else: "status"}
      >
        {elem(@delivery_feedback, 1)}
      </p>
      <p :if={(@detail["occurrences"] || []) == []} class="preview-incident-evidence">
        No notifications are recorded for this incident.
      </p>
      <div :for={notice <- @detail["occurrences"] || []} class="preview-incident-evidence">
        <h4>{badge_text(notice["kind"])} · {badge_text(notice["status"])}</h4>
        <p class="preview-caption">
          {time(notice["inserted_at"])} · {notice["attempt_count"] || 0} attempts
        </p>
        <p>{MondekWeb.NotificationComponents.notification_explanation(notice)}</p>
        <p :if={notice["waiting_on_gates"]} class="preview-caption">
          {MondekWeb.NotificationComponents.notification_gate_summary(notice)}
        </p>
        <p :if={notice["latest_attempt"]} class="preview-caption">
          Latest attempt: {MondekWeb.NotificationComponents.attempt_result(notice["latest_attempt"])}
        </p>
        <form
          :if={notice["can_retry"]}
          id={"preview-retry-" <> notice["id"]}
          class="preview-incident-form"
          phx-submit="retry_delivery"
          phx-auto-recover="ignore"
        >
          <input type="hidden" name="_id" value={notice["id"]} />
          <label>Reason for retry
          <input name="reason" required maxlength="500" value={@retry_drafts[notice["id"]]} /></label>
          <button type="submit" class="pf-v6-c-button pf-m-secondary">Retry notification</button>
        </form>
      </div>
    </section>

    <section
      class="preview-table-group preview-incident-section"
      aria-labelledby="preview-history-heading"
    >
      <h3 id="preview-history-heading" class="preview-section-heading">Incident history</h3>
      <table class="preview-incident-fact-table" aria-label="Incident history">
        <tbody>
          <tr>
            <th scope="row">Opened</th><td>{time(@incident["opened_at"])}</td>
          </tr>
          <tr :if={@incident["closed_at"]}>
            <th scope="row">Ended</th><td>{time(@incident["closed_at"])}</td>
          </tr>
          <tr :if={@incident["closure_reason"]}>
            <th scope="row">Closure reason</th><td>{badge_text(@incident["closure_reason"])}</td>
          </tr>
        </tbody>
      </table>
      <details
        id={"preview-measurements-" <> @incident["id"]}
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
          <div :for={measurement <- @measurements} class="preview-incident-evidence">
            <p><strong>{measurement.summary}</strong></p>
            <p class="preview-caption">{measurement.state} · {time(measurement.at)}</p>
            <pre :if={measurement.details not in [nil, ""]} class="preview-findings">{measurement.details}</pre>
          </div>
        </div>
      </details>
      <details
        id={"preview-operator-history-" <> @incident["id"]}
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
      </details>
    </section>
    """
  end

  defp acknowledgement_scope("loss", %{"scope_kind" => "runner"}),
    do: "this runner’s monitoring loss incident"

  defp acknowledgement_scope("loss", _), do: "this source’s monitoring loss incident"

  defp acknowledgement_scope("health", %{"contributions" => _}),
    do: "this shared health incident"

  defp acknowledgement_scope("health", _), do: "this result’s health incident"

  defp measurements("loss", incident, _) do
    for evidence <- incident["closing_evidence"] || [] do
      %{
        summary: evidence["label"],
        state: badge_text(evidence["health"] || evidence["knowledge"]),
        at: evidence["source_at"],
        details: nil
      }
    end
  end

  defp measurements("health", incident, detail) do
    ids = [
      incident["opening_observation_id"],
      incident["latest_observation_id"],
      incident["closing_observation_id"]
      | Enum.map(detail["occurrences"] || [], &get_in(&1, ["payload", "observation_id"]))
    ]

    for evidence <- detail["evidence"] || [],
        detail["evidence_projection"] == "referenced_result_excerpts" || evidence["id"] in ids,
        result <- get_in(evidence, ["payload", "results"]) || [],
        !incident["result_key"] || result["key"] == incident["result_key"] do
      %{
        summary: result["summary"],
        state: badge_text(result["health"]),
        at: result["source_at"] || evidence["evaluated_at"],
        details: result["details"]
      }
    end
  end
end
