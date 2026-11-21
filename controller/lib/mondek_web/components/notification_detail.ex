# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationDetail do
  @moduledoc "Canonical notification evidence and retry controls for pages and investigation panels."
  use MondekWeb, :html
  alias Phoenix.LiveView.JS
  alias MondekWeb.{EvidencePresentation, NotificationComponents, PreviewDetail}

  attr :inspection, :any, required: true
  attr :now, :any, required: true
  attr :full_page, :boolean, default: false
  attr :target, :any, default: nil
  attr :entity, :string, required: true
  attr :retry_drafts, :map, default: %{}
  attr :feedback, :any, default: nil
  attr :id_prefix, :string, default: ""
  attr :incident_path, :any, required: true
  attr :result_path, :any, required: true
  attr :execution_path, :any, required: true
  attr :maintenance_path, :any, required: true

  def body(assigns) do
    notice = get_in(assigns.inspection || %{}, ["occurrence"])
    attempts = (assigns.inspection || %{})["attempts"] || []

    assigns =
      assign(assigns,
        notice: notice,
        attempts: attempts,
        initial_attempts: if(assigns.full_page, do: 100, else: 5)
      )

    ~H"""
    <div data-notification-body>
      <PreviewDetail.heading
        level={if @full_page, do: 1, else: 2}
        id={@id_prefix <> if(@full_page, do: "notification-heading", else: "overview-panel-title")}
      >
        {title(@notice)}
      </PreviewDetail.heading>
      <p :if={!@notice} class="preview-empty">This notification is not in retained history.</p>
      <%= if @notice do %>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "notification-delivery"}
          title="Delivery status"
        >
          <p :if={@notice["delivery_enabled"] == false} data-notification-delivery-off>
            Notification delivery is off for this installation.
          </p>
          <PreviewDetail.facts label="Notification delivery">
            <tr>
              <th scope="row">Status</th><td><.status value={@notice["status"]} /></td>
            </tr>
            <tr>
              <th scope="row">Details</th><td>
                {NotificationComponents.notification_explanation(@notice)}
              </td>
            </tr>
            <tr>
              <th scope="row">Receiver</th><td>{receiver(@notice)}</td>
            </tr>
            <tr :if={@notice["condition_incident_id"]}>
              <th scope="row">Requested scope</th><td class="notification-requested-scope">
                {NotificationComponents.requested_scope(@notice)}
              </td>
            </tr>
            <tr>
              <th scope="row">Event</th><td>{event(@notice["kind"])}</td>
            </tr>
            <tr>
              <th scope="row">Created</th><td>
                <time datetime={@notice["inserted_at"]}>{EvidencePresentation.time(
                  @notice["inserted_at"]
                )}</time>
              </td>
            </tr>
            <tr>
              <th scope="row">Attempts</th><td>{@notice["attempt_count"] || 0}</td>
            </tr>
            <tr :if={@notice["next_retry_at"]}>
              <th scope="row">Next eligible attempt</th><td>
                {NotificationComponents.retry_time(@notice["next_retry_at"], @now)}
              </td>
            </tr>
            <tr :if={@notice["latest_attempt"]}>
              <th scope="row">Latest attempt</th><td>
                {NotificationComponents.attempt_result(@notice["latest_attempt"])}
              </td>
            </tr>
            <tr :if={@notice["gates"] not in [nil, []]}>
              <th scope="row">Notification controls</th><td>
                {NotificationComponents.notification_gate_summary(@notice)}
                <span :if={!@notice["waiting_on_gates"]}>An attempt already underway may finish.</span>
              </td>
            </tr>
            <tr :if={@notice["maintenance_windows"] not in [nil, []]}>
              <th scope="row">Maintenance</th><td>
                <div :for={window <- @notice["maintenance_windows"]}>
                  <.link navigate={@maintenance_path.(window["id"])}>{window["name"] ||
                    "Maintenance window"}</.link>
                </div>
              </td>
            </tr>
            <tr>
              <th scope="row">Related evidence</th><td>
                <.link :if={incident(@notice)} patch={@incident_path.(incident(@notice))}>View {if elem(
                                                                                                     incident(
                                                                                                       @notice
                                                                                                     ),
                                                                                                     0
                                                                                                   ) ==
                                                                                                     "loss",
                                                                                                   do:
                                                                                                     "monitoring loss",
                                                                                                   else:
                                                                                                     "health incident"}</.link>
                <span :if={get_in(@notice, ["payload", "stream_id"])}> · <.link patch={
                  @result_path.(get_in(@notice, ["payload", "stream_id"]))
                }>View current result</.link></span>
                <span :if={!get_in(@notice, ["payload", "stream_id"]) && @notice["assignment_id"]}> · <.link patch={
                  @execution_path.(@notice["assignment_id"])
                }>View scheduled execution</.link></span>
              </td>
            </tr>
          </PreviewDetail.facts>
          <p
            :if={@feedback}
            role={if elem(@feedback, 0) == :error, do: "alert", else: "status"}
            class="ui-feedback"
          >
            {elem(@feedback, 1)}
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "notification-attempts"}
          title="Delivery attempts"
        >
          <p :if={@attempts == []} class="preview-empty">No delivery attempts have been recorded.</p>
          <.attempts :if={@attempts != []} attempts={Enum.take(@attempts, @initial_attempts)} />
          <details
            :if={length(@attempts) > @initial_attempts}
            id={@id_prefix <> "notification-older-attempts"}
            phx-mounted={JS.ignore_attributes("open")}
            class="preview-result-history-more"
          >
            <summary>Earlier attempts ({length(@attempts) - @initial_attempts})</summary>
            <.attempts attempts={Enum.drop(@attempts, @initial_attempts)} />
          </details>
          <p
            :if={get_in(@inspection, ["notification_attempts", "omitted"]) not in [nil, 0]}
            class="preview-empty"
          >
            Older attempts are outside retained inspection limits.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          :if={@notice["can_retry"]}
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "notification-retry"}
          title="Retry delivery"
        >
          <form
            id={"retry-notification-" <> @notice["id"]}
            phx-target={@target}
            phx-submit="retry_notification"
            phx-change="edit_notification_retry"
            phx-auto-recover="edit_notification_retry"
            class="preview-incident-form notification-retry-form"
          >
            <input type="hidden" name="entity" value={@entity} />
            <input type="hidden" name="_id" value={@notice["id"]} />
            <label for={"retry-reason-" <> @notice["id"]}>Reason for retry</label>
            <input
              id={"retry-reason-" <> @notice["id"]}
              name="reason"
              value={@retry_drafts[@notice["id"]] || ""}
              required
              maxlength="500"
            />
            <p class="preview-caption">
              Retrying starts a new attempt budget for this original notification and receiver. It can deliver a duplicate. Acknowledgements and maintenance still apply.
            </p>
            <button class="pf-v6-c-button pf-m-primary" phx-disable-with="Requesting…">Retry notification</button>
          </form>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "notification-record"}
          title="Recorded notification"
        >
          <PreviewDetail.facts label="Notification identity">
            <tr>
              <th scope="row">Notification ID</th><td>{@notice["id"]}</td>
            </tr>
          </PreviewDetail.facts>
          <details
            id={@id_prefix <> "notification-payload"}
            phx-mounted={JS.ignore_attributes("open")}
            class="notification-disclosure"
          >
            <summary>Original notification payload</summary>
            <pre class="preview-findings">{Jason.encode!(Map.drop(@notice["payload"] || %{}, ["webhook_delivery"]), pretty: true)}</pre>
          </details>
          <details
            id={@id_prefix <> "notification-jobs"}
            phx-mounted={JS.ignore_attributes("open")}
            class="notification-disclosure"
          >
            <summary>Worker diagnostics</summary>
            <pre class="preview-findings">{Jason.encode!(@inspection["jobs"] || [], pretty: true)}</pre>
          </details>
        </PreviewDetail.card>
      <% end %>
    </div>
    """
  end

  attr :value, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={["pf-v6-c-label", tone(@value)]}><span class="pf-v6-c-label__content">{status_label(
      @value
    )}</span></span>
    """
  end

  attr :attempts, :list, required: true

  defp attempts(assigns) do
    ~H"""
    <table
      class="preview-incident-fact-table notification-attempt-table"
      aria-label="Delivery attempts"
    >
      <thead>
        <tr>
          <th scope="col">Started</th><th scope="col">Result</th>
        </tr>
      </thead><tbody>
        <tr :for={attempt <- @attempts}>
          <th scope="row">
            <time datetime={attempt["started_at"]}>{EvidencePresentation.time(attempt["started_at"])}</time>
          </th><td>{NotificationComponents.attempt_result(attempt)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  def title(nil), do: "Notification not found"

  def title(notice) do
    case NotificationComponents.notification_check_label(notice) do
      "" -> get_in(notice, ["payload", "email", "label"]) || "Notification"
      label -> label
    end
  end

  def receiver(%{"destination" => "mailto:" <> address}), do: address

  def receiver(%{"destination" => "webhook:" <> id}) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id),
      do: "Webhook · " <> id,
      else: "Webhook receiver · address hidden"
  end

  def receiver(_), do: "Webhook receiver · address hidden"
  def incident(%{"monitoring_incident_id" => id}) when is_binary(id), do: {"loss", id}

  def incident(notice) do
    if id = notice["condition_incident_id"] || notice["incident_id"], do: {"health", id}
  end

  def event("firing"), do: "Failure"
  def event("update"), do: "Severity change"
  def event("resolved"), do: "Incident ended"
  def event(value), do: EvidencePresentation.badge_text(value)
  def status_label("delivered"), do: "Receiver accepted"
  def status_label("pending"), do: "Queued"
  def status_label(value), do: EvidencePresentation.badge_text(value)
  defp tone("delivered"), do: "pf-m-green"
  defp tone("exhausted"), do: "pf-m-red"
  defp tone(value) when value in ~w(retrying delivering), do: "pf-m-orange"
  defp tone(_), do: ""
end
