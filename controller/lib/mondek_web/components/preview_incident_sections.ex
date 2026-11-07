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
      <h3 id="preview-ack-heading" class="preview-section-heading">Acknowledgement</h3>
      <div class="preview-incident-evidence">
        <p :if={@acknowledged}>
          <strong>Acknowledged</strong>
          {if @incident["acknowledged_until"],
            do: "until " <> time(@incident["acknowledged_until"]),
            else: "until this incident ends"}
        </p>
        <p :if={@acknowledged && @incident["acknowledgement_note"]}>
          {@incident["acknowledgement_note"]}
        </p>
        <p :if={!@acknowledged && @incident["status"] == "open"}>No active acknowledgement.</p>
        <p :if={@incident["status"] == "closed"}>This incident has ended.</p>
        <p :if={@incident["status"] == "open"} class="preview-caption">
          {acknowledgement_scope(@kind, @detail)} Acknowledgement pauses failure notifications while checks continue.
        </p>
        <button
          :if={@incident["status"] == "open" && !@review}
          type="button"
          class="pf-v6-c-button pf-m-secondary"
          phx-click="review_control"
        >
          {if @acknowledged, do: "Manage acknowledgement", else: "Acknowledge incident"}
        </button>
        <form
          :if={@incident["status"] == "open" && @review}
          id="preview-incident-ack-form"
          class="preview-incident-form"
          phx-change="edit_acknowledgement"
          phx-submit="save_acknowledgement"
          phx-auto-recover="ignore"
        >
          <label>
            Duration
            <select name="mode">
              <option
                value="until_incident_ends"
                selected={@draft["mode"] in [nil, "until_incident_ends"]}
              >
                Until this incident ends
              </option>
              <option value="1h" selected={@draft["mode"] == "1h"}>1 hour</option>
              <option value="24h" selected={@draft["mode"] == "24h"}>24 hours</option>
              <option :if={@acknowledged} value="end" selected={@draft["mode"] == "end"}>
                End acknowledgement now
              </option>
            </select>
          </label>
          <label>Note <textarea name="note" required maxlength="500" rows="2">{@draft["note"]}</textarea></label>
          <div class="preview-incident-form-actions">
            <button type="submit" class="pf-v6-c-button pf-m-primary">Save acknowledgement</button>
            <button type="button" class="pf-v6-c-button pf-m-link" phx-click="cancel_control">Cancel</button>
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
        <p :if={@feedback} role={if elem(@feedback, 0) == :error, do: "alert", else: "status"}>
          {elem(@feedback, 1)}
        </p>
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
        <p :if={@measurements == []} class="preview-incident-evidence">
          No linked measurements are retained here.
        </p>
        <div :for={measurement <- @measurements} class="preview-incident-evidence">
          <p><strong>{measurement.summary}</strong></p>
          <p class="preview-caption">{measurement.state} · {time(measurement.at)}</p>
          <pre :if={measurement.details not in [nil, ""]} class="preview-findings">{measurement.details}</pre>
        </div>
      </details>
      <details
        id={"preview-operator-history-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Operator control history</summary>
        <p :if={(@detail["controls"] || []) == []} class="preview-incident-evidence">
          No operator controls are recorded.
        </p>
        <div :for={control <- @detail["controls"] || []} class="preview-incident-evidence">
          <p><strong>{badge_text(control["kind"])}</strong></p>
          <p :if={control["reason"]}>{control["reason"]}</p>
          <p class="preview-caption">{control["actor"]} · {time(control["inserted_at"])}</p>
        </div>
      </details>
    </section>
    """
  end

  defp acknowledgement_scope("loss", %{"scope_kind" => "runner"}),
    do: "Applies to this runner’s monitoring loss incident."

  defp acknowledgement_scope("loss", _), do: "Applies to this source’s monitoring loss incident."

  defp acknowledgement_scope("health", %{"contributions" => _}),
    do: "Applies to this shared health incident."

  defp acknowledgement_scope("health", _), do: "Applies to this result’s health incident."

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
