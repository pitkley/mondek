# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MonitoringIncidentsLive do
  use MondekWeb, :live_view
  alias Mondek.{Monitoring, MonitoringLoss}
  alias MondekWeb.AgentPrompts
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       navigation_counts: Mondek.Inspection.navigation_counts(now),
       page_title: "Monitoring loss",
       controller_url: MondekWeb.Endpoint.url(),
       filters: %{},
       selected_id: nil,
       listing: %{},
       incident: nil,
       draft: nil,
       error: nil,
       retry_drafts: %{},
       now: Monitoring.now()
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    origin = URI.parse(uri)

    filters = normalize_filters(params)

    socket =
      if params["id"] != socket.assigns.selected_id,
        do: assign(socket, draft: nil, error: nil, retry_drafts: %{}),
        else: socket

    {:noreply,
     socket
     |> assign(
       filters: filters,
       selected_id: params["id"],
       controller_url:
         URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port})
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    filters = socket.assigns.filters |> Map.drop(["page"]) |> Map.put("status", status)
    {:noreply, push_patch(socket, to: list_path(filters))}
  end

  def handle_event("edit_acknowledgement", form, socket),
    do: {:noreply, keep_draft(socket, form)}

  def handle_event("review_acknowledgement", _form, socket) do
    socket = refresh(socket)

    draft =
      Map.merge(
        socket.assigns.draft || %{},
        Map.take(draft(socket.assigns.incident), ~w(_revision _attention_revision))
      )

    {:noreply, assign(socket, draft: draft, error: nil)}
  end

  def handle_event("acknowledge", form, socket) do
    socket = keep_draft(socket, form)

    result =
      with nil <- socket.assigns.error,
           {:ok, options} <- options(socket.assigns.draft),
           do:
             MonitoringLoss.acknowledge(
               socket.assigns.selected_id,
               options,
               socket.assigns.draft["note"],
               Monitoring.now()
             )

    acknowledge_result(socket, result)
  end

  def handle_event("end_acknowledgement", _form, socket) do
    values = socket.assigns.draft || %{}

    options = %{
      "mode" => "end",
      "revision" => integer(values["_revision"]),
      "attention_revision" => integer(values["_attention_revision"])
    }

    result =
      MonitoringLoss.acknowledge(
        socket.assigns.selected_id,
        options,
        "Acknowledgement ended by local operator",
        Monitoring.now()
      )

    acknowledge_result(socket, result)
  end

  def handle_event("edit_retry", %{"_id" => id, "reason" => reason}, socket)
      when is_binary(reason) and byte_size(reason) <= 500 do
    {:noreply, assign(socket, retry_drafts: Map.put(socket.assigns.retry_drafts, id, reason))}
  end

  def handle_event("retry_notification", %{"_id" => id, "reason" => reason}, socket) do
    permitted =
      Enum.any?((socket.assigns.incident || %{})["occurrences"] || [], &(&1["id"] == id))

    result =
      if permitted, do: Monitoring.retry_notification(id, reason), else: {:error, :not_found}

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(retry_drafts: Map.delete(socket.assigns.retry_drafts, id))
         |> refresh()
         |> clear_flash(:error)
         |> put_flash(
           :info,
           "Retry requested for the original notification; active holds still apply."
         )}

      {:error, reason} ->
        {:noreply, socket |> refresh() |> put_flash(:error, error_text(reason))}
    end
  end

  defp acknowledge_result(socket, {:ok, _}) do
    {:noreply,
     socket
     |> assign(draft: nil, error: nil)
     |> refresh()
     |> put_flash(
       :info,
       "Acknowledgement updated. Monitoring and target-health incidents remain visible."
     )}
  end

  defp acknowledge_result(socket, {:error, reason}),
    do: {:noreply, socket |> refresh() |> assign(error: error_text(reason))}

  defp acknowledge_result(socket, reason),
    do: {:noreply, assign(socket, error: error_text(reason))}

  defp refresh(socket) do
    now = Monitoring.now()

    socket =
      assign(socket,
        now: now,
        navigation_counts: Mondek.Inspection.navigation_counts(now)
      )

    if socket.assigns.selected_id do
      incident = MonitoringLoss.detail(socket.assigns.selected_id, now, socket.assigns.filters)

      assign(socket,
        now: now,
        incident: incident,
        draft: socket.assigns.draft || draft(incident)
      )
    else
      assign(socket, now: now, listing: MonitoringLoss.list(socket.assigns.filters, now))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={:incidents}
      page_title="Incidents"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
      main_class="monitoring-loss-page"
    >
      <MondekWeb.Layouts.section_header
        section="Incidents"
        description="Investigate target health and missing monitoring, with controls for their notifications."
        nav_label="Incident views"
      >
        <:tabs>
          <.link navigate="/incidents">Target health</.link><.link
            navigate="/monitoring-incidents"
            aria-current="page"
          >Monitoring loss</.link>
        </:tabs>
      </MondekWeb.Layouts.section_header>
      <.link
        :if={@live_action == :show}
        navigate={@filters["return_to"] || list_path(Map.drop(@filters, ["members_page"]))}
        class="back"
      >{if @filters["return_to"],
        do: monitoring_return_label(@filters["return_to"]),
        else: "← Monitoring loss incidents"}</.link>
      <div class="page-heading view-heading">
        <div>
          <h2>{if @incident, do: @incident["label"], else: "Monitoring loss"}</h2><p>
            Missing or unusable measurements are separate from a measured target failure.
          </p>
        </div>
      </div>
      <.listing :if={@live_action == :index} listing={@listing} filters={@filters} now={@now} />
      <p :if={@live_action == :show && !@incident} class="notice warn">
        This monitoring incident is not in retained history.
      </p>
      <.detail
        :if={@incident && @live_action == :show}
        incident={@incident}
        now={@now}
        filters={@filters}
        draft={@draft}
        error={@error}
        retry_drafts={@retry_drafts}
      />
      <AgentPrompts.library
        :if={@incident}
        id="monitoring-incident-prompts"
        kinds={[:incident]}
        context={
          %{
            "controller_url" => @controller_url,
            "incident_id" => @incident["id"],
            "incident_kind" => "monitoring_loss",
            "incident_status" => @incident["status"],
            "incident_reason" => @incident["closure_reason"],
            "runner_id" => @incident["runner_id"],
            "source_id" => @incident["source_id"],
            "contributor_count" => @incident["member_count"],
            "page_path" => "/monitoring-incidents/" <> @incident["id"]
          }
        }
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp listing(assigns) do
    ~H"""
    <p class="notice info notice-copy" id="monitoring-loss-explanation">
      After a grace period, losses on the same runner share one incident. Declared results with no selected runner share a source incident. Fresh measurements restore visibility. Runner control outages also require renewed control contact; a healthy heartbeat alone does not restore measurements. These incidents do not change target health.
    </p>
    <form phx-submit="filter" class="monitoring-loss-filters space-top" id="monitoring-loss-filters">
      <div class="field">
        <label for="loss-status">Status</label><select id="loss-status" name="status"><option
          :for={{value, label} <- [{"open", "Open"}, {"closed", "Closed"}, {"all", "All history"}]}
          value={value}
          selected={(@filters["status"] || "open") == value}
        >
          {label}
        </option></select>
      </div><button class="button">Apply filters</button><.link
        :if={@filters["runner_id"] || @filters["source_id"]}
        navigate="/monitoring-incidents"
        class="text-link"
      >Clear runner/source filter</.link>
    </form>
    <p :if={@filters["runner_id"] || @filters["source_id"]} class="footnote space-top">
      Showing only the selected {if @filters["runner_id"], do: "runner", else: "source"}.
    </p>
    <section class="panel space-top" id="monitoring-incident-list">
      <div class="panel-heading">
        <h2>Monitoring loss incidents</h2><span class="badge">{if @filters["runner_id"] ||
                                                                    @filters["source_id"],
                                                                  do: "Overall: "}{@listing[
          "open_count"
        ] || 0} open · {@listing[
          "unacknowledged_count"
        ] || 0} unacknowledged</span>
      </div>
      <div :if={@listing["items"] == []} class="empty">
        <h3>No matching monitoring incidents</h3><p>
          Brief gaps stay within the grace period. Coverage shows declared intent and current measurements.
        </p><.link navigate="/coverage" class="text-link">Inspect coverage</.link>
      </div>
      <div
        :for={incident <- @listing["items"] || []}
        id={"monitoring-incident-" <> incident["id"]}
        class={[
          "resource monitoring-loss-row",
          Monitoring.acknowledgement_active?(incident, @now) && "monitoring-loss-acknowledged"
        ]}
      >
        <div class="resource-name">
          <h3><.link navigate={detail_path(incident["id"], @filters)}>{incident["label"]}</.link></h3><span class={
            status_class(incident)
          }>{status_text(incident)}</span><span
            :if={Monitoring.acknowledgement_active?(incident, @now)}
            class="badge acknowledged"
          >✓ Acknowledged</span>
        </div>
        <p class="resource-subtitle">
          {scope_label(incident)} · {incident["member_count"]} {if incident["status"] == "closed",
            do: "last affected results",
            else: "affected results"}
        </p>
        <div class="resource-meta">
          <span>Opened{" "}<time datetime={incident["opened_at"]}>{time(incident["opened_at"])}</time></span><span :if={
            Monitoring.acknowledgement_active?(incident, @now)
          }>Failure notifications held</span>
        </div>
      </div>
      <.pagination listing={@listing} filters={@filters} />
    </section>
    <p class="footnote space-top">
      Unacknowledged incidents appear first. Acknowledgement holds notifications for this monitoring episode; it does not acknowledge target-health incidents. An independent external observer is needed to detect a completely unavailable controller.
    </p>
    """
  end

  defp detail(assigns) do
    assigns =
      assign(assigns,
        active: Monitoring.acknowledgement_active?(assigns.incident, assigns.now),
        stale: stale?(assigns.draft, assigns.incident)
      )

    ~H"""
    <section class="panel monitoring-loss-summary" id="monitoring-loss-summary">
      <div class="panel-heading">
        <h2>{status_text(@incident)}</h2><span :if={@active} class="badge acknowledged">✓ Acknowledged</span>
      </div><div class="panel-body">
        <p>{closure_text(@incident)}</p><dl class="result-context space-top">
          <div>
            <dt>Scope</dt><dd>{scope_label(@incident)}</dd>
          </div><div>
            <dt>Opened</dt><dd>{time(@incident["opened_at"])}</dd>
          </div><div :if={@incident["closed_at"]}>
            <dt>Ended</dt><dd>{time(@incident["closed_at"])}</dd>
          </div><div>
            <dt>
              {if @incident["status"] == "closed",
                do: "Last affected results",
                else: "Affected results"}
            </dt><dd>{@incident["member_count"]}</dd>
          </div>
        </dl><p class="footnote space-top">
          Target-health incidents and their acknowledgements remain independent. A restored measurement can still report Warning or Critical health.
        </p>
      </div>
    </section>
    <div class="details-grid incident-layout space-top">
      <div class="stack incident-summary">
        <section
          :if={
            @incident["status"] == "closed" && @incident["closure_reason"] == "monitoring_restored"
          }
          class="panel"
          id="monitoring-restoration-evidence"
        >
          <div class="panel-heading">
            <h2>Restoration evidence</h2>
          </div>
          <p class="panel-body">
            These fresh measurements closed the final remaining losses. Earlier partial restorations are not a complete contribution timeline. Source time is the age of the measurement, independent of when it arrived.
          </p>
          <p :if={(@incident["closing_evidence"] || []) == []} class="panel-body">
            No closing measurement references are retained for this historical episode.
          </p>
          <div :for={evidence <- @incident["closing_evidence"] || []} class="resource">
            <div class="resource-name">
              <h3>{evidence["label"] || "Restored measurement"}</h3><span
                :if={evidence["health"]}
                class="badge"
              >Measured health: {evidence["health"]}</span><span
                :if={!evidence["health"]}
                class="badge fresh"
              >Fresh coverage</span>
            </div><p class="space-top">
              Source time: <time datetime={evidence["source_at"]}>{time(evidence["source_at"])}</time>
            </p><p :if={evidence["generation"]} class="footnote">
              Configuration version {evidence["generation"]}
            </p><p :if={evidence["observation_id"]} class="footnote">
              Observation <code>{evidence["observation_id"]}</code>
            </p><.link
              :if={member_path(evidence)}
              navigate={member_link(evidence, @incident["id"], @filters)}
              class="text-link"
            >Inspect current {if evidence["stream_id"], do: "measurement", else: "coverage"}</.link>
          </div>
          <p class="panel-footer">
            Up to 100 final restoration references are retained. Measured Warning or Critical health can restore monitoring visibility.
          </p>
        </section>
        <section class="panel" id="monitoring-members">
          <div class="panel-heading">
            <h2>
              {if @incident["status"] == "open", do: "Affected results", else: "Last affected results"}
            </h2><span class="badge">{get_in(@incident, ["members", "total"]) || 0}</span>
          </div>
          <p :if={get_in(@incident, ["members", "items"]) == []} class="panel-body">
            No active losses remain. Notification history retains the original affected scope.
          </p>
          <div
            :for={member <- get_in(@incident, ["members", "items"]) || []}
            class="resource monitoring-loss-member"
          >
            <div class="resource-name">
              <h3>{member["label"] || member["key"]}</h3><span class="badge pending">{knowledge(
                member["knowledge"]
              )}</span>
            </div><p class="resource-subtitle">
              {target(member["target"])} · {member["environment"] ||
                "Monitored environment not declared"}
            </p><p class="footnote">Loss observed since {time(member["since_at"])}</p><.link
              :if={member_path(member)}
              navigate={member_link(member, @incident["id"], @filters)}
              class="text-link"
            >{if member["stream_id"] || member["assignment_id"],
              do: "Investigate measurement",
              else: "Inspect intended result"}</.link>
          </div>
          <.pagination
            listing={@incident["members"] || %{}}
            filters={@filters}
            incident_id={@incident["id"]}
          />
          <p :if={get_in(@incident, ["members", "truncated"])} class="panel-footer">
            This historical snapshot retains {get_in(@incident, ["members", "total"])} of {get_in(
              @incident,
              ["members", "affected_total"]
            )} affected results. The full former membership is no longer available.
          </p>
        </section>
      </div>
      <aside class="stack incident-controls" aria-label="Monitoring incident controls">
        <section class="panel" id="monitoring-acknowledgement">
          <div class="panel-heading">
            <h2>Acknowledgement</h2>
          </div><div class="panel-body">
            <p id="monitoring-ack-scope">
              Covers all monitoring loss on this {if @incident["scope_kind"] == "runner",
                do: "runner",
                else: "source"} while this acknowledgement is active in this episode, including results added later. Target-health acknowledgements are separate.
            </p>
            <div
              :if={@active}
              id="active-monitoring-acknowledgement"
              class="notice notice-copy space-top"
            >
              <strong>Acknowledged</strong><p>{@incident["acknowledgement_note"]}</p><p class="footnote">
                {if @incident["acknowledgement_mode"] == "until_incident_ends",
                  do: "Until this monitoring incident ends",
                  else: "Until " <> time(@incident["acknowledged_until"])}
              </p>
            </div>
            <p :if={@incident["status"] != "open"} class="space-top">
              This episode has ended. Previous controls remain in the history.
            </p>
            <form
              :if={@incident["status"] == "open"}
              id="monitoring-acknowledgement-form"
              phx-submit="acknowledge"
              phx-change="edit_acknowledgement"
              phx-auto-recover="edit_acknowledgement"
              class="attention-form"
            >
              <input type="hidden" name="_revision" value={@draft["_revision"]} /><input
                type="hidden"
                name="_attention_revision"
                value={@draft["_attention_revision"]}
              />
              <div :if={@error || @stale} id="monitoring-ack-error" class="form-error" role="alert">
                {@error ||
                  "This incident or its acknowledgement changed. Review the current state before saving."}<button
                  :if={@stale}
                  type="button"
                  id="review-monitoring-acknowledgement"
                  phx-click="review_acknowledgement"
                  class="button small space-top"
                >Review current state</button>
              </div>
              <div class="field">
                <label for="monitoring-ack-note">Operator note</label><textarea
                  id="monitoring-ack-note"
                  name="note"
                  required
                  maxlength="500"
                >{@draft["note"]}</textarea>
              </div>
              <div class="field">
                <label for="monitoring-ack-mode">Acknowledge until</label><select
                  id="monitoring-ack-mode"
                  name="mode"
                ><option
                  :for={
                    {value, label} <- [
                      {"until_incident_ends", "This monitoring incident ends"},
                      {"duration", "A duration has passed"},
                      {"until", "A specific date and time (UTC)"}
                    ]
                  }
                  value={value}
                  selected={@draft["mode"] == value}
                >
                  {label}
                </option></select>
              </div>
              <div :if={@draft["mode"] == "duration"} class="field">
                <label for="monitoring-ack-hours">Duration in hours</label><input
                  id="monitoring-ack-hours"
                  name="hours"
                  type="number"
                  min="1"
                  step="1"
                  value={@draft["hours"]}
                  required
                />
              </div>
              <div :if={@draft["mode"] == "until"} class="field">
                <label for="monitoring-ack-until">Expiry date and time (UTC)</label><input
                  id="monitoring-ack-until"
                  name="expires_at"
                  type="datetime-local"
                  step="1"
                  max="9999-12-31T23:59:59"
                  value={@draft["expires_at"]}
                  required
                /><small>Enter UTC, regardless of your device's timezone.</small>
              </div>
              <button class="button" disabled={@stale} phx-disable-with="Recording…">{if @active,
                do: "Update acknowledgement",
                else: "Acknowledge monitoring loss"}</button>
            </form>
            <button
              :if={@active}
              id="end-monitoring-acknowledgement"
              phx-click="end_acknowledgement"
              class="button small space-top"
              disabled={@stale}
            >End acknowledgement</button>
          </div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <h2>Maintenance</h2>
          </div><div class="panel-body">
            <p>
              Check and target maintenance holds a monitoring-loss notification when every affected result is covered. A partial window leaves uncovered losses eligible.
            </p><.link navigate="/maintenance" class="text-link space-top">Review maintenance windows</.link>
          </div>
        </section>
      </aside>
      <div class="stack incident-history">
        <section class="panel" id="monitoring-notifications">
          <div class="panel-heading">
            <h2>Notification history</h2>
          </div>
          <p :if={(@incident["occurrences"] || []) == []} class="panel-body">
            No notification work is recorded.
          </p>
          <div
            :for={occurrence <- @incident["occurrences"] || []}
            class="resource"
            id={"notification-" <> occurrence["id"]}
          >
            <div class="resource-name">
              <h3>{notification_heading(occurrence)}</h3><span class="badge">{delivery_status(
                occurrence
              )}</span>
            </div><p class="footnote space-top">
              Created {time(occurrence["inserted_at"])} · {occurrence["attempt_count"] || 0} delivery attempts
            </p>
            <p :if={occurrence["waiting_on_gates"]} class="notice notice-copy space-top">
              Failure notification held by {Enum.map_join(
                occurrence["gates"] || [],
                " and ",
                &String.replace(&1, "_", " ")
              )}. Ending one control leaves other active controls in effect.
            </p>
            <p :if={occurrence["next_retry_at"]} class="footnote">
              Next eligible attempt: {time(occurrence["next_retry_at"])}
            </p>
            <p :if={occurrence["latest_attempt"]} class="space-top">
              Latest attempt: {attempt_description(occurrence["latest_attempt"])}
            </p>
            <p :for={window <- occurrence["maintenance_windows"] || []} class="footnote">
              <.link navigate={"/maintenance/" <> window["id"]} class="text-link">Maintenance: {window[
                "name"
              ] || window["reason"] || window["id"]}</.link>
            </p>
            <details class="space-top" phx-mounted={JS.ignore_attributes("open")}>
              <summary>Delivery identity and original payload</summary><p class="footnote">
                Destination: {occurrence["destination"]}
              </p><pre>{Jason.encode!(occurrence["payload"], pretty: true)}</pre>
            </details>
            <form
              :if={occurrence["can_retry"]}
              id={"retry-monitoring-notification-" <> occurrence["id"]}
              class="attention-form space-top"
              phx-submit="retry_notification"
              phx-change="edit_retry"
              phx-auto-recover="edit_retry"
            >
              <input type="hidden" name="_id" value={occurrence["id"]} /><div class="field">
                <label for={"retry-reason-" <> occurrence["id"]}>Retry reason</label><input
                  id={"retry-reason-" <> occurrence["id"]}
                  name="reason"
                  required
                  maxlength="500"
                  value={@retry_drafts[occurrence["id"]] || ""}
                />
              </div><p class="footnote">
                Starts a new budget for the original notification. Duplicate delivery is possible; active acknowledgement and maintenance still hold failure notifications.
              </p><button class="button" phx-disable-with="Requesting…">Retry notification</button>
            </form>
          </div><p class="panel-footer">
            Original notification scope and destination are preserved across retries. Showing {length(
              @incident["occurrences"] || []
            )} of {get_in(@incident, ["limits", "occurrences", "total"]) ||
              length(@incident["occurrences"] || [])} notifications; the most recent 100 are available here.
          </p>
        </section>
        <details
          class="panel disclosure"
          id="monitoring-control-history"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Operator control history</summary><p :if={(@incident["controls"] || []) == []}>
            No controls recorded.
          </p><div :for={control <- @incident["controls"] || []} class="resource">
            <h3>{String.replace(control["kind"] || "Acknowledgement", "_", " ")}</h3><p>
              {control["reason"]}
            </p><small>{control["actor"]} · {time(control["inserted_at"])}</small>
          </div><p class="footnote">
            Showing {length(@incident["controls"] || [])} of {get_in(@incident, [
              "limits",
              "controls",
              "total"
            ]) || length(@incident["controls"] || [])} controls; the most recent 100 are available here.
          </p>
        </details>
      </div>
    </div>
    """
  end

  attr :listing, :map, required: true
  attr :filters, :map, required: true
  attr :incident_id, :string, default: nil

  defp pagination(assigns) do
    assigns =
      assign(assigns,
        pages:
          max(1, ceil((assigns.listing["total"] || 0) / (assigns.listing["page_size"] || 25))),
        page: assigns.listing["page"] || 1
      )

    ~H"""
    <nav
      class="pagination panel-footer"
      aria-label={if @incident_id, do: "Affected results pages", else: "Monitoring incident pages"}
    >
      <span>Page {@page} of {@pages} · {@listing["total"] || 0} results</span><div class="pagination-actions">
        <.link
          :if={@page > 1}
          patch={page_path(@filters, @incident_id, @page - 1)}
          class="button small"
        >Previous</.link><.link
          :if={@page < @pages}
          patch={page_path(@filters, @incident_id, @page + 1)}
          class="button small"
        >Next</.link>
      </div>
    </nav>
    """
  end

  defp list_path(filters), do: MondekWeb.MonitoringIncidentNavigation.list_path(filters)

  defp detail_path(id, filters),
    do: MondekWeb.MonitoringIncidentNavigation.detail_path(id, filters)

  defp page_path(filters, id, page),
    do: MondekWeb.MonitoringIncidentNavigation.page_path(filters, id, page)

  defp scope_label(%{"scope_kind" => "runner"}), do: "Runner monitoring"
  defp scope_label(_), do: "Source coverage"
  defp status_text(%{"status" => "open"}), do: "Monitoring loss"
  defp status_text(%{"closure_reason" => "monitoring_restored"}), do: "Monitoring restored"
  defp status_text(_), do: "Closed"
  defp status_class(%{"status" => "open"}), do: "badge monitoring-loss-badge"
  defp status_class(%{"closure_reason" => "monitoring_restored"}), do: "badge fresh"
  defp status_class(_), do: "badge historical"

  defp closure_text(%{"status" => "open", "scope_kind" => "coverage"}),
    do:
      "These declared results have no selected runner, or are still waiting for a newly selected runner to establish fresh measurements. Inspect an intended result to see its placement requirements."

  defp closure_text(%{"status" => "open"}),
    do:
      "Measurements or runner control contact are missing for the results below. Recent uploads can still arrive when control contact is overdue."

  defp closure_text(%{"closure_reason" => "monitoring_restored"}),
    do:
      "Fresh measurements restored monitoring for this episode. This confirms visibility, not healthy targets."

  defp closure_text(_),
    do:
      "The monitored scope was withdrawn. This administrative closure does not establish restored monitoring or target recovery."

  defp knowledge("stale"), do: "Overdue"
  defp knowledge("unavailable"), do: "Unavailable"
  defp knowledge("missing"), do: "No selected runner"
  defp knowledge("awaiting"), do: "Awaiting measurement"
  defp knowledge("runner_unreachable"), do: "Runner contact overdue"
  defp knowledge("control_contact_overdue"), do: "Control contact overdue"
  defp knowledge("no_selected_runner"), do: "No selected runner"
  defp knowledge("awaiting_new_measurement"), do: "Awaiting a new measurement"
  defp knowledge("awaiting_coverage_measurement"), do: "Awaiting coverage measurement"
  defp knowledge(value), do: value || "Measurement unavailable"

  defp target(value) when is_map(value),
    do: value["label"] || value["key"] || "Target not declared"

  defp target(_), do: "Target not declared"

  defp member_path(%{"stream_id" => id}) when is_binary(id),
    do: "/checks/" <> id <> "/diagnostics"

  defp member_path(%{"assignment_id" => id}) when is_binary(id),
    do: "/resources/" <> id <> "/diagnostics"

  defp member_path(%{"coverage_id" => id}) when is_binary(id), do: "/coverage/" <> id

  defp member_path(_), do: nil

  defp member_link(member, id, filters) do
    path = member_path(member)

    path <> "?" <> URI.encode_query(%{"return_to" => detail_path(id, filters)})
  end

  defdelegate return_path(value), to: MondekWeb.MonitoringIncidentNavigation

  defp normalize_filters(params),
    do: MondekWeb.MonitoringIncidentNavigation.normalize_filters(params)

  defp monitoring_return_label(path) do
    if String.starts_with?(path, "/notifications"),
      do: "← Back to notification delivery",
      else: "← Back to runner"
  end

  defp attempt_description(attempt) do
    status =
      case attempt["status"] do
        "accepted" -> "Accepted"
        "failed_or_ambiguous" -> "Failed or uncertain"
        value -> String.capitalize(String.replace(value || "Unknown", "_", " "))
      end

    [
      status,
      if(is_integer(attempt["http_status"]), do: "HTTP #{attempt["http_status"]}"),
      attempt["error"]
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp notification_heading(%{
         "kind" => "resolved",
         "payload" => %{"closure_reason" => "monitoring_restored"}
       }),
       do: "Monitoring restored"

  defp notification_heading(%{"kind" => "resolved"}), do: "Monitoring incident closed"
  defp notification_heading(_), do: "Monitoring lost"

  defp delivery_status(%{"status" => "delivered", "destination" => "mailto:" <> _}),
    do: "Mail relay accepted"

  defp delivery_status(%{"status" => "delivered"}), do: "Receiver accepted"
  defp delivery_status(%{"status" => "exhausted"}), do: "Retries exhausted"
  defp delivery_status(occurrence), do: String.capitalize(occurrence["status"] || "pending")
  defp time(nil), do: "—"
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M:%S UTC")

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> time(at)
      _ -> "Unknown"
    end
  end

  defp draft(nil), do: nil

  defp draft(incident) do
    timed =
      Monitoring.acknowledgement_active?(incident) && incident["acknowledgement_mode"] == "until"

    expires =
      if timed do
        case DateTime.from_iso8601(incident["acknowledged_until"]) do
          {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%dT%H:%M:%S")
          _ -> ""
        end
      else
        ""
      end

    %{
      "_revision" => incident["acknowledgement_revision"] || 0,
      "_attention_revision" => incident["attention_revision"] || 0,
      "mode" => if(timed, do: "until", else: "until_incident_ends"),
      "hours" => "24",
      "expires_at" => expires,
      "note" => incident["acknowledgement_note"] || ""
    }
  end

  defp stale?(draft, incident),
    do:
      integer(draft["_revision"]) != (incident["acknowledgement_revision"] || 0) or
        integer(draft["_attention_revision"]) != (incident["attention_revision"] || 0)

  defp keep_draft(socket, form) do
    values = Map.take(form, ~w(_revision _attention_revision mode hours expires_at note))

    if socket.assigns.draft &&
         Enum.all?(values, fn {_key, value} -> is_binary(value) and byte_size(value) <= 500 end),
       do: assign(socket, draft: Map.merge(socket.assigns.draft, values), error: nil),
       else: assign(socket, error: "Supply bounded text values for this acknowledgement.")
  end

  defp options(draft) do
    base = %{
      "mode" => draft["mode"],
      "revision" => integer(draft["_revision"]),
      "attention_revision" => integer(draft["_attention_revision"])
    }

    case draft["mode"] do
      "until_incident_ends" ->
        {:ok, base}

      "duration" ->
        {:ok, Map.put(base, "seconds", integer(draft["hours"]) * 3600)}

      "until" ->
        value = draft["expires_at"] || ""
        value = if byte_size(value) == 16, do: value <> ":00", else: value

        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC"),
             do: {:ok, Map.put(base, "expires_at", DateTime.to_iso8601(utc))},
             else: (_ -> {:error, "Enter a valid future date and time in UTC."})

      _ ->
        {:error, "Choose when acknowledgement should end."}
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> -1
    end
  end

  defp integer(_), do: -1

  defp error_text(:stale),
    do:
      "This incident or acknowledgement changed after review. Your draft is preserved; review the current state before saving."

  defp error_text({:invalid, value}), do: value
  defp error_text(value) when is_binary(value), do: value
  defp error_text(_), do: "The change could not be saved. Review the current state and try again."
end
