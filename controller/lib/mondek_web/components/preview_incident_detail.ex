# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewIncidentDetail do
  use MondekWeb, :html
  import MondekWeb.CheckDetails, only: [check_details: 1]
  import MondekWeb.EvidencePresentation, only: [time: 1, badge_text: 1, target_label: 1]
  alias Mondek.Monitoring
  alias MondekWeb.{PreviewDetail, PreviewIncidentSections}

  attr :target, :any, default: nil
  attr :entity, :string, default: nil
  attr :incident, :any, required: true
  attr :detail, :any, required: true
  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :type_label, :string, required: true
  attr :now, :any, required: true
  attr :current, :string, required: true
  attr :id_prefix, :string, required: true
  attr :full_page, :boolean, required: true
  attr :control_review, :any, required: true
  attr :control_draft, :map, required: true
  attr :control_replacing, :boolean, required: true
  attr :control_feedback, :any, required: true
  attr :delivery_feedback, :any, required: true
  attr :retry_drafts, :map, required: true
  attr :maintenance_windows, :list, required: true
  attr :detail_filters, :map, required: true
  attr :delivery_statuses, :list, required: true
  attr :result_path, :any, required: true
  attr :incident_path, :any, required: true
  attr :expected_path, :any, required: true
  attr :page_path, :any, required: true
  attr :filter_path, :any, required: true

  def body(assigns) do
    ~H"""
    <header class="preview-incident-intro">
      <p :if={@incident && !@detail["contributions"]} class="preview-caption">
        {@type_label}<span :if={@incident["scope_kind"] == "coverage"}> · {@incident[
          "source_id"
        ]}</span>
      </p>
      <PreviewDetail.heading
        level={if @full_page, do: 1, else: 2}
        id={@id_prefix <> "incident-heading"}
      >
        {@title}
      </PreviewDetail.heading>
      <div :if={@incident} class="preview-incident-meta">
        <.shared_incident_badge
          :if={@detail["contributions"]}
          count={@detail["counts"]["total"]}
        />
        <.severity :if={@incident["health"]} health={@incident["health"]} />
        <.incident_state
          status={@incident["status"]}
          acknowledged={Monitoring.acknowledgement_active?(@incident, @now)}
        />
      </div>
      <aside
        :if={@incident && Monitoring.acknowledgement_active?(@incident, @now)}
        class="preview-acknowledged-section"
        aria-label="Incident acknowledgement"
      >
        <strong>Acknowledged {if @incident["acknowledged_until"],
          do: "until " <> time(@incident["acknowledged_until"]),
          else: "until incident ends"}</strong>
        <p>{@incident["acknowledgement_note"]}</p>
        <p class="preview-caption">Failure notifications are held. This incident remains open.</p>
      </aside>
      <dl :if={@incident} class="preview-incident-facts">
        <div>
          <dt>Opened</dt>
          <dd><time datetime={@incident["opened_at"]}>{time(@incident["opened_at"])}</time></dd>
        </div>
        <div :if={@incident["closed_at"]}>
          <dt>Ended</dt>
          <dd><time datetime={@incident["closed_at"]}>{time(@incident["closed_at"])}</time></dd>
        </div>
        <div :if={@incident["member_count"]}>
          <dt>Affected results</dt><dd>{@incident["member_count"]}</dd>
        </div>
      </dl>
    </header>
    <p :if={!@incident} class="preview-empty">
      This incident may have been removed by retention.
    </p>
    <.health_evidence
      :if={@incident && @kind == "health"}
      full_page={@full_page}
      detail={@detail}
      current={@current}
      id_prefix={@id_prefix}
      result_path={@result_path}
      incident_path={@incident_path}
      page_path={@page_path}
      filter_path={@filter_path}
    />
    <.correlation_candidates
      :if={
        @kind == "health" && @incident &&
          show_candidates?(@detail["correlation_candidates"], @incident["status"])
      }
      evidence={@detail["correlation_candidates"]}
      incident_id={@incident["id"]}
      full_page={@full_page}
      id_prefix={@id_prefix}
      incident_path={@incident_path}
    />
    <.loss_evidence
      :if={@incident && @kind == "loss"}
      full_page={@full_page}
      id_prefix={@id_prefix}
      detail={@detail}
      current={@current}
      result_path={@result_path}
      expected_path={@expected_path}
      page_path={@page_path}
    />
    <PreviewIncidentSections.sections
      :if={@incident}
      full_page={@full_page}
      incident={@incident}
      detail={@detail}
      kind={@kind}
      now={@now}
      review={@control_review}
      draft={@control_draft}
      replacing={@control_replacing}
      feedback={@control_feedback}
      delivery_feedback={@delivery_feedback}
      retry_drafts={@retry_drafts}
      maintenance_windows={@maintenance_windows}
      current={@current}
      id_prefix={@id_prefix}
      target={@target}
      entity={@entity}
      result_path={@result_path}
      expected_path={@expected_path}
    >
      <:delivery_filter>
        <.detail_filter
          :if={@detail["notification_page"]}
          id_prefix={@id_prefix}
          field="notification_status"
          label="Delivery status"
          choices={@delivery_statuses}
          value={@detail_filters["notification_status"]}
          target={@target}
          entity={@entity}
        />
      </:delivery_filter>
      <:delivery_pagination>
        <.detail_pages
          :if={@detail["notification_page"]}
          listing={@detail["notification_page"]}
          page_path={@page_path}
          param="notification_page"
          label="Notification pages"
        />
      </:delivery_pagination>
    </PreviewIncidentSections.sections>
    <PreviewDetail.card
      :if={@incident}
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "incident-investigation-help"}
      title="Investigation help"
    >
      <div class="preview-incident-evidence">
        <MondekWeb.AgentPrompts.prompt
          id={@id_prefix <> "incident-agent-prompts-incident"}
          kind={:incident}
          context={
            Map.merge(
              Map.take(@incident, ~w(health source_id result_key condition_namespace condition_key)),
              %{
                "controller_url" => MondekWeb.Endpoint.url(),
                "incident_id" => @incident["id"],
                "incident_kind" => @kind,
                "incident_status" => @incident["status"],
                "runner_id" => @incident["runner_id"],
                "check_id" => @incident["assignment_id"],
                "page_path" => @current
              }
            )
          }
        />
      </div>
    </PreviewDetail.card>
    """
  end

  defp show_candidates?(nil, _), do: false
  defp show_candidates?(%{"status" => "unavailable"}, "closed"), do: false

  defp show_candidates?(evidence, _),
    do: evidence["status"] != "complete" or evidence["hint_count"] > 0

  defp correlation_candidates(assigns) do
    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "correlation-candidates"}
      title="Correlation candidates"
    >
      <div class="preview-incident-evidence">
        <p :if={@evidence["status"] == "unavailable"}>Candidate evidence is unavailable.</p>
        <p :if={@evidence["status"] == "incomplete"}>Candidate evidence is incomplete.</p>
        <p :if={@evidence["truncated"]}>
          The search reached its limit. Additional matches may exist.
        </p>
        <p :if={@evidence["conflicting_hints"]}>
          Contributors declared different dependency hints.
        </p>
        <p :if={@evidence["status"] == "complete" && @evidence["candidates"] == []}>
          No incidents matched the declared dependencies.
        </p>
        <div :for={candidate <- @evidence["candidates"]}>
          <.link patch={@incident_path.(candidate["id"], candidate["type"] == "individual")}>
            {candidate["label"]}
          </.link>
          <ul>
            <li :for={match <- candidate["matches"]}>
              {match["dimension"]} · {selector_label(match["depends_on"])} · {timing_label(
                match,
                candidate["type"],
                @evidence["subject"]["type"]
              )}
              <details>
                <summary>Hint provenance</summary>
                <ul>
                  <li :for={ref <- match["contributors"]}>
                    <.link
                      :if={ref["incident_id"] != @incident_id}
                      patch={@incident_path.(ref["incident_id"], true)}
                    >
                      Contributor {ref["incident_id"]}
                    </.link>
                    Opening generation {ref["generation"]} · Scheduled check {ref["assignment_id"]}
                  </li>
                </ul>
              </details>
            </li>
          </ul>
        </div>
      </div>
    </PreviewDetail.card>
    """
  end

  defp selector_label(%{"type" => "condition", "namespace" => ns, "key" => key}),
    do: "Condition #{ns}/#{key}"

  defp selector_label(%{"type" => "target", "source_id" => source, "kind" => kind, "key" => key}),
    do: "Target #{source}/#{kind}/#{key}"

  defp timing_label(match, candidate_type, subject_type) do
    candidate =
      if candidate_type == "condition" && match["depends_on"]["type"] == "target",
        do: "Matching target contribution",
        else: "Matching episode"

    subject =
      if subject_type == "condition", do: "the declaring contribution", else: "this incident"

    case match["timing"] do
      "overlap" ->
        "#{candidate} was open when #{subject} began"

      "later_opening" ->
        "#{candidate} opened within #{match["window_seconds"]} seconds after #{subject} began"
    end
  end

  defp health_evidence(assigns) do
    detail = assigns.detail
    incident = detail["incident"]

    measured = get_in(detail, ["recorded_measurement", "measurement"])

    assign(assigns,
      incident: incident,
      measured: measured,
      measured_at: measured && (measured["source_at"] || measured["evaluated_at"])
    )
    |> render_health_evidence()
  end

  defp render_health_evidence(assigns) do
    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-health-evidence"}
      title={if @detail["contributions"], do: "Contributing results", else: "Recorded failure"}
    >
      <PreviewDetail.facts
        :if={!@detail["contributions"]}
        label="Recorded failure"
      >
        <tr>
          <th scope="row">Finding</th>
          <td class="preview-incident-finding">
            <.severity :if={@measured && @measured["health"]} health={@measured["health"]} />
            {if @measured,
              do: @measured["summary"],
              else: "The recorded measurement is unavailable."}
          </td>
        </tr>
        <tr :if={@measured && @detail["recorded_measurement"]["basis"] != "latest_failure"}>
          <th scope="row">Evidence</th><td>
            Retained failure evidence; latest failure is unavailable.
          </td>
        </tr>
        <tr :if={@detail["stream"]}>
          <th scope="row">Target</th><td>{target_label(@detail["stream"]["target"])}</td>
        </tr>
        <tr :if={@detail["stream"]}>
          <th scope="row">Environment</th>
          <td>
            {@detail["stream"]["environment_label"] || @detail["stream"]["environment"] ||
              "Unscoped"}
          </td>
        </tr>
        <tr :if={@measured && @measured_at}>
          <th scope="row">Measured</th>
          <td><time datetime={@measured_at}>{time(@measured_at)}</time></td>
        </tr>
        <tr :if={@measured && @measured["details"] not in [nil, ""]}>
          <th scope="row">Check details</th><td>
            <.check_details text={@measured["details"]} />
          </td>
        </tr>
      </PreviewDetail.facts>
      <div :if={!@detail["contributions"] && @incident["stream_id"]} class="preview-recorded-actions">
        <.check_result_link
          result_path={@result_path}
          id={@incident["stream_id"]}
        >View latest check result →</.check_result_link>
      </div>
      <div :if={@incident["condition_incident_id"]} class="preview-recorded-actions">
        <.link patch={@incident_path.(@incident["condition_incident_id"], false)}>
          Open shared incident and its notifications
        </.link>
      </div>
      <PreviewDetail.facts
        :if={
          @detail["contributions"] &&
            (@incident["status"] == "open" || (@incident["impacts"] || []) != [])
        }
        label="Shared incident summary"
      >
        <tr :if={(@incident["impacts"] || []) != []}>
          <th scope="row">Impacts</th>
          <td>{Enum.map_join(@incident["impacts"], ", ", &(&1["label"] || &1["key"]))}</td>
        </tr>
        <tr :if={@incident["status"] == "open"}>
          <th scope="row">Failure notifications</th>
          <td>
            <p>
              Unpaused for {@detail["counts"]["uncovered"]} of {@detail["counts"]["open"]} failing results
            </p>
            <.link
              :if={
                @detail["contribution_page"]["state"] != "uncovered" &&
                  @detail["counts"]["uncovered"] > 0
              }
              patch={@filter_path.(%{"contributors" => "uncovered", "member_page" => "1"})}
            >Show results with unpaused notifications</.link>
          </td>
        </tr>
      </PreviewDetail.facts>
      <div
        :if={
          @detail["contributions"] && @incident["status"] == "open" &&
            (@detail["contribution_page"]["state"] != "open" ||
               @detail["counts"]["recovered"] + @detail["counts"]["withdrawn"] > 0)
        }
        class="preview-recorded-actions"
      >
        <.link
          :if={@detail["contribution_page"]["state"] != "open"}
          patch={@filter_path.(%{"contributors" => "default", "member_page" => "1"})}
        >Show active contributors</.link>
        <.link
          :if={@detail["contribution_page"]["state"] == "open"}
          patch={@filter_path.(%{"contributors" => "history", "member_page" => "1"})}
        >Show historical contributors</.link>
      </div>
      <p :if={@detail["contributions"] == []} class="preview-recorded-actions">
        No contributing results match this view.
      </p>
      <table
        :if={@detail["contributions"] not in [nil, []]}
        class="preview-incident-fact-table preview-contributor-table"
        aria-label="Contributing results"
      >
        <thead>
          <tr>
            <th scope="col">Result</th><th scope="col">Incident details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={contribution <- @detail["contributions"]}>
            <th scope="row">
              <.link patch={@incident_path.(contribution["incident"]["id"], true)}>
                {get_in(contribution, ["stream", "label"]) ||
                  get_in(contribution, ["assignment", "label"])}
              </.link>
              <div :if={contribution["incident"]["stream_id"]} class="preview-caption">
                <.check_result_link
                  result_path={@result_path}
                  id={contribution["incident"]["stream_id"]}
                >
                  Latest check result
                </.check_result_link>
              </div>
            </th>
            <td class="preview-incident-nested-facts">
              <table aria-label="Contributor details">
                <tbody>
                  <tr>
                    <th scope="row">Last failure</th>
                    <td>
                      <.severity health={
                        get_in(contribution, ["recorded_measurement", "measurement", "health"]) ||
                          contribution["last_failure_health"]
                      } />
                      <p :if={
                        get_in(contribution, ["recorded_measurement", "basis"]) not in [
                          nil,
                          "latest_failure"
                        ]
                      }>
                        Retained failure evidence; latest failure is unavailable.
                      </p>
                      <p :if={
                        get_in(contribution, ["recorded_measurement", "status"]) == "unavailable"
                      }>
                        The recorded measurement is unavailable.
                      </p>
                      <p :if={get_in(contribution, ["recorded_measurement", "measurement"])}>
                        {get_in(contribution, ["recorded_measurement", "measurement", "summary"])}
                      </p>
                    </td>
                  </tr>
                  <tr :if={get_in(contribution, ["incident", "impacts"]) not in [nil, []]}>
                    <th scope="row">Impacts</th><td>
                      {Enum.map_join(
                        contribution["incident"]["impacts"],
                        ", ",
                        &(&1["label"] || &1["key"])
                      )}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Collection</th><td>
                      <MondekWeb.PreviewResultDetail.state value={
                        get_in(contribution, ["stream", "current", "knowledge"])
                      } />
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">State</th>
                    <td>
                      <span class={[
                        "pf-v6-c-label",
                        contribution_state_color(contribution["contribution_state"])
                      ]}>
                        <span class="pf-v6-c-label__content">{badge_text(
                          contribution["contribution_state"]
                        )}</span>
                      </span>
                    </td>
                  </tr>
                  <tr :if={
                    contribution["incident"]["status"] == "open" &&
                      (contribution["coverage"]["uncovered"] ||
                         contribution["coverage"]["shared_acknowledgement"] ||
                         contribution["coverage"]["individual_acknowledgement"] ||
                         contribution["coverage"]["maintenance_windows"] not in [nil, []])
                  }>
                    <th scope="row">Notifications</th>
                    <td>
                      <p :if={contribution["coverage"]["uncovered"]}>Not paused</p>
                      <p :if={contribution["coverage"]["shared_acknowledgement"]}>
                        Paused by shared acknowledgement
                      </p>
                      <p :if={contribution["coverage"]["individual_acknowledgement"]}>
                        Paused by individual acknowledgement
                      </p>
                      <p :for={window <- contribution["coverage"]["maintenance_windows"] || []}>
                        Paused for maintenance:
                        <.link href={"/maintenance/" <> window["id"]}>{window["name"] ||
                          window["reason"] || "View maintenance"}</.link>
                        <span class="preview-caption"> · Ends {time(window["ends_at"])}</span>
                      </p>
                    </td>
                  </tr>
                </tbody>
              </table>
            </td>
          </tr>
        </tbody>
      </table>
      <.detail_pages
        :if={@detail["contribution_page"]}
        listing={@detail["contribution_page"]}
        page_path={@page_path}
        param="member_page"
        label="Contributing result pages"
      />
      <details
        :if={(get_in(@detail, ["contradiction_page", "total"]) || 0) > 0}
        id={@id_prefix <> "preview-confirmed-healthy-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary>Last confirmed healthy results ({@detail["contradiction_page"]["total"]})</summary>
        <div class="preview-incident-history-content">
          <p class="preview-incident-evidence">
            These results share the same condition. Their last confirmed measurements were healthy, but collection may now be stale or unavailable.
          </p>
          <PreviewDetail.facts label="Last confirmed healthy results">
            <tr :for={stream <- @detail["contradictions"]}>
              <th scope="row">
                <.check_result_link
                  result_path={@result_path}
                  id={stream["id"]}
                >{stream["label"]}</.check_result_link>
              </th>
              <td>{get_in(stream, ["current", "summary"])}</td>
            </tr>
          </PreviewDetail.facts>
          <.detail_pages
            listing={@detail["contradiction_page"]}
            page_path={@page_path}
            param="healthy_page"
            label="Last confirmed healthy result pages"
          />
        </div>
      </details>
    </PreviewDetail.card>
    """
  end

  defp loss_evidence(assigns) do
    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "preview-loss-evidence"}
      title={if @detail["status"] == "open", do: "Affected results", else: "Last affected results"}
    >
      <p :if={@detail["status"] == "open"} class="preview-incident-evidence">
        {if @detail["scope_kind"] == "coverage",
          do:
            "The monitoring project expects these results. Review how runners are selected for them.",
          else:
            "Mondek is missing current measurements for these results. Check the collection or runner evidence below."}
      </p>
      <p :if={@detail["status"] == "closed"} class="preview-incident-evidence">
        {if @detail["closure_reason"] == "monitoring_restored",
          do: "Monitoring was restored.",
          else: "This monitoring loss incident ended."}
      </p>
      <p :if={@detail["members"]["items"] == []} class="preview-incident-evidence">
        No affected result details are available.
      </p>
      <div :for={member <- @detail["members"]["items"]} class="preview-incident-evidence">
        <.dynamic_tag tag_name={if @full_page, do: "h3", else: "h4"}>
          {member["label"] || target_label(member["target"])}
        </.dynamic_tag>
        <p>
          {loss_reason(member["knowledge"])}
          <span :if={member["since_at"]}>· Since {time(member["since_at"])}</span>
        </p>
        <p class="preview-caption">
          {target_label(member["target"])} · {member["environment"] || "Unscoped"}
        </p>
        <.check_result_link
          :if={member["stream_id"]}
          result_path={@result_path}
          id={member["stream_id"]}
        >View latest check result</.check_result_link>
        <.link
          :if={!member["stream_id"] && member["coverage_id"]}
          patch={@expected_path.(member["coverage_id"])}
        >Review expected monitoring</.link>
      </div>
      <p :if={@detail["members"]["truncated"]} class="preview-incident-evidence">
        {length(@detail["members"]["items"])} of {@detail["member_count"]} affected results retained here.
      </p>
      <.detail_pages
        listing={@detail["members"]}
        page_path={@page_path}
        param="member_page"
        label="Affected result pages"
      />
    </PreviewDetail.card>
    """
  end

  defp check_result_link(assigns) do
    ~H"""
    <.link patch={@result_path.(@id)}>{render_slot(@inner_block)}</.link>
    """
  end

  defp detail_filter(assigns) do
    assigns = assigns |> assign_new(:target, fn -> nil end) |> assign_new(:entity, fn -> nil end)

    ~H"""
    <form
      id={@id_prefix <> "preview-filter-detail-" <> @field}
      phx-change="filter_incident_detail"
      phx-target={@target}
      phx-auto-recover="ignore"
      class="preview-recorded-actions preview-detail-filter"
    >
      <input :if={@entity} type="hidden" name="entity" value={@entity} />
      <label for={@id_prefix <> "preview-detail-" <> @field}>{@label}</label>
      <select id={@id_prefix <> "preview-detail-" <> @field} name={@field}>
        <option :for={{value, label} <- @choices} value={value} selected={@value == value}>
          {label}
        </option>
      </select>
    </form>
    """
  end

  defp detail_pages(assigns) do
    ~H"""
    <MondekWeb.PreviewPagination.pagination
      page={@listing["page"]}
      size={@listing["page_size"]}
      total={@listing["total"]}
      label={@label}
      url={fn page -> @page_path.(@param, page) end}
    />
    """
  end

  def shared_incident_badge(assigns) do
    ~H"""
    <span class="pf-v6-c-label pf-m-blue">
      <span class="pf-v6-c-label__content">
        Shared incident · {count(@count, "member")}
      </span>
    </span>
    """
  end

  defp contribution_state_color("open"), do: "pf-m-blue"
  defp contribution_state_color("recovered"), do: "pf-m-green"
  defp contribution_state_color(_), do: nil

  def severity(assigns) do
    ~H"""
    <span
      :if={@health}
      class={["pf-v6-c-label", @health == "CRIT" && "pf-m-red", @health == "WARN" && "pf-m-orange"]}
    >
      <span class="pf-v6-c-label__content">{badge_text(@health)}</span>
    </span>
    <span :if={!@health} class="preview-caption" title="No measured severity">—</span>
    """
  end

  def incident_state(assigns) do
    ~H"""
    <span class="preview-incident-state">
      <span>{if @status == "open", do: "Open", else: "Closed"}</span>
      <span :if={@acknowledged} class="preview-acknowledgement-label">Acknowledged</span>
    </span>
    """
  end

  defp loss_reason("unavailable"), do: "Collection unavailable"
  defp loss_reason("stale"), do: "Measurement overdue"
  defp loss_reason("control_contact_overdue"), do: "Runner contact overdue"
  defp loss_reason("no_selected_runner"), do: "No selected runner"
  defp loss_reason("awaiting_new_measurement"), do: "Awaiting a new measurement"
  defp loss_reason("awaiting_coverage_measurement"), do: "Awaiting a coverage measurement"
  defp loss_reason(_), do: "Measurement unavailable"

  defp count(1, noun), do: "1 " <> noun
  defp count(n, noun), do: "#{n} #{noun}s"
end
