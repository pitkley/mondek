# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationComponents do
  @moduledoc "Shared delivery evidence for notification and incident pages; no LiveView state."
  use MondekWeb, :html
  import MondekWeb.EvidencePresentation
  alias Phoenix.LiveView.JS
  alias MondekWeb.NotificationNavigation
  import MondekWeb.InvestigationNavigation, only: [detail_path: 2]

  def occurrence_list(assigns) do
    assigns = assign_new(assigns, :return_to, fn -> nil end)
    assigns = assign_new(assigns, :retry_drafts, fn -> %{} end)
    assigns = assign_new(assigns, :current_incident_id, fn -> nil end)

    ~H"""
    <div :if={@occurrences == []} class="empty">
      <h3>No notifications yet</h3><p>
        Incident notifications and their delivery decisions will appear here.
      </p>
    </div>
    <div :for={occurrence <- @occurrences} class="resource" id={"notification-" <> occurrence["id"]}>
      <div class="resource-name">
        <h3>{notification_title(occurrence)}</h3><.badge value={occurrence["status"]} />
      </div>
      <p :if={occurrence["condition_incident_id"]} class="space-top notification-requested-scope">
        <strong>Requested scope:</strong> {notification_requested_scope(occurrence)}
      </p>
      <p class="space-top">
        <.link
          :if={
            (occurrence["monitoring_incident_id"] || occurrence["condition_incident_id"] ||
               occurrence["incident_id"]) != @current_incident_id
          }
          navigate={
            detail_path(
              notification_incident_path(occurrence),
              @return_to
            )
          }
          class="text-link"
        >{notification_check_label(occurrence)} incident</.link>
        <.link
          :if={occurrence["assignment_id"]}
          navigate={detail_path(notification_result_path(occurrence), @return_to)}
          class="text-link"
        >{if get_in(occurrence, ["payload", "stream_id"]),
          do: "View result",
          else: "Shared check execution"}</.link>
      </p>
      <p class="resource-summary">{notification_explanation(occurrence)}</p>
      <p :if={occurrence["waiting_on_gates"] == true} class="notice notice-copy space-top">
        {notification_gate_summary(occurrence)} {if length(occurrence["gates"]) > 1,
          do: "Ending one control leaves the other active."}
      </p>
      <p
        :if={(occurrence["gates"] || []) != [] && occurrence["waiting_on_gates"] != true}
        class="footnote space-top"
      >
        {Enum.map_join(occurrence["gates"], " and ", &humanize/1)} applies to future delivery attempts. An attempt already underway may finish; exhausted work does not restart automatically.
      </p>
      <div class="resource-meta">
        <span>Delivery attempts <strong>{occurrence["attempt_count"] || 0}</strong></span>
        <span :if={occurrence["next_retry_at"]}>Next eligible attempt
        <strong>{retry_time(occurrence["next_retry_at"], @now)}</strong></span>
        <span :if={occurrence["latest_attempt"]}>Latest attempt
        <strong>{attempt_result(occurrence["latest_attempt"])}</strong></span>
        <span>Created <strong>{age(occurrence["inserted_at"], @now)}</strong></span><span class="mono">{String.slice(
          occurrence["id"] || "",
          0,
          8
        )}</span>
      </div><p class="resource-subtitle">
        {if String.starts_with?(occurrence["destination"], "mailto:"),
          do: "Email recipient",
          else: "Webhook receiver"}:
        <span class="mono">{String.replace_prefix(occurrence["destination"], "mailto:", "")}</span>
      </p><details phx-mounted={JS.ignore_attributes("open")} class="space-top">
        <summary class="footnote">Notification identity and immutable payload</summary><pre
          tabindex="0"
          role="region"
          aria-label="Notification payload"
        >{Jason.encode!(occurrence["payload"], pretty: true)}</pre>
      </details>
      <form
        :if={occurrence["can_retry"] == true}
        id={"retry-notification-" <> occurrence["id"]}
        phx-submit="retry_notification"
        phx-change="edit_notification_retry"
        phx-auto-recover="edit_notification_retry"
        class="attention-form space-top"
      >
        <input type="hidden" name="_id" value={occurrence["id"]} />
        <div class="field">
          <label for={"retry-reason-" <> occurrence["id"]}>Retry reason</label><input
            id={"retry-reason-" <> occurrence["id"]}
            name="reason"
            value={@retry_drafts[occurrence["id"]] || ""}
            required
            maxlength="500"
            placeholder="Receiver repaired; retry delivery"
          />
        </div>
        <p class="footnote">
          Starts a new attempt budget for this original notification. Failure notifications respect acknowledgement and maintenance; closure notifications remain eligible. The receiver may already have accepted an earlier attempt.
        </p>
        <button class="button" phx-disable-with="Requesting…">Retry notification</button>
      </form>
    </div>
    """
  end

  def attempts_table(assigns) do
    assigns = assign(assigns, occurrences: Map.get(assigns, :occurrences, []))
    assigns = assign_new(assigns, :current_notification_id, fn -> nil end)

    ~H"""
    <div :if={@attempts == []} class="empty">
      <h3>No delivery attempts yet</h3><p>Once dispatched, every attempt and retry appears here.</p>
    </div>
    <div
      :if={@attempts != []}
      class="table-wrap"
      tabindex="0"
      role="region"
      aria-label="Delivery attempts table"
    >
      <table>
        <thead>
          <tr>
            <th scope="col">Notification</th><th scope="col">Attempt</th><th scope="col">Result</th><th scope="col">
              Response
            </th><th scope="col">Started</th>
          </tr>
        </thead><tbody>
          <tr :for={attempt <- @attempts}>
            <td>
              <.link
                :if={
                  attempt["occurrence_id"] != @current_notification_id &&
                    attempt_notification_path(attempt, @occurrences)
                }
                navigate={attempt_notification_path(attempt, @occurrences)}
                class="text-link"
              >{attempt_notification_label(attempt, @occurrences)}</.link><span :if={
                attempt["occurrence_id"] == @current_notification_id ||
                  !attempt_notification_path(attempt, @occurrences)
              }>{if attempt["occurrence_id"] == @current_notification_id,
                do: notification_title(find(@occurrences, attempt["occurrence_id"])),
                else:
                  "Notification outside this view · " <> String.slice(attempt["occurrence_id"], 0, 8)}</span>
            </td>
            <td class="mono">{String.slice(to_string(attempt["id"]), 0, 8)}</td><td>
              <.badge value={attempt["status"]} />
            </td><td>
              {attempt_response(attempt)}
            </td><td title={attempt["started_at"]}>{age(attempt["started_at"], @now)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def notifications(assigns) do
    assigns =
      assign(assigns,
        delivery_page: assigns.snapshot["notification_page"],
        delivery_return_to: NotificationNavigation.path(assigns.filters)
      )

    ~H"""
    <div class="page-heading">
      <div>
        <div class="eyebrow">Notification delivery</div><h1>Notifications</h1>
        <p>Find delivery failures, inspect attempts, and retry after fixing the receiver.</p>
      </div>
    </div>
    <div class="delivery-summary" id="delivery-summary">
      <.link
        patch={NotificationNavigation.path(%{"notification_status" => "exhausted"})}
        class={[
          "panel delivery-stat",
          @snapshot["notification_backlog"]["exhausted"] > 0 && "delivery-stat-alert"
        ]}
      >
        <span>Needs intervention</span><strong>{@snapshot["notification_backlog"]["exhausted"]}</strong>
        <span class="footnote">Automatic retries exhausted</span>
      </.link>
      <.link patch={NotificationNavigation.path()} class="panel delivery-stat">
        <span>Outstanding</span><strong>{backlog_total(@snapshot)}</strong>
        <span class="footnote">Queued, retrying, in progress or exhausted</span>
      </.link>
    </div>
    <section class="panel" id="notifications" aria-labelledby="notifications-heading">
      <div class="panel-heading">
        <h2 id="notifications-heading">Delivery history</h2><span class="badge">{backlog_total(
          @snapshot
        )} outstanding</span>
      </div>
      <form
        id="notification-filters"
        class="inventory-filters delivery-filters"
        phx-change="notification_filter"
        phx-submit="notification_filter"
      >
        <div class="field">
          <label for="notification-status">Delivery status</label>
          <select id="notification-status" name="notification_status">
            <option
              :for={{value, label} <- notification_status_options()}
              value={value}
              selected={@delivery_page["status"] == value}
            >
              {label}
            </option>
          </select>
        </div>
        <button class="button" type="submit">Apply filter</button>
        <p class="footnote inventory-filter-help">
          Counts above cover the installation. Outstanding work lists exhausted retries first, then retrying, queued and in-progress delivery; oldest first within each state.
        </p>
      </form>
      <div :if={@snapshot["occurrences"] == []} class="empty" id="notification-empty">
        <h3>No notifications match this status</h3><p>
          Choose another status to inspect retained delivery history.
        </p>
      </div>
      <div :if={@snapshot["occurrences"] != []} class="table-wrap">
        <table class="notifications-table inventory-table" role="table">
          <thead role="rowgroup">
            <tr role="row">
              <th role="columnheader" scope="col">Notification</th><th role="columnheader" scope="col">
                Delivery
              </th><th role="columnheader" scope="col">
                Latest attempt
              </th><th role="columnheader" scope="col">Created</th>
            </tr>
          </thead>
          <tbody role="rowgroup">
            <tr
              :for={occurrence <- @snapshot["occurrences"]}
              id={"notification-row-" <> occurrence["id"]}
              role="row"
            >
              <td role="cell" data-label="Notification">
                <.link navigate={
                  NotificationNavigation.detail_path(occurrence["id"], @delivery_return_to)
                }><strong>{notification_check_label(occurrence)}</strong></.link><div class="sub">
                  {notification_title(occurrence)}
                </div>
              </td>
              <td role="cell" data-label="Delivery">
                <.badge value={occurrence["status"]} /><div
                  :if={occurrence["waiting_on_gates"]}
                  class="sub"
                >
                  Held by {Enum.map_join(occurrence["gates"] || [], " and ", &humanize/1)}
                </div><div :if={occurrence["next_retry_at"]} class="sub">
                  Next eligible attempt {retry_time(occurrence["next_retry_at"], @now)}
                </div>
              </td>
              <td role="cell" data-label="Latest attempt">
                <span :if={occurrence["latest_attempt"]}>{attempt_result(occurrence["latest_attempt"])}</span><span :if={
                  !occurrence["latest_attempt"]
                }>Not attempted</span><div class="sub">
                  {occurrence["attempt_count"] || 0} {plural(
                    occurrence["attempt_count"] || 0,
                    "attempt"
                  )}
                </div>
              </td>
              <td role="cell" data-label="Created">
                <time datetime={occurrence["inserted_at"]} title={time(occurrence["inserted_at"])}>{age(
                  occurrence["inserted_at"],
                  @now
                )}</time>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.notification_pages
        page={@delivery_page}
        returned={length(@snapshot["occurrences"])}
        filters={@filters}
      />
    </section>
    <details
      phx-mounted={JS.ignore_attributes("open")}
      class="panel disclosure space-top"
      id="delivery-explanation"
    >
      <summary>Delivery, retries and receiver acceptance</summary>
      <div class="panel-body">
        <p>
          Notifications survive controller restart. Acknowledgement and maintenance can hold failure delivery while checks continue running. Open a notification to inspect its controls, receiver and attempts.
        </p><p class="space-top">
          Delivery is at least once: a receiver may accept a message before its reply is lost. Retrying can deliver the same notification again. For email, acceptance means the SMTP relay accepted the message; it does not establish inbox delivery or that anyone read it.
        </p><p class="space-top">
          This list includes retained history. Completed records expire under the installation's retention policy; unresolved delivery remains inspectable.
        </p>
      </div>
    </details>
    """
  end

  def notification_detail(assigns) do
    assigns = assign(assigns, occurrence: get_in(assigns.inspection || %{}, ["occurrence"]))

    assigns =
      assign(assigns,
        detail_return:
          if(assigns.occurrence,
            do: NotificationNavigation.detail_path(assigns.occurrence["id"], assigns.return_to)
          )
      )

    ~H"""
    <.link navigate={@return_to || "/notifications"} class="back">← Back to notifications</.link>
    <div class="page-heading">
      <div>
        <div class="eyebrow">Notification delivery</div><h1>
          {if @occurrence, do: notification_check_label(@occurrence), else: "Notification not found"}
        </h1><p>Delivery status, controls and attempts for one original notification.</p>
      </div>
    </div>
    <div :if={!@occurrence} class="notice">This notification is not in retained history.</div>
    <div :if={@occurrence} class="notification-detail stack">
      <section class="panel" aria-label="Notification detail">
        <div class="panel-heading">
          <h2>Delivery status</h2>
        </div>
        <.occurrence_list
          occurrences={[@occurrence]}
          now={@now}
          return_to={@detail_return}
          retry_drafts={@retry_drafts}
        />
      </section>
      <section class="panel" id="notification-attempt-history">
        <div class="panel-heading">
          <h2>Delivery attempts</h2>
        </div>
        <.attempts_table
          attempts={@inspection["attempts"]}
          occurrences={[@occurrence]}
          now={@now}
          current_notification_id={@occurrence["id"]}
        />
        <.inspection_limit
          counts={@inspection["notification_attempts"]}
          label="attempts for this notification"
        />
      </section>
      <details
        phx-mounted={JS.ignore_attributes("open")}
        class="panel disclosure"
        id="notification-worker-diagnostics"
      >
        <summary>Worker diagnostics for this notification</summary><div class="panel-body">
          <p>
            At most thirty recent jobs are shown. A held job remains durable; it does not create a new notification or prove receiver acceptance.
          </p><pre tabindex="0" role="region" aria-label="Notification worker jobs">{Jason.encode!(@inspection["jobs"], pretty: true)}</pre>
        </div>
      </details>
    </div>
    """
  end

  defp notification_status_options do
    [
      {"unresolved", "Outstanding"},
      {"exhausted", "Exhausted automatic retries"},
      {"pending", "Queued"},
      {"retrying", "Retry pending"},
      {"delivering", "Attempt in progress"},
      {"delivered", "Accepted by receiver"},
      {"superseded", "Superseded"},
      {"all", "All retained history"}
    ]
  end

  defp notification_pages(assigns) do
    assigns =
      assign(assigns, pages: max(1, ceil(assigns.page["total"] / assigns.page["page_size"])))

    ~H"""
    <div class="panel-footer pagination" id="notification-pagination">
      <.link
        :if={@page["page"] > 1}
        patch={
          NotificationNavigation.path(
            Map.merge(%{}, %{
              "notification_status" => @page["status"],
              "notification_page" => @page["page"] - 1
            })
          )
        }
      >Previous notifications</.link>
      <span id="occurrence-subset">Page {@page["page"]} of {@pages} · {@returned} shown · {@page[
        "total"
      ]} matching {if @page["total"] == 1, do: "notification", else: "notifications"}</span>
      <.link
        :if={@page["page"] < @pages}
        patch={
          NotificationNavigation.path(
            Map.merge(%{}, %{
              "notification_status" => @page["status"],
              "notification_page" => @page["page"] + 1
            })
          )
        }
      >Next notifications</.link>
    </div>
    """
  end

  defp notification_kind("firing"), do: "Failure notification"
  defp notification_kind("resolved"), do: "Incident ended notification"
  defp notification_kind("update"), do: "Severity change notification"
  defp notification_kind(value), do: humanize(value)

  defp notification_title(%{
         "monitoring_incident_id" => id,
         "kind" => "resolved",
         "payload" => %{"closure_reason" => "monitoring_restored"}
       })
       when is_binary(id), do: "Monitoring restored notification"

  defp notification_title(%{"monitoring_incident_id" => id, "kind" => "resolved"})
       when is_binary(id), do: "Monitoring ended notification"

  defp notification_title(%{"monitoring_incident_id" => id}) when is_binary(id),
    do: "Monitoring lost notification"

  defp notification_title(occurrence), do: notification_kind(occurrence["kind"])

  def notification_focus(occurrences),
    do:
      Enum.find(occurrences, &(&1["status"] not in ["delivered", "superseded"])) ||
        List.first(occurrences)

  def notification_explanation(%{"status" => "delivered"}),
    do: "The receiver accepted this notification. This does not mean a person read it."

  def notification_explanation(%{"status" => "superseded"}),
    do:
      "This notification is no longer needed because the incident or its severity changed. It will not be retried."

  def notification_explanation(%{"status" => "exhausted"}),
    do:
      "Automatic delivery attempts have stopped. Inspect the receiver failure; restoring the receiver alone will not restart this notification."

  def notification_explanation(%{"status" => "retrying"}),
    do:
      "Delivery was rejected or its outcome is uncertain. The same notification will be retried when eligible."

  def notification_explanation(%{"status" => "delivering"}),
    do: "A delivery attempt is in progress. Receiver acceptance is not yet confirmed."

  def notification_explanation(%{"attempt_count" => count}) when count > 0,
    do:
      "This notification is waiting for another eligible delivery attempt. Its earlier attempts remain in the history."

  def notification_explanation(_),
    do: "This notification is waiting for its first eligible delivery attempt."

  def attempt_result(attempt) do
    "#{badge_text(attempt["status"])} · #{attempt_response(attempt)}"
  end

  defp attempt_response(%{"http_status" => status}) when is_integer(status), do: "HTTP #{status}"
  defp attempt_response(%{"status" => "accepted"}), do: "SMTP relay accepted"
  defp attempt_response(attempt), do: attempt["error"] || "No receiver response yet"

  def retry_time(value, now) do
    if active_gate?(value, now),
      do: time(value),
      else: "Scheduled for #{time(value)}; eligible now"
  end

  defp attempt_notification_label(attempt, occurrences) do
    occurrence = find(occurrences, attempt["occurrence_id"])

    scope =
      if occurrence["condition_incident_id"],
        do: notification_requested_scope(occurrence),
        else: notification_title(occurrence)

    "#{notification_check_label(occurrence)} · #{scope}"
  end

  defp notification_check_label(%{"monitoring_incident_id" => id} = occurrence)
       when is_binary(id),
       do: occurrence["check_label"] || "Monitoring loss"

  defp notification_check_label(%{"condition_incident_id" => id} = occurrence) when is_binary(id),
    do:
      occurrence["check_label"] || get_in(occurrence, ["payload", "condition", "label"]) ||
        "Shared condition"

  defp notification_check_label(occurrence) do
    [
      label(%{"id" => occurrence["assignment_id"], "label" => occurrence["check_label"]}),
      get_in(occurrence, ["payload", "result_key"]),
      if(get_in(occurrence, ["payload", "target"]),
        do: target_label(occurrence["payload"]["target"])
      )
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp notification_requested_scope(occurrence) do
    case get_in(occurrence, ["payload", "requested_fact"]) do
      %{"kind" => "severity", "key" => health} -> badge_text(health) <> " severity"
      %{"kind" => "impact", "label" => label} -> label
      _ -> "Incident ended · " <> humanize(get_in(occurrence, ["payload", "closure_reason"]))
    end
  end

  defp notification_result_path(occurrence) do
    case get_in(occurrence, ["payload", "stream_id"]) do
      nil -> "/resources/" <> occurrence["assignment_id"]
      id -> "/checks/" <> id
    end
  end

  defp attempt_notification_path(attempt, occurrences) do
    occurrence = find(occurrences, attempt["occurrence_id"])

    id =
      occurrence["monitoring_incident_id"] || occurrence["condition_incident_id"] ||
        occurrence["incident_id"]

    if is_binary(id) do
      query =
        if occurrence["condition_incident_id"],
          do: "?" <> URI.encode_query(%{"notification_id" => occurrence["id"]}),
          else: ""

      notification_incident_path(occurrence) <>
        "#{query}#notification-#{attempt["occurrence_id"]}"
    end
  end

  defp notification_incident_path(%{"monitoring_incident_id" => id}) when is_binary(id),
    do: "/monitoring-incidents/" <> id

  defp notification_incident_path(occurrence),
    do: "/incidents/" <> (occurrence["condition_incident_id"] || occurrence["incident_id"])

  def notification_gate_summary(occurrence) do
    gates = Enum.map_join(occurrence["gates"] || [], " and ", &humanize/1)

    if occurrence["gated_indefinitely"],
      do:
        "Waiting for #{gates}. Acknowledgement has no scheduled expiry and ends with the incident, a higher severity above its limit, a new impact, or an operator ending it.",
      else: "Waiting for #{gates} until #{acknowledgement_time(occurrence["gated_until"])}."
  end
end
