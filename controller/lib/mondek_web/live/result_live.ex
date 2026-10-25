# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ResultLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation
  alias Mondek.Monitoring
  alias MondekWeb.CheckDiagnostics
  alias MondekWeb.CheckInventory
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
       listing: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(
        selected_id: params["id"],
        return_to: safe_return_path(params["return_to"]),
        controller_url: controller_origin(uri),
        filters: inventory_params(params, socket.assigns.live_action),
        page_title: page_name(socket.assigns.live_action)
      )

    socket = refresh(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = Monitoring.overview(at)

    socket =
      assign(socket, snapshot: snapshot, now: parse_time(snapshot["now"]) || DateTime.utc_now())

    id = socket.assigns.selected_id
    action = socket.assigns.live_action

    detail =
      cond do
        is_nil(id) -> nil
        action in [:check, :check_diagnostics] -> Monitoring.stream_inspection(id, at)
        true -> Monitoring.assignment_inspection(id, at)
      end

    discovery =
      if action in [:check, :resource] && get_in(detail || %{}, ["stream", "id"]),
        do: Mondek.Discovery.inspect(detail["stream"]["id"], at)

    runner =
      if action in [:check_diagnostics, :resource_diagnostics] && detail,
        do: Mondek.Inspection.runner_detail(get_in(detail, ["assignment", "runner_id"]))

    assign(socket,
      check_inspection: detail,
      discovery_inspection: discovery,
      maintenance_windows: related_maintenance(detail),
      diagnostic_runner: runner
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
      <.resource_detail
        :if={@live_action in [:resource, :check]}
        snapshot={@snapshot}
        now={@now}
        return_to={@return_to}
        id={@selected_id}
        inspection={@check_inspection}
        discovery={@discovery_inspection}
        maintenance_windows={@maintenance_windows}
      />
      <CheckDiagnostics.page
        :if={@live_action in [:check_diagnostics, :resource_diagnostics]}
        inspection={@check_inspection}
        runner={@diagnostic_runner}
        now={@now}
        return_to={@return_to}
        controller_url={@controller_url}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp stream_rows(assigns) do
    assigns =
      assigns
      |> assign_new(:return_to, fn -> nil end)
      |> assign_new(:empty_title, fn -> "No matching results" end)
      |> assign_new(:empty_description, fn ->
        "Adjust the filters or inspect the runner inventory."
      end)

    ~H"""
    <div :if={@items == []} class="empty">
      <h3>{@empty_title}</h3><p>{@empty_description}</p>
    </div>
    <div :if={@items != []} class="table-wrap">
      <table class="inventory-table">
        <thead>
          <tr>
            <th scope="col">Result / target</th><th scope="col">Check / runner</th><th scope="col">
              Last measured health
            </th><th scope="col">Freshness / source age</th>
          </tr>
        </thead><tbody>
          <tr :for={stream <- @items} id={"result-" <> stream["id"]}>
            <td>
              <.link navigate={detail_path("/checks/" <> stream["id"], @return_to)}><strong>{label(
                stream
              )}</strong></.link><div class="sub">
                {target_label(stream["target"])}
              </div>
            </td>
            <td>
              <.link navigate={detail_path("/configuration/" <> stream["assignment_id"], @return_to)}>{stream[
                "check_label"
              ] ||
                stream["assignment_label"] || stream["assignment_id"]}</.link><div class="sub">
                {runner_label(stream)} · {source_label(stream)}
              </div>
              <div :if={stream["environment"]} class="sub">{environment_name(stream)}</div>
            </td>
            <td>
              <.badge value={measured_health(stream)} /><div class="sub inventory-summary">
                {get_in(stream, ["current", "summary"]) ||
                  "Waiting for its first scheduled observation."}
              </div>
            </td>
            <td>
              <.badge value={knowledge(stream)} /><div class="sub">
                {age(get_in(stream, ["current", "source_at"]), @now)}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp measured_health(stream),
    do:
      if(confirmed_measurement?(stream),
        do: get_in(stream, ["current", "health"]),
        else: "not_measured"
      )

  defp resource_detail(assigns) do
    inspection = assigns.inspection || %{}
    assignment = inspected_assignment(inspection)

    assignment =
      if assignment == %{},
        do: assignment,
        else: Map.put(assignment, "diagnostics_return_to", assigns.return_to)

    discovery_context = Mondek.DiscoveryConfiguration.context(assignment["id"])

    discovery_primary? =
      not is_nil(discovery_context) and
        get_in(assignment, ["discovery", "origin"]) == "discovered" and
        assignment["params_owner"] != "ui"

    assigns =
      assign(assigns,
        assignment: assignment,
        discovery_primary?: discovery_primary?,
        discovery_context: discovery_context,
        scheduled_check: inspection["assignment"] || %{},
        stream: inspection["stream"] || %{},
        streams: get_in(inspection, ["assignment", "streams"]) || [],
        current: assignment["current"] || %{},
        evidence: inspection["evidence"] || [],
        incidents: inspection["incidents"] || [],
        controls: inspection["controls"] || [],
        target_context_path: result_target_context_path(inspection, assigns.return_to),
        limits: inspection["limits"] || %{}
      )

    ~H"""
    <.link navigate={@return_to || "/"} class="back"><.icon name="back" size={13} />{return_label(
      @return_to,
      "Monitoring overview"
    )}</.link>
    <div :if={@assignment == %{}} class="notice warn">This check is not configured.</div>
    <div :if={@assignment != %{}}>
      <div class="page-heading">
        <div>
          <div class="eyebrow">
            {if @stream == %{}, do: "Scheduled check detail", else: "Result detail"}
          </div><h1>{label(@assignment)}</h1>
          <dl class="result-context">
            <div>
              <dt>Target</dt><dd>{measured_target(@assignment)}</dd>
            </div>
            <div :if={@assignment["environment"]}>
              <dt>Monitored environment</dt><dd>{environment_name(@assignment)}</dd>
            </div>
            <div>
              <dt>Observing runner</dt><dd>{runner_label(@assignment)}</dd>
            </div>
          </dl>
        </div><.link
          :if={!retired?(@scheduled_check) || @discovery_primary?}
          id={if @discovery_primary?, do: "configure-resource-discovery"}
          navigate={
            detail_path(
              if(@discovery_primary?, do: "/configuration/discovery/", else: "/configuration/") <>
                @assignment["id"],
              detail_path(
                if(@stream == %{},
                  do: "/resources/" <> @assignment["id"],
                  else: "/checks/" <> @stream["id"]
                ),
                @return_to
              )
            )
          }
          class="button"
        ><.icon
          name="sliders"
          size={14}
        />{if @discovery_primary?, do: "Configure resource discovery", else: "Review configuration"}</.link>
      </div>
      <section
        :if={@discovery_context}
        class="panel panel-body space-bottom"
        id="resource-discovery-settings"
      >
        <h2>How this resource is monitored</h2>
        <p :if={get_in(@scheduled_check, ["discovery", "origin"]) == "required"}>
          Required by code. Discovery exclusions cannot remove this expectation; change the monitoring project's declaration.
        </p>
        <p :if={get_in(@scheduled_check, ["discovery", "origin"]) == "discovered"}>
          Automatically discovered. Its membership is managed by {@discovery_context.manager["label"]}. Excluding it changes future selection; it does not turn the failure into a healthy measurement.
        </p>
        <.link
          navigate={(if @discovery_primary?, do: "/configuration/", else: "/configuration/discovery/") <> @scheduled_check["id"] <> "?" <> URI.encode_query(%{"return_to" => detail_path(if(@stream == %{}, do: "/resources/" <> @scheduled_check["id"], else: "/checks/" <> @stream["id"]), @return_to)})}
          class="button"
          id={
            if @discovery_primary?,
              do: "inspect-resource-check-settings",
              else: "configure-resource-discovery"
          }
        >{if @discovery_primary?,
          do: "Inspect this check’s own settings",
          else: "Configure resource discovery"}</.link>
      </section>
      <p :if={@target_context_path} class="space-bottom">
        <.link id="result-target-context" navigate={@target_context_path} class="text-link">Show all observations of this target</.link>
      </p>
      <div :if={retired?(@assignment)} class="notice notice-copy space-top" id="retired-check-notice">
        <strong>{if retired?(@scheduled_check), do: "Check retired", else: "Result retired"} {time(
          @assignment["retired_at"]
        )}.</strong> {@assignment[
          "retirement_reason"
        ]}
        <p :if={retired?(@scheduled_check)}>
          This check is excluded from active coverage. Its last measurement is historical; retirement does not mean recovery. The runner stops scheduling it after control reconnects.
        </p>
        <p :if={!retired?(@scheduled_check)}>
          This result is excluded from active coverage. Its last measurement is historical; retirement does not mean recovery. The shared check continues scheduling its remaining results.
        </p>
        <.link
          :if={!retired?(@scheduled_check)}
          navigate={detail_path("/resources/" <> @scheduled_check["id"], @return_to)}
          class="button space-top"
        >Inspect shared check</.link>
      </div>
      <div class="details-grid result-layout">
        <div class="stack">
          <section :if={@stream == %{} && length(@streams) > 1} class="panel">
            <div class="panel-heading">
              <h2>Independent results</h2><p>Select a result to inspect its health and incidents.</p>
            </div><.stream_rows items={@streams} now={@now} return_to={@return_to} />
          </section>
          <.confirmed_measurement
            :if={@stream != %{} || length(@streams) <= 1}
            assignment={@assignment}
            now={@now}
            id="result-measurement"
            discovery_href={
              @discovery && MondekWeb.DiscoveryLive.path(@discovery["stream"]["id"], @return_to)
            }
            details_id="confirmed-result-details"
            provenance_id="measurement-provenance"
            result_keys={
              if @stream == %{}, do: @assignment["expected_keys"] || [], else: [@stream["result_key"]]
            }
          />
          <section
            :for={incident <- Enum.filter(@incidents, &(&1["status"] == "open"))}
            class="panel"
            id={"active-incident-" <> incident["id"]}
          >
            <div class="panel-heading">
              <h2>Open incident</h2><.badge value={incident["health"]} />
            </div>
            <div class="panel-body">
              <p>{incident_summary(incident)}</p>
              <.link
                navigate={parent_incident_path(incident, @return_to)}
                class="button primary space-top"
              >Inspect incident & acknowledgement</.link>
            </div>
          </section>
          <details
            phx-mounted={JS.ignore_attributes("open")}
            class="panel disclosure result-history"
            id="check-incident-history"
          >
            <summary>Incident history ({length(@incidents)} in this view)</summary>
            <.incidents_table
              incidents={@incidents}
              assignments={[@assignment]}
              now={@now}
              return_to={@return_to}
            />
            <.inspection_limit counts={@limits["incidents"]} label="incidents" />
          </details>
          <details
            phx-mounted={JS.ignore_attributes("open")}
            class="panel disclosure result-history"
            id="check-execution-history"
          >
            <summary>Execution evidence ({length(@evidence)} in this view)</summary>
            <p>
              Reports in receipt order, including late or historical reports. The confirmed measurement above keeps its own original age and configuration.
            </p>
            <.evidence_table
              evidence={@evidence}
              now={@now}
              retired={retired?(@assignment)}
              result_key={@stream["result_key"]}
            />
            <p :if={(get_in(@limits, ["evidence", "missing"]) || 0) > 0} class="panel-footer">
              {get_in(@limits, ["evidence", "missing"])} referenced observations are no longer retained. The recorded history and measurement identities remain available.
            </p>
          </details>
          <details
            phx-mounted={JS.ignore_attributes("open")}
            class="panel disclosure result-history"
            id="check-control-history"
          >
            <summary>Operator control history ({length(@controls)} in this view)</summary>
            <p :if={@controls == []} class="empty">
              No controls are recorded in this timeline.
            </p>
            <div :if={@controls != []} class="timeline">
              <div :for={control <- @controls} class="timeline-item">
                <h3>{humanize(control["kind"])}</h3><p>{control["reason"]}</p>
                <small>{control["actor"]} · recorded {time(control["inserted_at"])}{control_lifetime(
                  control
                )}</small>
              </div>
            </div>
            <p class="panel-footer">
              Maintenance windows keep their own <.link
                navigate={maintenance_path(@assignment["id"], @stream["id"], false)}
                class="text-link"
              >maintenance history</.link>.
            </p>
            <.inspection_limit counts={@limits["controls"]} label="operator controls" />
          </details>
        </div><aside class="stack">
          <.source_details assignment={@assignment} />
          <section class="panel">
            <div class="panel-heading">
              <h2>Shared check configuration</h2><.badge value={config_status(@scheduled_check)} />
            </div><div class="panel-body">
              <dl class="kv-list">
                <div :for={{key, value} <- Enum.sort(@assignment["params"] || %{})} class="kv">
                  <dt>{parameter_label(key)}</dt><dd>{parameter_value(value)}</dd>
                </div>
              </dl><.stages :if={!retired?(@scheduled_check)} assignment={@scheduled_check} />
              <div
                :if={
                  @current["confirmed_params"] &&
                    @current["confirmed_generation"] != @assignment["desired_generation"]
                }
                class="space-top"
                id="last-measured-parameters"
              >
                <h3>Last measured values ({generation(@current["confirmed_generation"])})</h3>
                <dl class="kv-list">
                  <div :for={{key, value} <- Enum.sort(@current["confirmed_params"])} class="kv">
                    <dt>{parameter_label(key)}</dt><dd>{parameter_value(value)}</dd>
                  </div>
                </dl>
              </div>
            </div>
          </section><.maintenance_form
            :if={!retired?(@assignment)}
            assignment={@assignment}
            now={@now}
            windows={@maintenance_windows}
            stream_id={@stream["id"]}
          />
        </aside>
      </div>
    </div>
    """
  end

  defp result_target_context_path(%{"stream" => stream, "assignment" => assignment}, return_to)
       when is_map(stream) and is_map(assignment) do
    row = Map.merge(stream, Map.take(assignment, ["source_id"]))

    filters =
      case return_to && URI.parse(return_to) do
        %URI{path: "/checks", query: query} ->
          CheckInventory.normalize(URI.decode_query(query || ""))

        _ ->
          CheckInventory.normalize(%{
            "status" => if(stream["retired_at"], do: "all", else: "active")
          })
      end

    inventory_origin = match?(%URI{path: "/checks"}, return_to && URI.parse(return_to))

    CheckInventory.target_context_path(
      Mondek.Inspection.target_id(row),
      filters,
      inventory_origin
    )
  end

  defp result_target_context_path(_, _), do: nil
end
