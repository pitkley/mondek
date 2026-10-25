# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.IncidentLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation
  import MondekWeb.NotificationComponents
  alias Mondek.Monitoring
  alias MondekWeb.AgentPrompts
  alias Phoenix.LiveView.JS
  import MondekWeb.MonitoringUI
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1000)

    {:ok,
     socket
     |> assign(
       selected_id: nil,
       return_to: nil,
       controller_url: MondekWeb.Endpoint.url(),
       filters: %{},
       listing: nil,
       retry_drafts: %{},
       acknowledgement_draft: nil,
       acknowledgement_error: nil,
       acknowledgement_notice: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    retained =
      if socket.assigns.selected_id == params["id"],
        do:
          Map.take(socket.assigns, [
            :retry_drafts,
            :acknowledgement_draft,
            :acknowledgement_error,
            :acknowledgement_notice
          ]),
        else: %{}

    socket =
      socket
      |> assign(
        selected_id: params["id"],
        return_to: safe_return_path(params["return_to"]),
        controller_url: controller_origin(uri),
        filters: inventory_params(params, socket.assigns.live_action),
        page_title: page_name(socket.assigns.live_action)
      )

    socket =
      socket
      |> assign(
        retry_drafts: %{},
        acknowledgement_draft: nil,
        acknowledgement_error: nil,
        acknowledgement_notice: nil
      )
      |> assign(retained)

    socket = refresh(socket)
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"])

    socket =
      assign(socket,
        acknowledgement_draft:
          socket.assigns.acknowledgement_draft ||
            if(incident, do: acknowledgement_draft(incident))
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  @impl true
  def handle_event("condition_notification_filter", params, socket) do
    status = params["notification_status"] || "all"
    current = get_in(socket.assigns.incident_inspection || %{}, ["notification_page", "status"])

    if status == current do
      {:noreply, socket}
    else
      filters =
        socket.assigns.filters
        |> Map.drop(~w(notification_page notification_id))
        |> Map.put("notification_status", status)

      {:noreply,
       push_patch(socket,
         to: condition_path(socket.assigns.selected_id, filters, socket.assigns.return_to),
         replace: true
       )}
    end
  end

  def handle_event("retry_notification", %{"_id" => id, "reason" => reason}, socket) do
    socket = keep_retry_draft(socket, id, reason)

    case Monitoring.retry_notification(id, reason) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(retry_drafts: Map.delete(socket.assigns.retry_drafts, id))
         |> refresh()
         |> clear_flash(:error)
         |> put_flash(
           :info,
           MondekWeb.NotificationRetry.success_message()
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:error, MondekWeb.NotificationRetry.error_message(reason))}
    end
  end

  def handle_event("edit_notification_retry", %{"_id" => id, "reason" => reason}, socket),
    do: {:noreply, keep_retry_draft(socket, id, reason)}

  def handle_event("end_acknowledgement", %{"id" => id} = form, socket) do
    options = %{
      "mode" => "end",
      "revision" => integer(form["revision"]),
      "attention_revision" => integer(form["attention_revision"])
    }

    case Monitoring.acknowledge(id, options, "Acknowledgement ended by local operator") do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh()
         |> reset_acknowledgement_draft()
         |> clear_flash(:error)
         |> put_flash(
           :info,
           if get_in(socket.assigns.incident_inspection || %{}, [
                "incident",
                "condition_incident_id"
              ]) do
             "Individual acknowledgement ended. A shared incident acknowledgement and maintenance may still hold notifications; checks and incident health are unchanged."
           else
             "Acknowledgement ended. Notification maintenance remains in effect if active; checks and incident health are unchanged."
           end
         )}

      {:error, reason} ->
        {:noreply, acknowledgement_failure(socket, reason)}
    end
  end

  def handle_event("edit_acknowledgement", form, socket),
    do: {:noreply, keep_acknowledgement_draft(socket, form)}

  def handle_event("review_acknowledgement", _form, socket) do
    socket = refresh(socket)
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"])

    if incident do
      draft =
        Map.merge(
          socket.assigns.acknowledgement_draft || acknowledgement_draft(incident),
          Map.take(
            acknowledgement_draft(incident),
            ~w(_id _revision _attention_revision _health reviewed_impacts)
          )
        )

      {:noreply,
       assign(socket,
         acknowledgement_draft: draft,
         acknowledgement_error: nil,
         acknowledgement_notice:
           "Current #{acknowledgement_subject(incident)} and acknowledgement reviewed. Your proposed settings and note are preserved."
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("acknowledge", %{"_id" => id} = form, socket) do
    socket = keep_acknowledgement_draft(socket, form)

    result =
      if socket.assigns.acknowledgement_error do
        {:error, socket.assigns.acknowledgement_error}
      else
        with {:ok, options} <- acknowledgement_options(socket.assigns.acknowledgement_draft),
             do: Monitoring.acknowledge(id, options, socket.assigns.acknowledgement_draft["note"])
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh()
         |> reset_acknowledgement_draft()
         |> clear_flash(:error)
         |> acknowledgement_recorded_flash()}

      {:error, reason} ->
        {:noreply, acknowledgement_failure(socket, reason)}
    end
  end

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = Monitoring.overview(at)

    socket =
      assign(socket, snapshot: snapshot, now: parse_time(snapshot["now"]) || DateTime.utc_now())

    detail =
      if socket.assigns.selected_id,
        do: Monitoring.incident_detail(socket.assigns.selected_id, at, socket.assigns.filters)

    socket = clear_stale_acknowledgement_flash(socket, detail, socket.assigns.now)

    discovery =
      if get_in(detail || %{}, ["stream", "id"]),
        do: Mondek.Discovery.inspect(detail["stream"]["id"], at)

    assign(socket,
      incident_inspection: detail,
      discovery_inspection: discovery,
      maintenance_windows: related_maintenance(detail)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={@live_action}
      page_title={page_name(@live_action)}
      snapshot={@snapshot}
      now={@now}
      flash={@flash}
    >
      <.incident_detail
        :if={@live_action == :incident}
        snapshot={@snapshot}
        inspection={@incident_inspection}
        discovery={@discovery_inspection}
        filters={@filters}
        controller_url={@controller_url}
        now={@now}
        retry_drafts={@retry_drafts}
        acknowledgement_draft={@acknowledgement_draft}
        acknowledgement_error={@acknowledgement_error}
        acknowledgement_notice={@acknowledgement_notice}
        maintenance_windows={@maintenance_windows}
        return_to={@return_to}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp incident_detail(assigns) do
    if condition_incident?(get_in(assigns.inspection || %{}, ["incident"]) || %{}) do
      condition_detail(assigns)
    else
      result_incident_detail(assigns)
    end
  end

  defp condition_detail(assigns) do
    detail = assigns.inspection
    incident = detail["incident"]

    assigns =
      assign(assigns,
        incident: incident,
        counts: detail["counts"],
        contributions: detail["contributions"],
        contribution_page: detail["contribution_page"],
        contradictions: detail["contradictions"],
        contradiction_page: detail["contradiction_page"],
        occurrences: detail["occurrences"],
        notification_page: detail["notification_page"],
        notification_counts: detail["notification_counts"],
        controls: detail["controls"],
        attempts: detail["attempts"],
        evidence: detail["evidence"],
        limits: detail["limits"],
        acknowledgement_active: Monitoring.acknowledgement_active?(incident, assigns.now),
        acknowledgement_draft: assigns.acknowledgement_draft || acknowledgement_draft(incident),
        investigation_path: condition_path(incident["id"], assigns.filters, assigns.return_to)
      )

    ~H"""
    <.link navigate={@return_to || "/incidents"} class="back"><.icon name="back" size={13} />{return_label(
      @return_to,
      "All incidents"
    )}</.link>
    <div class="page-heading" id="shared-incident-heading">
      <div>
        <div class="eyebrow">Shared incident</div><h1>{@incident["label"]}</h1>
        <p id="incident-environment">Monitored environment: {monitored_environment(@incident)}</p>
        <p>
          {@counts["open"]} currently failing {plural(@counts["open"], "result")} · {@counts[
            "recovered"
          ]} recovered · {@counts[
            "withdrawn"
          ]} withdrawn
        </p>
      </div>
      <div class="status-line">
        <span class="footnote">Incident severity</span><.badge value={@incident["health"]} /><.badge value={
          @incident["status"]
        } />
        <.link
          :if={@incident["status"] == "open"}
          href="#incident-acknowledgement"
          class="button"
          id="incident-acknowledgement-shortcut"
        >
          {if @acknowledgement_active, do: "Review acknowledgement", else: "Acknowledge incident"}
        </.link>
      </div>
    </div>
    <div class="details-grid incident-layout shared-incident-layout">
      <div class="stack incident-summary" id="incident-summary">
        <section class="panel" id="condition-status">
          <div class="panel-heading">
            <h2>
              {if @incident["status"] == "open", do: "Current condition", else: "Incident outcome"}
            </h2>
          </div>
          <div class="panel-body">
            <p :if={@incident["status"] == "open"}>
              Unresolved results: {@counts["critical"]} critical · {@counts["warning"]} warning. Each result keeps its own measurement and freshness; an unavailable or stale result does not imply recovery.
            </p>
            <p :if={@incident["status"] != "open"} class="notice">
              {humanize(@incident["closure_reason"])}. This history belongs to the incident that ended {time(
                @incident["closed_at"]
              )}.
            </p>
            <h3 class="space-top">
              {if @incident["status"] == "open", do: "Current impacts", else: "Last recorded impacts"}
            </h3>
            <p id="condition-impacts">{impact_names(@incident["impacts"] || [])}</p>
            <div
              :if={@incident["status"] == "open"}
              class="condition-coverage space-top"
              id="condition-coverage"
            >
              <h3>Notification holds</h3>
              <p>
                <strong>{@counts["uncovered"]} of {@counts["open"]} failing {plural(
                  @counts["open"],
                  "result"
                )} {if @counts["uncovered"] == 1, do: "has", else: "have"} no active hold.</strong>
              </p>
              <p>
                {@counts["shared_acknowledged"]} covered by the incident acknowledgement · {@counts[
                  "individually_acknowledged"
                ]} individually acknowledged · {@counts["maintained"]} in maintenance.
              </p>
              <p class="footnote">
                Holds can overlap. Partial maintenance does not hold the other results. Delivery still follows the notification’s recorded scope and retry budget.
              </p>
              <.link
                :if={@counts["uncovered"] > 0}
                id="inspect-uncovered-results"
                patch={
                  condition_path(
                    @incident["id"],
                    @filters |> Map.put("state", "uncovered") |> Map.delete("page"),
                    @return_to
                  )
                }
                class="text-link space-top"
              >Inspect results without active holds</.link>
            </div>
            <div class="fact-grid space-top">
              <div class="fact">
                <label>Incident opened</label><strong>{time(@incident["opened_at"])}</strong>
              </div>
              <div class="fact">
                <label>Incident ended</label><strong>{time(@incident["closed_at"])}</strong>
              </div>
            </div>
          </div>
          <details
            id="condition-identity"
            class="disclosure"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Condition identity & incident attribution</summary>
            <dl class="result-context">
              <div>
                <dt>Namespace</dt><dd class="mono">{@incident["namespace"]}</dd>
              </div>
              <div>
                <dt>Condition key</dt><dd class="mono">{@incident["key"]}</dd>
              </div>
              <div>
                <dt>Incident</dt><dd class="mono">{@incident["id"]}</dd>
              </div>
            </dl>
            <p>
              Check code declares this relationship. The namespace, condition key and monitored environment identify the condition; matching labels alone do not group results.
            </p>
          </details>
        </section>
        <div class="stack shared-contributors">
          <section
            class="panel"
            id="condition-contributors"
            aria-labelledby="condition-contributors-heading"
          >
            <div class="panel-heading">
              <h2 id="condition-contributors-heading">Contributing results</h2><span class="badge">{@counts[
                "open"
              ]} failing</span>
            </div>
            <nav class="condition-tabs panel-body" aria-label="Contributing result history">
              <.link
                :for={
                  {state, label} <- [
                    {"open", "Failing now (#{@counts["open"]})"},
                    {"uncovered", "Without active holds (#{@counts["uncovered"]})"},
                    {"history",
                     "Recovered & withdrawn (#{@counts["recovered"] + @counts["withdrawn"]})"},
                    {"all", "All contributions (#{@counts["total"]})"}
                  ]
                }
                patch={
                  condition_path(
                    @incident["id"],
                    @filters |> Map.put("state", state) |> Map.delete("page"),
                    @return_to
                  )
                }
                class={
                  if @contribution_page["state"] == state,
                    do: "button primary small",
                    else: "button small"
                }
                aria-current={if @contribution_page["state"] == state, do: "page"}
              >{label}</.link>
            </nav>
            <p class="panel-footer">
              A result can recover and rejoin this incident while other failures continue. Each contribution below retains its own evidence and individual controls.
            </p>
            <.condition_pagination
              id="contributions-top"
              position="top"
              page={@contribution_page}
              field="page"
              label="Contributions"
              incident={@incident}
              filters={@filters}
              return_to={@return_to}
            />
            <p :if={@contributions == []} class="empty">No contributions in this view.</p>
            <.condition_contribution
              :for={row <- @contributions}
              row={row}
              now={@now}
              return_to={@investigation_path}
            />
            <.condition_pagination
              :if={@contribution_page["pages"] > 1}
              id="contributions-bottom"
              position="bottom"
              page={@contribution_page}
              field="page"
              label="Contributions"
              incident={@incident}
              filters={@filters}
              return_to={@return_to}
            />
          </section>
          <details
            :if={@contradiction_page["total"] > 0}
            id="condition-other-results"
            class="panel disclosure"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>
              Last confirmed healthy evidence ({@contradiction_page["total"]})
            </summary>
            <p>
              These currently registered results share the same condition and monitored environment. Their last confirmed measurement was healthy; collection may now be stale or unavailable. Check each result’s evidence state and measurement age. These measurements do not cancel another result’s unresolved failure or rewrite this incident’s history.
            </p>
            <.condition_pagination
              id="contradictions"
              page={@contradiction_page}
              field="contradiction_page"
              label="Other results"
              incident={@incident}
              filters={@filters}
              return_to={@return_to}
            />
            <div
              :for={stream <- @contradictions}
              class="resource"
              id={"condition-ok-" <> stream["id"]}
            >
              <div class="resource-name">
                <h3>
                  <.link navigate={detail_path("/checks/" <> stream["id"], @investigation_path)}>{stream[
                    "label"
                  ]}</.link>
                </h3><.badge value="OK" /><.badge value={knowledge(stream)} />
              </div>
              <p>{target_label(stream["target"])} · {runner_label(stream)}</p>
              <p>{get_in(stream, ["current", "summary"])}</p>
              <p class="footnote">Measured {time(get_in(stream, ["current", "source_at"]))}</p>
              <p :if={knowledge(stream) == "unavailable"} class="footnote">
                Collection is unavailable; the last confirmed healthy measurement is retained.
              </p>
            </div>
          </details>
        </div>
      </div>
      <aside
        class="stack incident-controls"
        id="incident-controls"
        aria-label="Shared incident notification controls"
      >
        <.acknowledgement_panel
          incident={@incident}
          now={@now}
          acknowledgement_draft={@acknowledgement_draft}
          acknowledgement_error={@acknowledgement_error}
          acknowledgement_notice={@acknowledgement_notice}
        />
        <section class="panel" id="condition-maintenance">
          <div class="panel-heading">
            <h2>Maintenance</h2>
          </div>
          <div class="panel-body">
            <p>
              Choose the scheduled checks or exact targets you intend to maintain. A shared condition is not itself a maintenance scope.
            </p>
            <.link navigate="/maintenance/new" class="button space-top">Choose maintenance scope</.link>
          </div>
        </section>
      </aside>
      <div class="stack incident-history" id="incident-history">
        <section class="panel" id="incident-delivery-summary">
          <div class="panel-heading">
            <h2>Notification delivery</h2><span class="badge">{@notification_counts["total"] || 0} {plural(
              @notification_counts["total"] || 0,
              "notification"
            )}</span>
          </div>
          <div class="panel-body">
            <p>
              {@notification_counts["pending"] || 0} pending · {@notification_counts["retrying"] || 0} retrying · {@notification_counts[
                "delivering"
              ] || 0} delivering · {@notification_counts["exhausted"] || 0} retries exhausted
            </p>
            <p class="footnote space-top">
              {@notification_counts["delivered"] || 0} accepted by receiver · {@notification_counts[
                "superseded"
              ] || 0} superseded. Counts cover this whole incident.
            </p>
            <.link href="#incident-occurrences" class="text-link space-top">Inspect notification history</.link>
          </div>
        </section>
        <section class="panel" id="incident-occurrences">
          <div class="panel-heading">
            <h2>Notifications</h2>
          </div>
          <form
            id="condition-notification-filter"
            class="panel-body"
            phx-change="condition_notification_filter"
            phx-auto-recover="condition_notification_filter"
          >
            <div class="field">
              <label for="condition-notification-status">Delivery status</label><select
                id="condition-notification-status"
                name="notification_status"
              >
                <option
                  :for={
                    {value, label} <- [
                      {"all", "All notifications"},
                      {"unresolved", "Unresolved"},
                      {"pending", "Pending"},
                      {"retrying", "Retrying"},
                      {"delivering", "Delivering"},
                      {"exhausted", "Retries exhausted"},
                      {"delivered", "Receiver accepted"},
                      {"superseded", "Superseded"}
                    ]
                  }
                  value={value}
                  selected={@notification_page["status"] == value}
                >
                  {label}
                </option>
              </select>
            </div>
          </form>
          <.condition_pagination
            id="condition-notifications"
            page={@notification_page}
            field="notification_page"
            label="Notifications"
            incident={@incident}
            filters={@filters}
            return_to={@return_to}
          />
          <.occurrence_list
            :if={@occurrences != [] || @notification_counts["total"] == 0}
            occurrences={@occurrences}
            now={@now}
            retry_drafts={@retry_drafts}
            current_incident_id={@incident["id"]}
          />
          <div
            :if={@occurrences == [] && @notification_counts["total"] > 0}
            class="empty"
            id="condition-notifications-empty"
          >
            <h3>No notifications match this status</h3>
            <p>
              This incident has {@notification_counts["total"]} recorded {plural(
                @notification_counts["total"],
                "notification"
              )}.
            </p>
            <.link
              patch={
                condition_path(
                  @incident["id"],
                  @filters
                  |> Map.drop(~w(notification_page notification_id))
                  |> Map.put("notification_status", "all"),
                  @return_to
                )
              }
              class="button space-top"
            >View all notifications</.link>
          </div>
          <p class="panel-footer">
            Each notification retains its original impact scope, evidence and destination across attempts. Later corroborating results do not turn an accepted notification into a new one.
          </p>
        </section>
        <details
          id="condition-delivery-attempts"
          class="panel disclosure"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Delivery attempts ({get_in(@limits, ["attempts", "total"]) || 0})</summary>
          <.attempts_table attempts={@attempts} occurrences={@occurrences} now={@now} />
          <.inspection_limit counts={@limits["attempts"]} label="delivery attempts" />
        </details>
        <details
          id="incident-control-history"
          class="panel disclosure"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Operator control history ({get_in(@limits, ["controls", "total"]) || 0})</summary>
          <p>
            Shared and individual controls retain their original scope. Maintenance windows also have a separate <.link
              navigate="/maintenance"
              class="text-link"
            >maintenance history</.link>.
          </p>
          <p :if={@controls == []}>No controls are recorded for this incident.</p>
          <div class="timeline">
            <div :for={control <- @controls} class="timeline-item">
              <h3>{humanize(control["kind"])}</h3>
              <p>
                {if control["condition_incident_id"],
                  do: "Shared incident",
                  else: "Individual result or scheduled check"} · {control["reason"]}
              </p>
              <small>{control["actor"]} · recorded {time(control["inserted_at"])}{control_lifetime(
                control
              )}</small>
              <.link
                :if={control["incident_id"]}
                navigate={detail_path("/incidents/" <> control["incident_id"], @investigation_path)}
                class="text-link"
              >Inspect individual control</.link>
            </div>
          </div>
          <.inspection_limit counts={@limits["controls"]} label="operator controls" />
        </details>
        <details
          id="condition-evidence"
          class="panel disclosure"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Measurement evidence for this view ({length(@evidence)})</summary>
          <p>
            These are result excerpts from the original observations referenced by the displayed contributions, healthy context and notifications. Other results from those executions are omitted. Change the contribution or notification page to inspect its evidence.
          </p>
          <p :if={@incident["closure_reason"]} class="notice">
            Closure: {humanize(@incident["closure_reason"])}. {if @incident["closing_observation_id"],
              do: "The exact closing observation is included when retained.",
              else: "This closure has no closing measurement; withdrawal does not imply recovery."}
          </p>
          <.evidence_table evidence={@evidence} now={@now} />
          <p :if={(@limits["evidence"]["missing"] || 0) > 0}>
            {@limits["evidence"]["missing"]} referenced observations are no longer retained.
          </p>
        </details>
        <AgentPrompts.library
          id="incident-agent-prompts"
          kinds={[:incident]}
          context={
            %{
              "incident_id" => @incident["id"],
              "incident_kind" => "condition",
              "incident_status" => @incident["status"],
              "incident_reason" => @incident["closure_reason"],
              "condition_namespace" => @incident["namespace"],
              "controller_url" => @controller_url,
              "condition_key" => @incident["key"],
              "monitored_environment" => @incident["environment"],
              "contributor_count" => @counts["open"],
              "page_path" => "/incidents/" <> @incident["id"]
            }
          }
        />
      </div>
    </div>
    """
  end

  defp condition_contribution(assigns) do
    assigns =
      assign(assigns,
        incident: assigns.row["incident"],
        stream: assigns.row["stream"] || %{},
        measured: assigns.row["measured_result"] || %{},
        coverage: assigns.row["coverage"],
        state: assigns.row["contribution_state"]
      )

    ~H"""
    <article class="resource condition-contribution" id={"contribution-" <> @incident["id"]}>
      <div class="resource-name">
        <h3>
          <.link navigate={detail_path("/checks/" <> @incident["stream_id"], @return_to)}>{@stream[
            "label"
          ] || @incident["result_key"]}</.link>
        </h3>
        <span :if={@state != "open"} class="footnote">Last failure:</span><.badge value={
          @incident["health"]
        } /><span class="badge">{humanize(@state)}</span>
      </div>
      <p class="resource-subtitle">{target_label(@stream["target"])} · {runner_label(@stream)}</p>
      <div class="condition-measurement space-top">
        <div>
          <h4>
            {if @state == "open",
              do: "Last confirmed measurement",
              else: "Last measurement in this contribution"}
          </h4>
          <p :if={@measured != %{}}><.badge value={@measured["health"]} /> {@measured["summary"]}</p>
          <p :if={@measured != %{}} class="footnote contribution-impacts">
            Impacts: {impact_names(@measured["impacts"] || [])}.
          </p>
          <p :if={@measured == %{}}>The referenced measurement is no longer retained.</p>
          <p :if={@measured["source_at"]} class="footnote">
            Measured {time(@measured["source_at"])} · {age(@measured["source_at"], @now)}
          </p>
          <p :if={@state != "open"} class="footnote">
            Ended {time(@incident["closed_at"])} · {humanize(@incident["closure_reason"])}
          </p>
        </div>
        <div :if={@state == "open"}>
          <h4>Evidence now</h4><.badge value={knowledge(@stream)} />
          <p :if={knowledge(@stream) == "unavailable"} class="footnote">
            Collection is unavailable. The retained failure remains unresolved.
          </p>
          <p :if={knowledge(@stream) == "stale"} class="footnote">
            Fresh evidence is overdue. This is not a new failure measurement.
          </p>
        </div>
      </div>
      <div :if={@state == "open"} class="condition-holds space-top">
        <p :if={@coverage["shared_acknowledgement"]}>Covered by the incident acknowledgement.</p>
        <p :if={@coverage["individual_acknowledgement"]}>Individual acknowledgement is active.</p>
        <p :for={window <- @coverage["maintenance_windows"]}>
          Maintenance:
          <.link navigate={"/maintenance/" <> window["id"]} class="text-link">{window["name"] ||
            window["reason"]}</.link>
          until {time(window["ends_at"])}.
          <.link
            :if={window["series_id"]}
            navigate={"/maintenance/series/" <> window["series_id"]}
            class="text-link maintenance-series-link"
          >All dates in series</.link>
        </p>
        <p :if={@coverage["uncovered"]}>No active notification hold.</p>
      </div>
      <div class="condition-row-actions space-top">
        <.link
          navigate={detail_path("/checks/" <> @incident["stream_id"], @return_to)}
          class="text-link"
        >View result now</.link>
        <.link
          :if={@state == "open" && knowledge(@stream) in ["unavailable", "stale", "pending"]}
          id={"investigate-contribution-" <> @incident["id"]}
          navigate={detail_path("/checks/" <> @incident["stream_id"] <> "/diagnostics", @return_to)}
          class="button small"
        >Investigate missing measurement</.link>
        <.link navigate={detail_path("/incidents/" <> @incident["id"], @return_to)} class="text-link">{if @state ==
                                                                                                            "open",
                                                                                                          do:
                                                                                                            "Evidence & individual acknowledgement",
                                                                                                          else:
                                                                                                            "Inspect contribution history"}</.link>
      </div>
    </article>
    """
  end

  defp condition_pagination(assigns) do
    assigns = assign_new(assigns, :position, fn -> nil end)

    ~H"""
    <nav
      id={@id}
      class="pagination panel-footer"
      aria-label={@label <> " pagination" <> if(@position, do: " (#{@position})", else: "")}
    >
      <span>{if @page["total"] == 0,
        do: "No matching entries",
        else:
          "Page #{@page["page"]} of #{@page["pages"]} · #{@page["returned"]} of #{@page["total"]} #{if @page["total"] == 1, do: "entry", else: "entries"}"}</span>
      <div class="pagination-actions">
        <.link
          :if={@page["page"] > 1}
          patch={
            condition_path(
              @incident["id"],
              condition_page_filters(@filters, @field, @page["page"] - 1, @page),
              @return_to
            )
          }
          class="button small"
          aria-label={"Previous " <> String.downcase(@label) <> " page"}
        >Previous</.link>
        <.link
          :if={@page["page"] < @page["pages"]}
          patch={
            condition_path(
              @incident["id"],
              condition_page_filters(@filters, @field, @page["page"] + 1, @page),
              @return_to
            )
          }
          class="button small"
          aria-label={"Next " <> String.downcase(@label) <> " page"}
        >Next</.link>
      </div>
    </nav>
    """
  end

  defp result_incident_detail(assigns) do
    detail = assigns.inspection || %{}
    incident = detail["incident"] || %{}

    assignment =
      detail
      |> inspected_assignment()
      |> Map.put(
        "diagnostics_return_to",
        if(incident["id"], do: condition_path(incident["id"], assigns.filters, assigns.return_to))
      )

    assigns =
      assign(assigns,
        incident: incident,
        acknowledgement_draft: assigns.acknowledgement_draft || acknowledgement_draft(incident),
        acknowledgement_active: Monitoring.acknowledgement_active?(incident, assigns.now),
        acknowledgement_review_changed:
          acknowledgement_review_changed?(assigns.acknowledgement_draft, incident),
        assignment: assignment,
        occurrences: detail["occurrences"] || [],
        notification_summary: notification_focus(detail["occurrences"] || []),
        controls: detail["controls"] || [],
        attempts: detail["attempts"] || [],
        evidence: detail["evidence"] || [],
        incident_evidence: incident_evidence(detail),
        evidence_incident: incident_evidence_identity(detail),
        closing_measurement_notice: closing_measurement_notice(detail),
        limits: detail["limits"] || %{}
      )

    ~H"""
    <.link navigate={@return_to || "/incidents"} class="back"><.icon name="back" size={13} />{return_label(
      @return_to,
      "All incidents"
    )}</.link>
    <div :if={@incident == %{}} class="notice warn">
      This incident is not in the retained history.
    </div>
    <div :if={@incident != %{}}>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Incident detail</div><h1>{label(@assignment)}</h1><p>
            Target: {measured_target(@assignment)} · Observing runner: {runner_label(@assignment)}
          </p><p :if={@incident["environment"]} id="incident-environment">
            Monitored environment when opened: {environment_name(@incident)}
          </p><p>
            {incident_summary(@incident)}
          </p>
        </div><div class="status-line">
          <span class="footnote">Incident severity</span><.badge value={@incident["health"]} /><.badge value={
            @incident["status"]
          } />
          <.link
            :if={@incident["status"] == "open"}
            href="#incident-acknowledgement"
            class="button"
            id="incident-acknowledgement-shortcut"
          >
            {acknowledgement_shortcut_label(@incident, @acknowledgement_active)}
          </.link>
        </div>
      </div>
      <p :if={@incident["condition_incident_id"]} class="notice space-bottom" id="contribution-parent">
        This result contributes to a shared incident. <.link
          navigate={parent_incident_path(@incident, @return_to)}
          class="text-link"
        >Inspect the shared incident and all contributing results</.link>.
        Controls on this page apply to this result only.
      </p>
      <div class="details-grid incident-layout">
        <div class="stack incident-summary" id="incident-summary">
          <.confirmed_measurement
            assignment={@assignment}
            now={@now}
            id="incident-check-now"
            title="Latest measurement"
            context={
              if @incident["status"] == "open",
                do:
                  "New measurements update this panel while this #{acknowledgement_subject(@incident)} remains open. The opening findings are preserved in the measurement history below.",
                else:
                  "This is the check's latest measurement, including any measurements after this #{acknowledgement_subject(@incident)} ended. Findings from this #{acknowledgement_subject(@incident)} are preserved in the measurement history below."
            }
            discovery_href={
              @discovery &&
                MondekWeb.DiscoveryLive.path(
                  @discovery["stream"]["id"],
                  condition_path(@incident["id"], @filters, @return_to)
                )
            }
            discovery_link_id="incident-discovery-review"
            details_id="incident-current-details"
            provenance_id="incident-measurement-provenance"
            result_keys={[@incident["result_key"]]}
          />
          <section :if={@notification_summary} class="panel" id="incident-delivery-summary">
            <div class="panel-heading">
              <h2>Notification delivery</h2><.badge value={@notification_summary["status"]} />
            </div>
            <div class="panel-body">
              <p>{notification_explanation(@notification_summary)}</p>
              <p
                :if={@notification_summary["waiting_on_gates"] == true}
                class="notice notice-copy space-top"
              >
                {notification_gate_summary(@notification_summary)}
              </p>
              <p :if={@notification_summary["latest_attempt"]} class="space-top">
                Latest delivery attempt: {attempt_result(@notification_summary["latest_attempt"])}
              </p>
              <p :if={@notification_summary["next_retry_at"]} class="footnote space-top">
                Next eligible attempt: {retry_time(@notification_summary["next_retry_at"], @now)}
              </p>
              <.link href="#incident-occurrences" class="text-link space-top">Inspect notification history</.link>
            </div>
          </section>
          <AgentPrompts.library
            id="incident-agent-prompts"
            kinds={[:incident]}
            context={
              %{
                "incident_id" => @incident["id"],
                "incident_status" => @incident["status"],
                "incident_reason" => @incident["closure_reason"],
                "check_id" => @incident["assignment_id"],
                "result_key" => @incident["result_key"],
                "source_id" => @assignment["source_id"],
                "page_path" => "/incidents/" <> @incident["id"]
              }
            }
          />
        </div>
        <aside
          class="stack incident-controls"
          id="incident-controls"
          aria-label="Incident notification controls"
        >
          <.acknowledgement_panel
            incident={@incident}
            now={@now}
            acknowledgement_draft={@acknowledgement_draft}
            acknowledgement_error={@acknowledgement_error}
            acknowledgement_notice={@acknowledgement_notice}
            maintenance_windows={@maintenance_windows}
          />
          <.maintenance_form
            :if={!retired?(@assignment)}
            assignment={@assignment}
            now={@now}
            windows={@maintenance_windows}
            stream_id={@incident["stream_id"]}
          />
        </aside>
        <div class="stack incident-history" id="incident-history">
          <section class="panel">
            <div class="panel-heading">
              <h2>Incident history</h2><.link
                navigate={detail_path(incident_check_link(@inspection, @assignment), @return_to)}
                class="text-link"
              >View check <.icon name="arrow" size={13} /></.link>
            </div><div class="panel-body">
              <div class="fact-grid">
                <div class="fact">
                  <label>Incident opened</label><strong>{time(@incident["opened_at"])}</strong>
                </div><div class="fact">
                  <label>Incident ended</label><strong>{time(@incident["closed_at"])}</strong>
                </div>
              </div><div :if={@incident["closure_reason"]} class="notice space-top">
                Closure: {humanize(@incident["closure_reason"])}
              </div>
            </div><details phx-mounted={JS.ignore_attributes("open")} class="disclosure">
              <summary>Incident identity & attribution</summary><p class="mono">{@incident["id"]}</p><p>
                Attention revision {@incident["attention_revision"]}. Acknowledgements and maintenance are attributed to the local operator.
              </p>
            </details>
          </section>
          <details
            phx-mounted={JS.ignore_attributes("open")}
            class="panel disclosure"
            id="incident-measurements"
          >
            <summary>
              <h2>{String.capitalize(acknowledgement_subject(@incident))} measurement history</h2>
            </summary>
            <p class="panel-body">
              Historical findings from this {acknowledgement_subject(@incident)}. These can differ from the latest measurement shown above.
            </p>
            <.evidence_table
              evidence={@incident_evidence}
              incident={@evidence_incident}
              result_key={@incident["result_key"]}
              now={@now}
              empty_title={"No retained measurements for this " <> acknowledgement_subject(@incident)}
              empty_description={"No linked measurement evidence is retained for this " <> acknowledgement_subject(@incident) <> ". Current check state and recent executions are shown separately."}
            />
            <p :if={@closing_measurement_notice} class="panel-footer">
              {@closing_measurement_notice}
            </p>
            <div :if={(get_in(@limits, ["evidence", "missing"]) || 0) > 0} class="panel-footer">
              {get_in(@limits, ["evidence", "missing"])} referenced observations are no longer retained.
            </div>
          </details>
          <section class="panel" id="incident-occurrences">
            <div class="panel-heading">
              <h2>
                {if @incident["condition_incident_id"],
                  do: "Shared notification history",
                  else: "Notifications"}
              </h2>
            </div>
            <div :if={@incident["condition_incident_id"]} class="panel-body">
              <p>Notifications and delivery attempts are recorded on the shared incident.</p>
              <.link
                id="contribution-shared-notifications"
                navigate={parent_notification_path(@incident, @return_to)}
                class="text-link space-top"
              >Inspect shared notification history</.link>
            </div>
            <.occurrence_list
              :if={!@incident["condition_incident_id"]}
              occurrences={@occurrences}
              now={@now}
              retry_drafts={@retry_drafts}
            /><div :if={!@incident["condition_incident_id"]} class="panel-footer">
              Each notification keeps its original payload and destination across delivery attempts.
            </div>
            <.inspection_limit
              :if={!@incident["condition_incident_id"]}
              counts={@limits["occurrences"]}
              label="notifications"
            />
          </section>
          <section :if={!@incident["condition_incident_id"]} class="panel" id="incident-attempts">
            <div class="panel-heading">
              <h2>Delivery attempts</h2><span class="badge">{length(@attempts)} attempts</span>
            </div><.attempts_table
              attempts={Enum.take(@attempts, 3)}
              occurrences={@occurrences}
              now={@now}
            />
            <p :if={length(@attempts) > 3} class="panel-footer" id="visible-attempt-count">
              Showing the latest {min(length(@attempts), 3)} of {get_in(@limits, ["attempts", "total"]) ||
                length(@attempts)} retained delivery attempts.
            </p>
            <details
              :if={length(@attempts) > 3}
              phx-mounted={JS.ignore_attributes("open")}
              class="disclosure"
              id="earlier-delivery-attempts"
            >
              <summary>Earlier delivery attempts ({length(@attempts) - 3} in this view)</summary>
              <.attempts_table
                attempts={Enum.drop(@attempts, 3)}
                occurrences={@occurrences}
                now={@now}
              />
            </details>
            <.inspection_limit counts={@limits["attempts"]} label="delivery attempts" />
          </section>
          <details
            phx-mounted={JS.ignore_attributes("open")}
            class="panel disclosure"
            id="recent-incident-evidence"
          >
            <summary>
              Recent check executions, including measurements after this {acknowledgement_subject(
                @incident
              )}
            </summary>
            <.evidence_table
              evidence={
                Enum.reject(
                  @evidence,
                  &Enum.any?(@incident_evidence, fn selected -> selected["id"] == &1["id"] end)
                )
              }
              result_key={@incident["result_key"]}
              now={@now}
              empty_title="No additional retained executions"
              empty_description="Linked measurements are shown above. There are no other retained executions in this view."
            />
          </details>
          <section class="panel" id="incident-control-history">
            <div class="panel-heading">
              <h2>Operator control history</h2>
            </div>
            <div :if={@controls == []} class="empty">
              <p>No controls are recorded in this timeline.</p>
            </div>
            <div :if={@controls != []} class="timeline">
              <div :for={control <- @controls} class="timeline-item">
                <h3>{humanize(control["kind"])}</h3>
                <p>{control["reason"]}</p>
                <small>{control["actor"]} · recorded {time(control["inserted_at"])}{control_lifetime(
                  control
                )}</small>
              </div>
            </div>
            <p class="panel-footer">
              Maintenance windows keep their own <.link
                navigate={maintenance_path(@assignment["id"], @incident["stream_id"], false)}
                class="text-link"
              >maintenance history</.link>.
            </p>
            <.inspection_limit counts={@limits["controls"]} label="operator controls" />
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp acknowledgement_panel(assigns) do
    assigns =
      assigns
      |> assign_new(:maintenance_windows, fn -> [] end)
      |> assign(
        :acknowledgement_active,
        Monitoring.acknowledgement_active?(assigns.incident, assigns.now)
      )
      |> assign(
        :acknowledgement_review_changed,
        acknowledgement_review_changed?(assigns.acknowledgement_draft, assigns.incident)
      )

    ~H"""
    <section
      class="panel"
      id="incident-acknowledgement"
      tabindex="-1"
      aria-labelledby="incident-acknowledgement-heading"
    >
      <div class="panel-heading">
        <h2 id="incident-acknowledgement-heading">
          {if @incident["condition_incident_id"],
            do: "Individual acknowledgement",
            else: "Acknowledgement"}
        </h2>
      </div><div class="panel-body">
        <div :if={@acknowledgement_active} id="active-acknowledgement">
          <span class="badge">{if @incident["condition_incident_id"],
            do: "Individually acknowledged",
            else: "Acknowledged"}</span><p class="space-top">
            {@incident["acknowledgement_note"]}
          </p><p class="footnote" id="acknowledgement-lifetime">
            {acknowledgement_lifetime(@incident)}
          </p><small>Recorded by {@incident["acknowledged_by"] || "Local operator"}. Covers {badge_text(
            @incident["acknowledgement_ceiling"]
          )} severity and below.</small><p class="footnote" id="acknowledged-impacts">
            Impact scope: {acknowledged_impact_names(@incident)}.
          </p>
        </div><p :if={!@acknowledgement_active && @incident["status"] == "open"}>
          {if @incident["condition_incident_id"],
            do:
              "No individual acknowledgement is active. Hold this result’s failure notifications while you investigate this contribution.",
            else:
              "No acknowledgement is active. Hold failure notifications while you investigate this incident."}
        </p><p :if={@incident["status"] != "open"}>
          This {acknowledgement_subject(@incident)} has ended. Its acknowledgement no longer holds notifications; previous actions remain in the history.
        </p>
        <p
          :if={@incident["condition_incident_id"]}
          class="notice notice-copy"
          id="individual-acknowledgement-scope"
        >
          This control covers this contribution only. It does not acknowledge the shared incident. A shared incident acknowledgement may still hold notifications for this result.
        </p><form
          :if={@incident["status"] == "open"}
          id="acknowledgement-form"
          phx-submit="acknowledge"
          phx-change="edit_acknowledgement"
          phx-auto-recover="edit_acknowledgement"
          class="attention-form"
        >
          <input type="hidden" name="_id" value={@incident["id"]} />
          <input type="hidden" name="_revision" value={@acknowledgement_draft["_revision"]} />
          <input
            type="hidden"
            name="_attention_revision"
            value={@acknowledgement_draft["_attention_revision"]}
          />
          <input type="hidden" name="_health" value={@acknowledgement_draft["_health"]} />
          <div
            :if={@acknowledgement_error || @acknowledgement_review_changed}
            id="ack-error"
            class="form-error"
            role="alert"
          >
            {@acknowledgement_error ||
              "The #{acknowledgement_subject(@incident)} or acknowledgement changed while you were reviewing it. Your proposed settings are preserved."}
            <button
              :if={@acknowledgement_review_changed}
              id="review-acknowledgement"
              type="button"
              class="button small space-top"
              phx-click="review_acknowledgement"
            >Review current {acknowledgement_subject(@incident)} and acknowledgement</button>
          </div>
          <p
            :if={@acknowledgement_notice}
            id="ack-notice"
            class="notice notice-copy"
            role="status"
          >
            {@acknowledgement_notice}
          </p>
          <div class="field">
            <label for="ack-note">Operator note</label><textarea
              id="ack-note"
              name="note"
              required
              maxlength="500"
              placeholder="Investigating the local service"
            >{@acknowledgement_draft["note"]}</textarea>
          </div><div class="field">
            <label for="ack-mode">Acknowledge until</label><select id="ack-mode" name="mode">
              <option
                value="until_incident_ends"
                selected={@acknowledgement_draft["mode"] == "until_incident_ends"}
              >
                This {acknowledgement_subject(@incident)} ends
              </option>
              <option value="duration" selected={@acknowledgement_draft["mode"] == "duration"}>
                A duration has passed
              </option>
              <option value="until" selected={@acknowledgement_draft["mode"] == "until"}>
                A specific date and time (UTC)
              </option>
            </select>
          </div>
          <div :if={@acknowledgement_draft["mode"] == "duration"} class="field">
            <label for="ack-duration">Duration</label><select id="ack-duration" name="seconds">
              <option
                :for={
                  {value, label} <- [
                    {"900", "15 minutes"},
                    {"3600", "1 hour"},
                    {"86400", "1 day"},
                    {"604800", "1 week"},
                    {"custom", "Custom duration"}
                  ]
                }
                value={value}
                selected={@acknowledgement_draft["seconds"] == value}
              >
                {label}
              </option>
            </select>
          </div>
          <div
            :if={
              @acknowledgement_draft["mode"] == "duration" &&
                @acknowledgement_draft["seconds"] == "custom"
            }
            class="form-grid"
          >
            <div class="field">
              <label for="ack-days">Days</label><input
                id="ack-days"
                type="number"
                name="days"
                min="0"
                step="1"
                required
                value={@acknowledgement_draft["days"]}
              />
            </div>
            <div class="field">
              <label for="ack-hours">Additional hours</label><input
                id="ack-hours"
                type="number"
                name="hours"
                min="0"
                max="23"
                step="1"
                required
                value={@acknowledgement_draft["hours"]}
              />
            </div>
          </div>
          <div :if={@acknowledgement_draft["mode"] == "until"} class="field">
            <label for="ack-expires-at">Expiry date and time (UTC)</label><input
              id="ack-expires-at"
              name="expires_at"
              type="datetime-local"
              step="1"
              max="9999-12-31T23:59:59"
              value={@acknowledgement_draft["expires_at"]}
              required
              aria-describedby="ack-expiry-help"
            /><small id="ack-expiry-help">Enter UTC, regardless of your device's timezone. This must be in the future.</small>
          </div>
          <p class="footnote" id="ack-reviewed-severity">
            This acknowledgement will cover {badge_text(@acknowledgement_draft["_health"])} severity and below. A higher severity or a new impact ends it.
          </p>
          <p :if={!@acknowledgement_review_changed} class="footnote" id="ack-reviewed-impacts">
            Impact scope: {impact_names(@acknowledgement_draft["reviewed_impacts"] || [])}.
          </p>
          <p :if={condition_incident?(@incident)} class="footnote">
            Equivalent results arriving later remain covered while this incident continues. Individual acknowledgements and maintenance remain separate.
          </p>
          <button
            class="button"
            phx-disable-with="Recording…"
            disabled={@acknowledgement_review_changed}
          >
            {if @acknowledgement_active,
              do:
                if(@incident["condition_incident_id"],
                  do: "Update individual acknowledgement",
                  else: "Update acknowledgement"
                ),
              else:
                if(@incident["condition_incident_id"],
                  do: "Acknowledge this result only",
                  else: "Acknowledge"
                )}
          </button>
        </form>
        <button
          :if={@incident["status"] == "open" && @acknowledgement_active}
          id="end-acknowledgement"
          type="button"
          class="button small space-top"
          phx-click="end_acknowledgement"
          phx-value-id={@incident["id"]}
          phx-value-revision={@acknowledgement_draft["_revision"]}
          phx-value-attention_revision={@acknowledgement_draft["_attention_revision"]}
          disabled={@acknowledgement_review_changed}
        >{if @incident["condition_incident_id"],
          do: "End individual acknowledgement",
          else: "End acknowledgement"}</button>
        <p
          :if={Enum.any?(@maintenance_windows, &(&1["status"] == "active"))}
          class="notice notice-copy space-top"
        >
          Notification maintenance also applies. Ending acknowledgement leaves that window active.
        </p>
      </div><div class="panel-footer">
        Checks and health remain visible. Acknowledgement ends when {if @incident[
                                                                          "condition_incident_id"
                                                                        ],
                                                                        do: "this contribution ends",
                                                                        else: "the incident closes"}, when its chosen time expires, when severity rises above the acknowledged limit, or when a new impact appears. Equivalent failures within that scope do not end it. Recovery notifications can still be delivered. An attempt already underway may finish.
        <span :if={@incident["condition_incident_id"]}>The shared incident may continue after this contribution ends.</span>
      </div>
    </section>
    """
  end

  defp condition_path(id, filters, return_to),
    do: MondekWeb.InvestigationNavigation.condition_path(id, filters, return_to)

  defp parent_notification_path(incident, return_to),
    do: MondekWeb.InvestigationNavigation.parent_notification_path(incident, return_to)

  defp condition_page_filters(filters, field, page, projection),
    do:
      MondekWeb.InvestigationNavigation.condition_page_filters(
        filters,
        field,
        page,
        projection
      )

  defp impact_names([]), do: "No named impacts"

  defp impact_names(impacts),
    do:
      Enum.map_join(impacts, ", ", fn
        %{"label" => label} -> label
        %{"key" => key} -> key
        key when is_binary(key) -> key
      end)

  defp acknowledged_impact_names(incident) do
    labels = Map.new(incident["impacts"] || [], &{&1["key"], &1["label"] || &1["key"]})

    (incident["acknowledgement_impacts"] || [])
    |> Enum.map(&Map.get(labels, &1, &1))
    |> impact_names()
  end

  defp incident_check_link(inspection, assignment) do
    case get_in(inspection || %{}, ["stream", "id"]) do
      nil -> "/resources/" <> assignment["id"]
      id -> "/checks/" <> id
    end
  end

  defp incident_evidence_identity(detail) do
    incident = detail["incident"] || %{}
    firing = Enum.find(detail["occurrences"] || [], &(&1["kind"] == "firing")) || %{}

    Map.put(
      incident,
      "opening_observation_id",
      incident["opening_observation_id"] || get_in(firing, ["payload", "observation_id"])
    )
  end

  defp incident_evidence(detail) do
    ids = [
      get_in(detail, ["incident", "opening_observation_id"]),
      get_in(detail, ["incident", "latest_observation_id"]),
      get_in(detail, ["incident", "closing_observation_id"])
      | Enum.map(detail["occurrences"] || [], &get_in(&1, ["payload", "observation_id"]))
    ]

    Enum.filter(detail["evidence"] || [], &(&1["id"] in ids)) |> Enum.reverse()
  end

  defp closing_measurement_notice(%{"incident" => %{"closure_reason" => reason}})
       when reason in [
              "check_retired",
              "source_removed",
              "result_retired",
              "condition_changed",
              "publisher_retired",
              "publisher_replaced"
            ],
       do: "Monitoring ended. No recovery measurement is implied by this closure."

  defp closing_measurement_notice(%{"incident" => %{"status" => "closed"} = incident} = detail) do
    id = incident["closing_observation_id"]

    cond do
      is_nil(id) ->
        "This historical incident has no linked closing measurement. Its recorded closure reason is shown above."

      not Enum.any?(detail["evidence"] || [], &(&1["id"] == id)) ->
        "The linked closing measurement is no longer retained. Its recorded closure reason is shown above."

      true ->
        nil
    end
  end

  defp closing_measurement_notice(_), do: nil

  defp clear_stale_acknowledgement_flash(socket, detail, at) do
    previous = get_in(socket.assigns[:incident_inspection] || %{}, ["incident"])
    current = get_in(detail || %{}, ["incident"])
    message = get_in(socket.assigns[:flash] || %{}, ["info"]) || ""

    changed =
      previous && current && previous["id"] == current["id"] &&
        (previous["acknowledgement_revision"] != current["acknowledgement_revision"] ||
           Monitoring.acknowledgement_active?(previous, socket.assigns[:now] || at) !=
             Monitoring.acknowledgement_active?(current, at))

    inactive = current && not Monitoring.acknowledgement_active?(current, at)

    if (changed || inactive) && String.starts_with?(message, "Acknowledgement recorded."),
      do: clear_flash(socket, :info),
      else: socket
  end

  defp acknowledgement_recorded_flash(socket) do
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"])

    message =
      if incident && Monitoring.acknowledgement_active?(incident, socket.assigns.now) do
        if incident["condition_incident_id"] do
          "Acknowledgement recorded. This individual acknowledgement holds this result’s failure notifications until this contribution ends, the chosen time expires, severity rises above the acknowledged limit, or a new impact appears. Shared acknowledgement and maintenance remain separate."
        else
          "Acknowledgement recorded. Failure notifications are held until the incident ends, the chosen time expires, severity rises above the acknowledged limit, or a new impact appears. Checks continue; recovery notifications can still be delivered."
        end
      else
        "The acknowledgement was recorded but is no longer active. Review the current #{acknowledgement_subject(incident || %{})} before acknowledging again."
      end

    put_flash(socket, :info, message)
  end

  defp acknowledgement_shortcut_label(incident, active?) do
    case {is_binary(incident["condition_incident_id"]), active?} do
      {true, true} -> "Review individual acknowledgement"
      {true, false} -> "Acknowledge this result only"
      {false, true} -> "Review acknowledgement"
      {false, false} -> "Acknowledge incident"
    end
  end

  defp acknowledgement_draft(incident) do
    active = Monitoring.acknowledgement_active?(incident)

    mode =
      if active && incident["acknowledgement_mode"] == "until",
        do: "until",
        else: "until_incident_ends"

    expires = if active && mode == "until", do: parse_time(incident["acknowledged_until"])

    %{
      "_id" => incident["id"],
      "_revision" => incident["acknowledgement_revision"] || 0,
      "_attention_revision" => incident["attention_revision"],
      "_health" => incident["health"],
      "reviewed_impacts" => incident["impacts"] || [],
      "mode" => mode,
      "seconds" => "900",
      "days" => "1",
      "hours" => "0",
      "expires_at" => if(expires, do: Calendar.strftime(expires, "%Y-%m-%dT%H:%M:%S"), else: ""),
      "note" => if(active, do: incident["acknowledgement_note"] || "", else: "")
    }
  end

  defp keep_acknowledgement_draft(socket, form) when is_map(form) do
    fields = ~w(_id _revision _attention_revision _health mode seconds days hours expires_at note)
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"])
    values = Map.take(form, fields)

    valid_values =
      Enum.all?(values, fn {_key, value} -> is_binary(value) || is_integer(value) end)

    if incident && form["_id"] == incident["id"] && valid_values &&
         byte_size(Jason.encode!(values)) <= 4_096 do
      draft =
        Map.merge(socket.assigns.acknowledgement_draft || acknowledgement_draft(incident), values)

      assign(socket,
        acknowledgement_draft: draft,
        acknowledgement_error: nil,
        acknowledgement_notice: nil
      )
    else
      assign(socket,
        acknowledgement_error:
          "Supply the acknowledgement form for this incident using bounded text values."
      )
    end
  end

  defp acknowledgement_options(draft) when is_map(draft) do
    now = Monitoring.now()
    last_expiry = ~U[9999-12-31 23:59:59.999999Z]

    base = %{
      "mode" => draft["mode"],
      "revision" => integer(draft["_revision"]),
      "attention_revision" => integer(draft["_attention_revision"])
    }

    case draft["mode"] do
      "until_incident_ends" ->
        {:ok, base}

      "duration" ->
        days = integer(draft["days"])
        hours = integer(draft["hours"])

        seconds =
          if draft["seconds"] == "custom",
            do: days * 86_400 + hours * 3_600,
            else: integer(draft["seconds"])

        cond do
          seconds <= 0 || (draft["seconds"] == "custom" && (days < 0 || hours not in 0..23)) ->
            {:error, "Enter a positive duration using whole days and 0–23 additional hours."}

          seconds > DateTime.diff(last_expiry, now) ->
            {:error,
             "Choose a shorter duration that ends by 31 December 9999, or choose This incident ends."}

          true ->
            {:ok, Map.put(base, "seconds", seconds)}
        end

      "until" ->
        case draft["expires_at"] do
          value when is_binary(value) ->
            value = if byte_size(value) == 16, do: value <> ":00", else: value

            with {:ok, date} <- NaiveDateTime.from_iso8601(value),
                 {:ok, utc} <- DateTime.from_naive(date, "Etc/UTC") do
              cond do
                DateTime.compare(utc, now) != :gt ->
                  {:error, "Choose a future expiry date and time in UTC."}

                DateTime.compare(utc, last_expiry) == :gt ->
                  {:error, "Choose an expiry no later than 31 December 9999 in UTC."}

                true ->
                  {:ok, Map.put(base, "expires_at", DateTime.to_iso8601(utc))}
              end
            else
              _ -> {:error, "Enter a valid UTC date and time through year 9999."}
            end

          _ ->
            {:error, "Enter a valid future date and time in UTC."}
        end

      _ ->
        {:error, "Choose when this acknowledgement should end."}
    end
  end

  defp acknowledgement_options(_), do: {:error, "Review the incident before acknowledging it."}

  defp acknowledgement_review_changed?(nil, _incident), do: false

  defp acknowledgement_review_changed?(draft, incident),
    do:
      integer(draft["_revision"]) != incident["acknowledgement_revision"] ||
        integer(draft["_attention_revision"]) != incident["attention_revision"]

  defp reset_acknowledgement_draft(socket) do
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"])

    assign(socket,
      acknowledgement_draft: if(incident, do: acknowledgement_draft(incident)),
      acknowledgement_error: nil,
      acknowledgement_notice: nil
    )
  end

  defp acknowledgement_failure(socket, reason) do
    incident = get_in(socket.assigns.incident_inspection || %{}, ["incident"]) || %{}

    message =
      if reason == :stale,
        do:
          "The #{acknowledgement_subject(incident)} or acknowledgement changed after you reviewed it. Your proposed settings are preserved. Review the current control before saving or ending it.",
        else: error_message(reason)

    socket |> refresh() |> assign(acknowledgement_error: message, acknowledgement_notice: nil)
  end

  defp acknowledgement_lifetime(%{"acknowledgement_mode" => "until_incident_ends"} = incident),
    do: "Until this #{acknowledgement_subject(incident)} ends; no scheduled expiry."

  defp acknowledgement_lifetime(incident),
    do: "Until " <> acknowledgement_time(incident["acknowledged_until"]) <> "."

  defp keep_retry_draft(socket, id, reason)
       when is_binary(reason) and byte_size(reason) <= 2_000 do
    occurrences =
      case socket.assigns.live_action do
        :incident ->
          (socket.assigns.incident_inspection || %{})["occurrences"] || []

        _ ->
          socket.assigns.snapshot["occurrences"] || []
      end

    assign(socket,
      retry_drafts:
        MondekWeb.NotificationRetry.keep_draft(
          socket.assigns.retry_drafts,
          occurrences,
          id,
          reason
        )
    )
  end

  defp keep_retry_draft(socket, _id, _reason), do: socket
end
