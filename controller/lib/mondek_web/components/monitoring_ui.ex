# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MonitoringUI do
  use MondekWeb, :html
  import MondekWeb.EvidencePresentation
  alias Mondek.Monitoring
  alias MondekWeb.CheckDiagnostics
  alias Phoenix.LiveView.JS

  def setup(assigns) do
    ~H"""
    <section class="panel space-top" id="runner-onboarding">
      <div class="panel-body">
        <div class="eyebrow">Runner-provided monitoring</div><h2>Waiting for check inventory</h2>
        <p class="space-top">
          Install your consumer package on a runner and configure its environment and datasource access there. The runner publishes its checks and expected results to Mondek.
        </p>
        <ol class="helper-list space-top">
          <li>Define stable check and result keys in your consumer package.</li>
          <li>Start a runner with that package and this Mondek server address.</li>
          <li>Review the published inventory here, then wait for scheduled measurements.</li>
        </ol>
        <p class="space-top">
          Code and target membership stay with the source. This UI edits parameters only when the check explicitly delegates them.
        </p>
        <.link navigate="/runners" class="button space-top">Inspect runner connections</.link>
        <.link navigate="/guide" class="button space-top">Set up a runner</.link>
        <.link navigate="/checks?status=retired" class="text-link space-top">Inspect retired result history</.link>
      </div>
    </section>
    """
  end

  def inventory_filters(assigns) do
    assigns =
      assign(assigns, runner_names: distinct_runner_names(assigns.snapshot["runners"] || []))

    ~H"""
    <datalist id="inventory-environments"><option
      :for={environment <- @snapshot["environments"] || []}
      value={environment_id(environment)}
      label={environment_option_label(environment)}
    /></datalist>
    <form
      id="inventory-filters"
      class="inventory-filters"
      phx-submit="filter"
      phx-change="filter"
      phx-auto-recover="recover_filters"
    >
      <div class="field inventory-search">
        <label for="inventory-search">Search</label>
        <input
          id="inventory-search"
          name="search"
          value={@filters["search"] || ""}
          phx-debounce="300"
          placeholder="Check, target, or source"
        />
      </div>
      <div class="field">
        <label for="inventory-runner">Observing runner</label><select
          id="inventory-runner"
          name="runner_id"
        >
          <option value="">All runners</option><option
            :for={runner <- @snapshot["runners"] || []}
            value={runner["installation_id"] || runner["id"]}
            selected={@filters["runner_id"] == (runner["installation_id"] || runner["id"])}
          >
            {@runner_names[runner["installation_id"] || runner["id"]]}
          </option>
        </select>
      </div>
      <div class="field">
        <label for="inventory-environment">Monitored environment</label><input
          id="inventory-environment"
          list="inventory-environments"
          name="environment"
          value={@filters["environment"] || ""}
          phx-debounce="300"
          placeholder="All environments"
          aria-describedby="inventory-environment-help"
        />
      </div>
      <div :if={@mode == :configuration} class="field">
        <label for="inventory-configuration-stage">Configuration adoption</label><select
          id="inventory-configuration-stage"
          name="configuration_stage"
          aria-describedby="configuration-adoption-help"
        >
          <option value="">All adoption stages</option><option
            :for={{value, name} <- configuration_stage_options()}
            value={value}
            selected={@filters["configuration_stage"] == value}
          >
            {name}
          </option>
        </select>
      </div>
      <div class="field">
        <label for="inventory-status">{if @mode == :incidents,
          do: "Incident status",
          else: "Membership"}</label><select id="inventory-status" name="status">
          <option
            :for={{value, name} <- status_options(@mode)}
            value={value}
            selected={(@filters["status"] || default_status(@mode)) == value}
          >
            {name}
          </option>
        </select>
      </div>
      <button type="submit" class="button">Apply filters</button><.link
        patch={filter_path(@mode, result_page_size_filter(@filters, @mode))}
        class="text-link"
      >Clear filters</.link>
      <p id="inventory-environment-help" class="inventory-filter-help">
        Monitored environment: choose a suggestion or enter an environment ID.
      </p>
    </form>
    """
  end

  def pagination(assigns) do
    pages = max(1, ceil(assigns.listing["total"] / assigns.listing["page_size"]))
    assigns = assign(assigns, pages: pages)

    ~H"""
    <nav class="panel-footer pagination" aria-label="Result pages">
      <span role="status">Page {@listing["page"]} of {@pages} · {@listing[
        "total"
      ]} matching</span>
      <div class="pagination-actions">
        <.link
          :if={@listing["page"] > 1}
          patch={filter_path(@mode, Map.put(@filters, "page", @listing["page"] - 1))}
          class="button small"
        >Previous</.link>
        <.link
          :if={@listing["page"] < @pages}
          patch={filter_path(@mode, Map.put(@filters, "page", @listing["page"] + 1))}
          class="button small"
        >Next</.link>
      </div>
    </nav>
    """
  end

  def source_details(assigns) do
    ~H"""
    <section class="panel" id="check-source">
      <div class="panel-heading">
        <h2>Source & execution</h2>
      </div><div class="panel-body">
        <p :if={source_check?(@assignment)} class="source-intro">
          Check logic, scheduling, targets and expected results are defined in your Python project. Publish code changes through its runner.
        </p>
        <dl class="kv-list">
          <div class="kv">
            <dt>Observing runner</dt><dd>{runner_label(@assignment)}</dd>
          </div>
          <div class="kv">
            <dt>Source</dt><dd>{source_label(@assignment)}</dd>
          </div>
          <div class="kv">
            <dt>Monitored environment</dt><dd>{environment_name(@assignment)}</dd>
          </div>
          <div class="kv">
            <dt>Parameter ownership</dt><dd>{owner_label(@assignment)}</dd>
          </div>
        </dl>
        <dl class="source-schedule" id="check-schedule">
          <div>
            <dt>Runs every</dt><dd>
              {MondekWeb.Duration.format_seconds(@assignment["interval_seconds"])}
            </dd>
          </div>
          <div>
            <dt>Times out after</dt><dd>
              {MondekWeb.Duration.format_seconds(@assignment["timeout_seconds"])}
            </dd>
          </div>
          <div>
            <dt>Freshness limit</dt><dd>
              {MondekWeb.Duration.format_seconds(@assignment["freshness_seconds"])}
            </dd>
          </div>
        </dl>
        <p class="footnote space-top">
          The freshness limit controls when the last measurement becomes overdue.
        </p>
      </div>
      <details
        :if={source_check?(@assignment)}
        phx-mounted={JS.ignore_attributes("open")}
        class="disclosure"
        id="check-source-revisions"
      >
        <summary>Technical source details</summary>
        <dl class="kv-list space-top source-revisions">
          <div class="kv">
            <dt>Check key</dt><dd>{@assignment["source_key"]}</dd>
          </div>
          <div :if={get_in(@assignment, ["target", "key"])} class="kv">
            <dt>Target ID</dt><dd>{get_in(@assignment, ["target", "key"])}</dd>
          </div>
          <div class="kv">
            <dt>Source revision</dt><dd class="mono">{@assignment["source_revision"]}</dd>
          </div>
          <div class="kv">
            <dt>Definition revision</dt><dd class="mono">{@assignment["definition_revision"]}</dd>
          </div>
        </dl>
      </details>
      <details
        :if={source_check?(@assignment)}
        phx-mounted={JS.ignore_attributes("open")}
        class="disclosure"
        id="check-source-lifecycle"
      >
        <summary>Removing checks and results</summary>
        <p>
          Remove the declaration in your Python project and restart its runner. When the controller accepts the runner's complete inventory, missing checks or results retire from active monitoring. Failed imports, missing reports and disconnections keep the previously declared coverage.
        </p>
        <p>
          Open incidents close with the reason “Source removed”, without a recovery measurement. Previous incidents and evidence remain available within the normal retention limits.
        </p>
      </details>
    </section>
    """
  end

  def stages(assigns) do
    assigns =
      assigns
      |> assign(:steps, configuration_steps(assigns.assignment))
      |> assign_new(:show_message, fn -> true end)

    ~H"""
    <ol class="stages" aria-label="Configuration adoption stages">
      <li
        :for={step <- @steps}
        class={"stage " <> if(step.complete, do: "complete", else: "")}
        aria-current={if step.current, do: "step"}
      >
        <strong>{step.name}</strong><span>{generation(step.version)}</span>
        <small class="stage-status">{if step.complete,
          do: "Complete",
          else: if(step.current, do: "Waiting", else: "Not reached")}</small>
      </li>
    </ol>
    <p
      :if={@show_message}
      id={"configuration-progress-" <> @assignment["id"]}
      role="status"
      class="footnote space-top"
    >
      {configuration_message(@assignment)}
    </p>
    """
  end

  def incidents_table(assigns) do
    assigns =
      assigns
      |> assign_new(:return_to, fn -> nil end)
      |> assign_new(:empty_title, fn -> "No incidents recorded" end)
      |> assign_new(:empty_description, fn ->
        "When a check observes a failure, its incident and notification history will appear here."
      end)

    ~H"""
    <div :if={@incidents == []} class="empty">
      <div class="empty-icon"><.icon name="check" /></div><h3>{@empty_title}</h3><p>
        {@empty_description}
      </p>
    </div>
    <div :if={@incidents != []} class="table-wrap">
      <table class="incident-table" role="table">
        <thead role="rowgroup">
          <tr role="row">
            <th scope="col" role="columnheader">Incident</th><th scope="col" role="columnheader">
              Severity
            </th><th scope="col" role="columnheader">
              Status
            </th><th scope="col" role="columnheader">Opened</th><th scope="col" role="columnheader">
              <span class="sr-only">Inspect incident</span>
            </th>
          </tr>
        </thead><tbody role="rowgroup">
          <tr
            :for={incident <- @incidents}
            role="row"
            id={"incident-row-" <> incident["id"]}
            class={if Monitoring.acknowledgement_active?(incident, @now), do: "incident-acknowledged"}
          >
            <td role="cell">
              <.link navigate={detail_path("/incidents/" <> incident["id"], @return_to)}><strong>{incident_label(
                incident,
                @assignments
              )}</strong></.link><div :if={!condition_incident?(incident)} class="sub">
                {incident_target(incident, @assignments)} · {incident_runner(incident, @assignments)}
              </div><div :if={condition_incident?(incident)} class="sub">
                Shared condition · {incident["open_contribution_count"] || 0} failing {plural(
                  incident["open_contribution_count"] || 0,
                  "result"
                )} · {incident[
                  "observer_count"
                ] || 0} {plural(incident["observer_count"] || 0, "runner")}
              </div><div :if={condition_incident?(incident) && incident["scope_filtered"]} class="sub">
                {incident_matching_summary(incident)} Showing the whole incident.
              </div><div :if={incident["environment"] || condition_incident?(incident)} class="sub">
                {monitored_environment(incident)}
              </div><div class="sub">{incident_summary(incident)}</div>
            </td><td role="cell">
              <span class="incident-mobile-label" aria-hidden="true">Severity</span><.badge value={
                incident["health"]
              } />
            </td><td role="cell">
              <span class="incident-mobile-label" aria-hidden="true">Status</span>
              <div class="incident-status-badges">
                <.badge value={incident["status"]} />
                <span
                  :if={Monitoring.acknowledgement_active?(incident, @now)}
                  class="badge acknowledged"
                >
                  <.icon name="check" size={13} />Acknowledged
                </span>
              </div>
              <span
                :if={Monitoring.acknowledgement_active?(incident, @now)}
                class="sub incident-acknowledged-status"
              >
                Failure notifications held
              </span>
            </td><td role="cell" title={incident["opened_at"]}>
              <span class="incident-mobile-label" aria-hidden="true">Opened</span>{" "}{age(
                incident["opened_at"],
                @now
              )}
            </td><td role="cell">
              <.link
                navigate={detail_path("/incidents/" <> incident["id"], @return_to)}
                aria-label={"Inspect " <> incident_label(incident, @assignments) <> " incident"}
              ><.icon name="arrow" size={15} /></.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def maintenance_form(assigns) do
    assigns = assign(assigns, visible_windows: compact_maintenance_windows(assigns.windows))

    ~H"""
    <section class="panel" id={"maintenance-summary-" <> @assignment["id"]}>
      <div class="panel-heading">
        <h2>Notification maintenance</h2>
      </div><div class="panel-body">
        <p :if={@windows == []}>
          No active or upcoming maintenance windows cover this result or scheduled check.
        </p>
        <ul :if={@windows != []} class="maintenance-candidates">
          <li :for={window <- @visible_windows}>
            <.link navigate={"/maintenance/" <> window["id"]} class="text-link">{window["name"]}</.link>
            <small>{if window["status"] == "active", do: "Active", else: "Upcoming"} · {maintenance_scope_label(
              window["scope"]
            )}</small>
            <small>{acknowledgement_time(window["starts_at"])} – {acknowledgement_time(
              window["ends_at"]
            )}</small>
            <.link
              :if={window["series_id"]}
              navigate={"/maintenance/series/" <> window["series_id"]}
              class="text-link maintenance-series-link"
            >All dates in series</.link>
          </li>
        </ul>
        <p :if={Enum.any?(@windows, & &1["series_id"])} class="footnote space-top">
          Repeating series show their active windows, or their next upcoming window. Open the series for all dates.
        </p>
        <.link
          id="schedule-maintenance"
          navigate={maintenance_path(@assignment["id"], @stream_id, true)}
          class="button space-top"
        >Schedule maintenance</.link>
        <.link
          navigate={maintenance_path(@assignment["id"], @stream_id, false)}
          class="text-link space-top"
        >View maintenance history</.link>
      </div><div class="panel-footer">
        Review the selected checks or targets before saving. Checks continue. Recovery notifications can still be delivered. Ending one window leaves other windows and acknowledgements in effect.
      </div>
    </section>
    """
  end

  def compact_maintenance_windows(windows) do
    active_series =
      windows
      |> Enum.filter(&(&1["series_id"] && &1["status"] == "active"))
      |> MapSet.new(& &1["series_id"])

    {visible, _seen} =
      Enum.reduce(windows, {[], MapSet.new()}, fn window, {visible, seen} ->
        series = window["series_id"]

        cond do
          is_nil(series) or window["status"] == "active" ->
            {[window | visible], seen}

          MapSet.member?(active_series, series) or MapSet.member?(seen, series) ->
            {visible, seen}

          true ->
            {[window | visible], MapSet.put(seen, series)}
        end
      end)

    Enum.reverse(visible)
  end

  def maintenance_scope_label("selection"), do: "Selected checks and targets"
  def maintenance_scope_label("target"), do: "Matching target results"
  def maintenance_scope_label(_), do: "All results of this scheduled check"

  def maintenance_path(assignment_id, stream_id, create?) do
    params =
      if create?,
        do: %{"check_id" => assignment_id},
        else: %{"assignment_id" => assignment_id, "status" => "history"}

    params = if stream_id, do: Map.put(params, "stream_id", stream_id), else: params
    if(create?, do: "/maintenance/new?", else: "/maintenance?") <> URI.encode_query(params)
  end

  attr(:assignment, :map, required: true)
  attr(:now, :any, required: true)
  attr(:id, :string, required: true)
  attr(:title, :string, default: "Last confirmed measurement")
  attr(:details_id, :string, required: true)
  attr(:provenance_id, :string, required: true)
  attr(:result_keys, :list, default: [])
  attr(:context, :string, default: nil)
  attr(:discovery_href, :string, default: nil)
  attr(:discovery_link_id, :string, default: "result-discovery-review")

  def confirmed_measurement(assigns) do
    assigns =
      assign(assigns,
        current: assigns.assignment["current"] || %{},
        confirmed: confirmed_measurement?(assigns.assignment),
        summary: measurement_summary(assigns.assignment)
      )

    ~H"""
    <section class="panel measurement-panel" id={@id}>
      <div class="panel-heading">
        <h2>{@title}</h2>
        <div class="status-line">
          <.badge value={if @confirmed, do: @current["health"], else: "not_measured"} />
          <.badge value={knowledge(@assignment)} />
        </div>
      </div>
      <div class="panel-body">
        <.measurement_notice assignment={@assignment} />
        <p class="measurement-summary">{@summary}</p>
        <p :if={@context} class="footnote space-top">{@context}</p>
        <dl :if={@confirmed} class="measurement-context">
          <div>
            <dt>Measurement age</dt>
            <dd>
              <time datetime={@current["source_at"]} title={time(@current["source_at"])}>{age(
                @current["source_at"],
                @now
              )}</time>
            </dd>
          </div>
          <div :if={is_number(@current["value"])}>
            <dt>Measured value</dt><dd>{display_number(@current["value"])} {unit(@assignment)}</dd>
          </div>
        </dl>
        <.diagnostic_details
          :if={@confirmed}
          text={@current["details"]}
          title="Check details"
          id={@details_id}
          expanded={true}
        />
        <.link
          :if={@discovery_href}
          id={@discovery_link_id}
          navigate={@discovery_href}
          class="button space-top"
        >Review discovered resources</.link>
      </div>
      <details
        phx-mounted={JS.ignore_attributes("open")}
        class="disclosure measurement-provenance"
        id={@provenance_id}
      >
        <summary>Measurement timing &amp; configuration</summary>
        <dl class="fact-grid space-top">
          <div class="fact">
            <dt>Source measured at</dt><dd>
              {if @confirmed, do: time(@current["source_at"]), else: "Not measured"}
            </dd>
          </div>
          <div class="fact">
            <dt>Check evaluated at</dt><dd>
              {if @confirmed, do: time(@current["confirmed_evaluated_at"]), else: "Not measured"}
            </dd>
          </div>
          <div class="fact">
            <dt>Last measured version</dt><dd id="confirmed-configuration">
              {if @confirmed, do: generation(@current["confirmed_generation"]), else: "Not measured"}
            </dd>
          </div>
          <div class="fact">
            <dt>Latest accepted execution</dt><dd>{time(@current["evaluated_at"])}</dd>
          </div>
          <div class="fact">
            <dt>Execution received at</dt><dd>{time(@current["received_at"])}</dd>
          </div>
          <div class="fact">
            <dt>Execution version</dt><dd id="execution-configuration">
              {generation(@current["generation"])}
            </dd>
          </div>
          <div class="fact">
            <dt>Freshness limit</dt><dd>
              {MondekWeb.Duration.format_seconds(@assignment["freshness_seconds"])}
            </dd>
          </div>
          <div :if={@result_keys != []} class="fact">
            <dt>Expected output</dt><dd>{Enum.join(@result_keys, ", ")}</dd>
          </div>
        </dl>
        <p>
          Source time is when the input was measured. Evaluation and receipt describe execution and delivery; they do not make an older measurement fresh.
        </p>
      </details>
    </section>
    """
  end

  def confirmed_measurement?(assignment),
    do: not is_nil(get_in(assignment, ["current", "confirmed_observation_id"]))

  def measurement_summary(assignment) do
    cond do
      confirmed_measurement?(assignment) -> get_in(assignment, ["current", "summary"])
      retired?(assignment) -> "Monitoring was retired without a confirmed measurement."
      true -> "No confirmed measurement yet."
    end
  end

  def evidence_table(assigns) do
    assigns =
      assigns
      |> assign_new(:retired, fn -> false end)
      |> assign_new(:incident, fn -> %{} end)
      |> assign_new(:result_key, fn -> nil end)
      |> assign_new(:empty_title, fn -> nil end)
      |> assign_new(:empty_description, fn -> nil end)

    ~H"""
    <div :if={@evidence == []} class="empty">
      <h3>
        {@empty_title ||
          if(@retired, do: "No retained execution evidence", else: "No retained evidence yet")}
      </h3><p>
        {@empty_description ||
          if(@retired,
            do: "Monitoring has ended for this result. No future measurement is expected for it.",
            else: "Scheduled reports will appear once the runner collects and delivers them."
          )}
      </p>
    </div>
    <div :for={evidence <- @evidence} class="resource" id={"evidence-" <> report(evidence)["id"]}>
      <div class="resource-name">
        <h3>{evidence_heading(evidence, @incident)}</h3><.badge value={
          evidence["disposition"] || "historical"
        } /><span :if={report(evidence)["complete"] == false} class="badge unavailable">Incomplete collection</span><small>Configuration version {generation(
          report(evidence)["generation"]
        )}</small>
      </div>
      <div :for={result <- evidence_results(evidence, @result_key)}>
        <p class="resource-summary">
          <.badge value={result["health"]} /> <strong>{result["key"]}</strong> {result["summary"]}
        </p>
        <.diagnostic_details
          text={result["details"]}
          title={"Result details: " <> result["key"]}
          id={"result-details-" <> report(evidence)["id"] <> "-" <> Base.url_encode64(result["key"], padding: false)}
        />
      </div>
      <p :if={report(evidence)["diagnostic"] not in [nil, ""]} class="resource-summary">
        {report(evidence)["diagnostic"]}
      </p>
      <div class="resource-meta">
        <span>Executed
        <strong title={report(evidence)["evaluated_at"]}>{age(report(evidence)["evaluated_at"], @now)}</strong></span><span>Received
        <strong>{age(evidence["received_at"] || evidence["inserted_at"], @now)}</strong></span><span class="mono">{String.slice(
          report(evidence)["id"] || evidence["id"] || "",
          0,
          8
        )}</span>
      </div>
      <details
        phx-mounted={JS.ignore_attributes("open")}
        class="space-top"
        id={"raw-evidence-" <> report(evidence)["id"]}
      >
        <summary class="footnote">Inspect evidence and original timestamps</summary><pre>{Jason.encode!(report(evidence), pretty: true)}</pre>
      </details>
    </div>
    """
  end

  def evidence_heading(evidence, incident) do
    id = report(evidence)["id"]
    subject = acknowledgement_subject(incident)

    cond do
      incident == %{} ->
        "Run #{report(evidence)["sequence"]}"

      id == incident["opening_observation_id"] ->
        "When this #{subject} opened"

      id == incident["closing_observation_id"] &&
          incident["closure_reason"] == "measured_recovery" ->
        "Recovery measurement"

      id == incident["closing_observation_id"] ->
        "Closing measurement"

      true ->
        "Later measurement in this #{subject}"
    end
  end

  def diagnostic_details(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> nil end)
      |> assign_new(:expanded, fn -> false end)

    ~H"""
    <div
      :if={@expanded && @text not in [nil, ""]}
      class="diagnostic-details measurement-details"
      id={@id}
    >
      <h3>{@title}</h3><pre tabindex="0" role="region" aria-label={@title}>{@text}</pre>
    </div>
    <details
      :if={!@expanded && @text not in [nil, ""]}
      phx-mounted={JS.ignore_attributes("open")}
      class="diagnostic-details space-top"
      id={@id}
    >
      <summary>{@title}</summary><pre>{@text}</pre>
    </details>
    """
  end

  attr(:name, :string, required: true)
  attr(:size, :integer, default: 18)

  def icon(assigns) do
    ~H"""
    <MondekWeb.Layouts.icon name={@name} size={@size} />
    """
  end

  def result_page_size_filter(filters, mode),
    do: MondekWeb.InvestigationNavigation.result_page_size_filter(filters, mode)

  def filter_path(mode, filters),
    do: MondekWeb.InvestigationNavigation.filter_path(mode, filters)

  def inventory_params(params, mode),
    do: MondekWeb.InvestigationNavigation.inventory_params(params, mode)

  def parent_incident_path(incident, return_to),
    do: MondekWeb.InvestigationNavigation.parent_incident_path(incident, return_to)

  def comparable_inventory_filters(filters, mode),
    do: MondekWeb.InvestigationNavigation.comparable_inventory_filters(filters, mode)

  def safe_return_path(value), do: MondekWeb.InvestigationNavigation.safe_return_path(value)

  def detail_path(path, return_to),
    do: MondekWeb.InvestigationNavigation.detail_path(path, return_to)

  def return_label(path, fallback),
    do: MondekWeb.InvestigationNavigation.return_label(path, fallback)

  def controller_origin(uri) do
    parsed = URI.parse(uri)
    URI.to_string(%URI{scheme: parsed.scheme, host: parsed.host, port: parsed.port})
  end

  def default_status(:incidents), do: "open"
  def default_status(_), do: "active"

  def status_options(:incidents),
    do: [{"all", "All incidents"}, {"open", "Open"}, {"closed", "Closed"}]

  def status_options(_),
    do: [{"active", "Active"}, {"retired", "Retired"}, {"all", "All membership"}]

  def page_projection(nil), do: nil
  def page_projection(page), do: Map.new(page, fn {key, value} -> {to_string(key), value} end)
  def source_check?(check), do: check["source_id"] not in [nil, ""]

  def source_label(check), do: check["source_id"]

  def owner_label(check),
    do: if(check["params_owner"] == "ui", do: "Delegated to operator", else: "Source owned")

  def runner_label(check),
    do:
      check["runner_label"] || check["runner_id"] || check["installation_id"] ||
        "Awaiting runner assignment"

  def runner_name(runner),
    do: runner["label"] || runner["name"] || runner["installation_id"] || runner["id"] || "Runner"

  def distinct_runner_names(runners) do
    counts = Enum.frequencies_by(runners, &runner_name/1)

    Map.new(runners, fn runner ->
      id = runner["installation_id"] || runner["id"]
      name = runner_name(runner)
      {id, if(counts[name] > 1, do: name <> " (" <> id <> ")", else: name)}
    end)
  end

  def environment_id(%{"id" => id}), do: id
  def environment_id(id) when is_binary(id), do: id

  def environment_option_label(%{"id" => id} = environment),
    do: named_environment(id, environment["label"])

  def environment_option_label(id), do: named_environment(id, nil)

  def environment_name(check),
    do: named_environment(check["environment"], check["environment_label"])

  def named_environment(nil, _), do: "Not declared"
  def named_environment(id, label) when label in [nil, ""], do: id
  def named_environment(id, id), do: id
  def named_environment(id, label), do: label <> " (" <> id <> ")"
  def parameter_value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def parameter_value(value), do: to_string(value)

  def inspected_assignment(detail) do
    assignment = detail["assignment"] || %{}

    case detail["stream"] do
      stream when is_map(stream) ->
        Map.merge(
          assignment,
          Map.take(
            stream,
            ~w(label target current retired_at retirement_reason runner_label environment environment_label)
          )
        )
        |> Map.put("stream_id", stream["id"])

      _ ->
        assignment
    end
  end

  def incident_label(incident, assignments),
    do:
      incident["result_label"] || incident["label"] ||
        label(find(assignments, incident["assignment_id"]))

  def condition_incident?(incident),
    do: incident["incident_kind"] == "condition" || is_binary(incident["namespace"])

  def incident_matching_summary(incident) do
    total =
      if incident["status"] == "open",
        do: incident["open_contribution_count"],
        else: incident["result_count"]

    scope =
      if incident["status"] == "open",
        do: "contributing " <> plural(total, "result"),
        else: plural(total, "result") <> " in this history"

    "Matches #{incident["matching_result_count"]} of #{total} #{scope}."
  end

  def monitored_environment(incident),
    do:
      if(incident["environment"],
        do: environment_name(incident),
        else: "No monitored environment"
      )

  def incident_target(incident, assignments) do
    if incident["target"],
      do: target_label(incident["target"]),
      else: measured_target(find(assignments, incident["assignment_id"]))
  end

  def incident_runner(incident, assignments) do
    if incident["runner_label"] || incident["runner_id"],
      do: runner_label(incident),
      else: runner_label(find(assignments, incident["assignment_id"]))
  end

  def page_name(:configuration), do: "Configuration"
  def page_name(:configuration_detail), do: "Check configuration"
  def page_name(action) when action in [:checks, :check], do: "Checks"
  def page_name(action) when action in [:incidents, :incident], do: "Incidents"
  def page_name(:guide), do: "Runner setup"
  def page_name(:resource), do: "Check detail"

  def page_name(action) when action in [:check_diagnostics, :resource_diagnostics],
    do: "Measurement investigation"

  def page_name(_), do: "Overview"

  def retired?(assignment), do: not is_nil(assignment["retired_at"])

  def target(%{"target" => target}) when is_map(target), do: target_label(target)

  def target(%{"kind" => "filesystem", "params" => params}),
    do: "Linux runner · " <> (params["path"] || "/")

  def target(assignment), do: get_in(assignment, ["params", "url"]) || "Awaiting configuration"

  def measured_target(assignment) do
    case get_in(assignment, ["current", "confirmed_params"]) do
      params when is_map(params) -> target(Map.put(assignment, "params", params))
      _ -> target(assignment)
    end
  end

  def measurement_notice(assigns) do
    assigns = assign(assigns, current: assigns.assignment["current"] || %{})

    ~H"""
    <div
      :if={knowledge(@assignment) != "fresh" && !retired?(@assignment)}
      class="notice warn collection-notice"
      id={"measurement-notice-" <> @assignment["id"]}
    >
      <h3>{String.capitalize(freshness_label(knowledge(@assignment)))}</h3>
      <p>{measurement_explanation(@assignment)}</p>
      <p
        :if={knowledge(@assignment) == "unavailable" && collection_diagnostic(@current)}
        class="collection-diagnostic"
      >
        <span>{collection_diagnostic(@current)}</span>
      </p>
      <.diagnostic_details
        :if={knowledge(@assignment) == "unavailable"}
        text={@current["execution_details"]}
        title="Collection details"
        id={"collection-details-" <> @assignment["id"]}
        expanded={true}
      />
      <.link
        navigate={
          detail_path(CheckDiagnostics.path(@assignment), @assignment["diagnostics_return_to"])
        }
        class="text-link"
      >Investigate measurement</.link>
    </div>
    """
  end

  def freshness_label("unavailable"), do: "measurement unavailable"
  def freshness_label("stale"), do: "measurement overdue"
  def freshness_label("fresh"), do: "fresh"
  def freshness_label(_), do: "waiting for measurement"

  def measurement_explanation(assignment) do
    case knowledge(assignment) do
      "unavailable" ->
        "The latest execution could not produce a complete measurement. " <>
          if(confirmed_measurement?(assignment),
            do:
              "Last measured health is retained below; it does not establish current target health.",
            else: "No confirmed health is available for this result."
          )

      "stale" ->
        "No fresh measurement has arrived within the freshness budget. Last measured health does not establish current target health."

      _ ->
        "Waiting for a complete measurement from the current runner and configuration. Any previous health remains historical."
    end
  end

  def collection_diagnostic(current) do
    Enum.find([current["diagnostic"], current["execution_summary"]], &(&1 not in [nil, ""]))
  end

  def parameter_label("warn_percent"), do: "Warning at (% used)"
  def parameter_label("crit_percent"), do: "Critical at (% used)"
  def parameter_label("warn_count"), do: "Warning at (items)"
  def parameter_label("crit_count"), do: "Critical at (items)"
  def parameter_label("url"), do: "Target URL"
  def parameter_label("path"), do: "Target path"
  def parameter_label(key), do: humanize(key)

  def configuration_steps(assignment) do
    desired = assignment["desired_generation"]

    values = [
      {"Saved", desired},
      {"Prepared", assignment["prepared_generation"]},
      {"Active", assignment["active_generation"]},
      {"Measured", measured_generation(assignment)}
    ]

    waiting = Enum.find_index(values, fn {_, value} -> value != desired end)

    values
    |> Enum.with_index()
    |> Enum.map(fn {{name, version}, index} ->
      %{name: name, version: version, complete: version == desired, current: index == waiting}
    end)
  end

  def configuration_message(assignment) do
    version = generation(assignment["desired_generation"])

    message =
      case config_status(assignment) do
        "measured" ->
          "Version #{version} has produced complete measured evidence. Measurement freshness is shown separately."

        "active" ->
          "Version #{version} is active. Waiting for its first complete, fresh measurement."

        "prepared" ->
          "Version #{version} is prepared. Waiting for the runner to activate it."

        _ ->
          "Version #{version} is saved. Waiting for runner preparation; offline changes remain pending."
      end

    "#{label(assignment)}: #{message}"
  end

  def unit(%{"kind" => "filesystem"}), do: "% used"
  def unit(%{"kind" => "consumer"}), do: "items"
  def unit(_), do: ""

  def configuration_stage_options,
    do: [
      {"saved", "Saved — waiting for preparation"},
      {"prepared", "Prepared — waiting for activation"},
      {"active", "Active — waiting for measurement"},
      {"measured", "Measured"}
    ]

  def knowledge(assignment), do: get_in(assignment, ["current", "knowledge"]) || "pending"

  def measured_generation(assignment) do
    if source_check?(assignment) && !assignment["target"],
      do: assignment["observed_generation"],
      else: get_in(assignment, ["current", "confirmed_generation"])
  end

  def config_status(assignment) do
    desired = assignment["desired_generation"]

    cond do
      retired?(assignment) -> "retired"
      desired && measured_generation(assignment) == desired -> "measured"
      desired && assignment["active_generation"] == desired -> "active"
      desired && assignment["prepared_generation"] == desired -> "prepared"
      true -> "pending"
    end
  end

  def generation(nil), do: "—"
  def generation(0), do: "—"
  def generation(value), do: "v#{value}"

  def evidence_results(evidence, nil), do: report(evidence)["results"] || []

  def evidence_results(evidence, key),
    do: Enum.filter(report(evidence)["results"] || [], &(&1["key"] == key))

  def report(evidence), do: evidence["payload"] || evidence["report"] || evidence

  def incident_summary(%{"closure_reason" => reason}) when is_binary(reason),
    do: humanize(reason)

  def incident_summary(_), do: "Observed failure remains unresolved"
  def display_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def display_number(value), do: to_string(value)

  def integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> -1
    end
  end

  def acknowledgement_subject(incident),
    do: if(incident["condition_incident_id"], do: "contribution", else: "incident")

  def control_lifetime(%{"acknowledgement_mode" => "until_incident_ends"} = control),
    do: " · until this incident ends" <> control_ceiling(control)

  def control_lifetime(%{"acknowledgement_mode" => "ended"}), do: ""

  def control_lifetime(%{"kind" => "acknowledgement"} = control),
    do:
      " · until " <>
        acknowledgement_time(control["until"]) <>
        control_ceiling(control)

  def control_lifetime(%{"kind" => "maintenance"} = control),
    do: " · until " <> time(control["until"])

  def control_lifetime(_), do: ""

  def control_ceiling(%{"acknowledgement_ceiling" => ceiling}) when is_binary(ceiling),
    do: " · covers #{badge_text(ceiling)} severity and below"

  def control_ceiling(_), do: ""

  def error_message({:invalid, message}) when is_binary(message), do: message
  def error_message({:conflict, message}) when is_binary(message), do: message
  def error_message(message) when is_binary(message), do: message

  def error_message(:review_expired),
    do: "The review expired. Preview the change again before saving."

  def error_message(:review_required), do: "Preview the change before saving."

  def error_message(:stale),
    do: "This check changed after you reviewed it. Review the latest check before trying again."

  def error_message(:source_owned),
    do: "These parameters are owned by the source. Publish changes from the runner configuration."

  def error_message(:retired), do: "This check has been retired. Its history remains available."

  def error_message(:not_exhausted),
    do: "This notification is no longer exhausted. Review its current delivery status."

  def error_message(:delivery_in_progress),
    do:
      "The previous delivery job is still finishing. Wait briefly and review its status before retrying."

  def error_message(:superseded),
    do: "This notification no longer applies to the current incident and cannot be retried."

  def error_message(:not_found),
    do: "This record is no longer available. Reload the page to review current state."

  def error_message(_), do: "The change could not be saved. Check the values and try again."

  def related_maintenance(detail) do
    cond do
      id = get_in(detail || %{}, ["stream", "id"]) -> Mondek.Maintenance.for_stream(id)
      id = get_in(detail || %{}, ["incident", "stream_id"]) -> Mondek.Maintenance.for_stream(id)
      id = get_in(detail || %{}, ["assignment", "id"]) -> Mondek.Maintenance.for_assignment(id)
      true -> []
    end
  end
end
