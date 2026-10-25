# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckDiagnostics do
  @moduledoc "A result-scoped investigation of collection and its owning runner."
  use Phoenix.Component
  alias MondekWeb.AgentPrompts

  def path(%{"stream_id" => id}) when is_binary(id), do: "/checks/#{id}/diagnostics"
  def path(assignment), do: "/resources/#{assignment["id"]}/diagnostics"

  attr :inspection, :map, default: nil
  attr :runner, :map, default: nil
  attr :now, :any, required: true
  attr :return_to, :string, default: nil
  attr :controller_url, :string, required: true

  def page(assigns) do
    inspection = assigns.inspection || %{}
    assignment = inspection["assignment"] || %{}
    result = inspection["stream"] || assignment
    runner = assigns.runner || %{}
    status = runner_status(runner["status"])
    current = result["current"] || %{}

    base =
      if inspection["stream"],
        do: "/checks/#{result["id"]}",
        else: "/resources/#{assignment["id"]}"

    result_path =
      if assigns.return_to,
        do: base <> "?" <> URI.encode_query(%{"return_to" => assigns.return_to}),
        else: base

    monitoring_return = MondekWeb.MonitoringIncidentsLive.return_path(assigns.return_to)

    {kind, title, explanation, next_step} = finding(result, assignment, runner, assigns.now)

    investigation_path = with_return(base <> "/diagnostics", assigns.return_to)

    coverage_return = MondekWeb.CoverageNavigation.return_path(assigns.return_to)

    incident_return =
      if String.starts_with?(URI.parse(assigns.return_to || "").path || "", "/incidents/"),
        do: assigns.return_to

    action = next_action(kind, assignment, runner, result_path, investigation_path)

    assigns =
      assign(assigns,
        exists: assignment != %{},
        assignment: assignment,
        result: result,
        runner: runner,
        status: status,
        scheduler: status["scheduler"] || %{},
        current: current,
        back: monitoring_return || incident_return || coverage_return || result_path,
        back_label:
          cond do
            monitoring_return -> "← Back to monitoring incident"
            incident_return -> "← Back to incident"
            coverage_return -> "← Back to coverage"
            inspection["stream"] -> "← Back to result"
            true -> "← Back to check"
          end,
        contextual_return: monitoring_return || incident_return || coverage_return,
        action: action,
        evidence_order:
          if(kind in [:contact, :configuration, :waiting, :unassigned],
            do: [:runner, :execution],
            else: [:execution, :runner]
          ),
        monitoring_return: monitoring_return,
        result_path: result_path,
        finding: title,
        explanation: explanation,
        next_step: next_step,
        recent: recent_contact?(runner, assigns.now),
        incidents:
          (inspection["incidents"] || [])
          |> Enum.filter(&(&1["status"] == "open"))
          |> Enum.uniq_by(&(&1["condition_incident_id"] || &1["id"])),
        investigation_path: investigation_path,
        context: %{
          "controller_url" => assigns.controller_url,
          "page_path" => base <> "/diagnostics",
          "check_id" => assignment["id"],
          "check_key" => assignment["source_key"],
          "check_name" => result["label"],
          "source_id" => assignment["source_id"],
          "result_key" => result["result_key"],
          "runner_id" => runner["id"],
          "runner_name" => runner["label"],
          "target_id" => get_in(result, ["target", "key"]),
          "target_kind" => get_in(result, ["target", "kind"]),
          "target_name" => get_in(result, ["target", "label"]),
          "monitored_environment" => result["environment"],
          "freshness" => current["knowledge"],
          "health" => current["reported_health"],
          "configuration_version" => assignment["desired_generation"]
        }
      )

    ~H"""
    <div :if={!@exists} class="notice warn">This check is not configured.</div>
    <div :if={@exists} id="measurement-investigation">
      <.link id="investigation-back" navigate={@back} class="back">{@back_label}</.link>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Measurement investigation</div>
          <h1>{@result["label"] || @assignment["kind"]}</h1>
          <dl class="result-context">
            <div>
              <dt>Target</dt><dd>{target_name(@result)}</dd>
            </div>
            <div>
              <dt>Monitored environment</dt><dd>
                {@result["environment_label"] || @result["environment"] || "Not declared"}
              </dd>
            </div>
            <div>
              <dt>Observing runner</dt><dd>{@runner["label"] || @runner["id"] || "Not assigned"}</dd>
            </div>
          </dl>
        </div>
        <.link :if={@contextual_return} navigate={@result_path} class="text-link">View result</.link>
      </div>
      <section
        id="investigation-finding"
        class="panel investigation-finding"
        aria-labelledby="finding-heading"
      >
        <div class="panel-body">
          <h2 id="finding-heading">{@finding}</h2>
          <p>{@explanation}</p>
          <p class="investigation-next">{@next_step}</p>
          <div class="space-top" id="investigation-next-action">
            <.link :if={@action.anchor} href={@action.path} class="button primary">{@action.label}</.link>
            <.link :if={!@action.anchor} navigate={@action.path} class="button primary">{@action.label}</.link>
          </div>
        </div>
      </section>
      <div class="details-grid result-layout">
        <div class="stack">
          <div :for={panel <- @evidence_order} class="investigation-section">
            <.execution_evidence :if={panel == :execution} current={@current} />
            <.runner_evidence
              :if={panel == :runner}
              runner={@runner}
              recent={@recent}
              assignment={@assignment}
              scheduler={@scheduler}
              status={@status}
              investigation_path={@investigation_path}
            />
          </div>
        </div>
        <div class="stack">
          <section id="notification-boundary" class="panel" aria-labelledby="notification-heading">
            <div class="panel-heading">
              <h2 id="notification-heading">Notification delivery</h2>
            </div>
            <div class="panel-body">
              <p>
                Delivery is separate from measurement collection. Acknowledgement and maintenance hold notifications; checks keep running.
              </p>
              <p class="footnote space-top">
                Prolonged unavailable or overdue measurements open a separate monitoring-loss incident after a grace period. They do not by themselves open a target-health incident.
              </p>
              <.link
                navigate={"/monitoring-incidents" <> if(@runner["id"], do: "?" <> URI.encode_query(%{"runner_id" => @runner["id"]}), else: "")}
                class="text-link space-top"
              >Inspect monitoring-loss notifications</.link>
              <p :if={@incidents == []} class="space-top">
                No open target-health incident is recorded for this result. Return to the result for its health history.
              </p>
              <p :if={@incidents != []} class="space-top">
                Review an open incident's notification timeline for holds, attempts and delivery errors:
              </p>
              <ul :if={@incidents != []} class="investigation-incidents">
                <li :for={incident <- @incidents}>
                  <.link navigate={notification_path(incident, @investigation_path)} class="text-link">{incident[
                    "label"
                  ] || @result["label"] || "Open incident"} · {incident["health"]}</.link>
                </li>
              </ul>
            </div>
          </section>
          <AgentPrompts.library
            id="collection-agent-prompts"
            kinds={[:collection]}
            context={@context}
          />
        </div>
      </div>
    </div>
    """
  end

  defp execution_evidence(assigns) do
    ~H"""
    <section id="latest-execution" tabindex="-1" class="panel" aria-labelledby="execution-heading">
      <div class="panel-heading">
        <h2 id="execution-heading">Latest execution evidence</h2>
      </div>
      <div class="panel-body">
        <p :if={!@current["observation_id"]}>
          No execution evidence has been received for this result yet.
        </p>
        <p :if={@current["execution_summary"]} class="measurement-summary">
          {@current["execution_summary"]}
        </p>
        <p
          :if={@current["diagnostic"] not in [nil, "", @current["execution_summary"]]}
          class="collection-diagnostic"
        >
          {@current["diagnostic"]}
        </p>
        <div :if={@current["execution_details"] not in [nil, ""]}>
          <h3>Collection details</h3>
          <pre class="diagnostic-text investigation-evidence">{@current["execution_details"]}</pre>
        </div>
        <dl class="investigation-facts space-top">
          <div>
            <dt>Evaluated</dt><dd><.recorded_time value={@current["evaluated_at"]} /></dd>
          </div>
          <div>
            <dt>Received by controller</dt><dd>
              <.recorded_time value={@current["received_at"]} />
            </dd>
          </div>
          <div>
            <dt>Reported source time</dt><dd>
              <.recorded_time value={@current["reported_source_at"]} />
            </dd>
          </div>
        </dl>
        <p class="footnote space-top">
          These are the latest received execution details. Retained health on the result page comes from its last confirmed measurement, which may be older.
        </p>
      </div>
    </section>
    """
  end

  defp runner_evidence(assigns) do
    ~H"""
    <section id="runner-signals" tabindex="-1" class="panel" aria-labelledby="signals-heading">
      <div class="panel-heading">
        <h2 id="signals-heading">Runner contact and execution</h2>
      </div>
      <div class="panel-body">
        <p :if={@runner == %{}}>
          No owning runner is recorded. Attach the intended runner and check its source declarations in Coverage.
        </p>
        <div :if={@runner != %{}}>
          <p class="footnote">{@runner["label"] || @runner["id"]}</p>
          <p>
            <strong>{if @recent,
              do: "Recent controller contact",
              else: "No recent controller contact"}</strong>
          </p>
          <p class="footnote">
            Last contact:
            <.recorded_time value={@runner["last_seen_at"]} />. Contact confirms communication, not a successful measurement.
          </p>
          <h3 class="space-top">This check's configuration</h3>
          <dl class="investigation-facts">
            <div>
              <dt>Desired version</dt><dd>{value(@assignment["desired_generation"])}</dd>
            </div>
            <div>
              <dt>Prepared / active</dt><dd>
                {value(@assignment["prepared_generation"])} / {value(@assignment["active_generation"])}
              </dd>
            </div>
          </dl>
          <h3 class="space-top">Last reported runner status</h3>
          <p class="footnote">
            These values cover all checks on this runner and may predate its last contact. They do not advance while disconnected and cannot identify which check is blocked.
          </p>
          <dl class="investigation-facts">
            <div>
              <dt>Running executions</dt><dd>{value(@scheduler["running_checks"])}</dd>
            </div>
            <div>
              <dt>Due, waiting for a slot</dt><dd>{value(@scheduler["due_waiting_checks"])}</dd>
            </div>
            <div>
              <dt>Reports awaiting upload</dt><dd>{value(@status["queue_count"])}</dd>
            </div>
            <div>
              <dt>Reports dropped since journal creation</dt><dd>
                {value(@status["dropped"])}
              </dd>
            </div>
          </dl>
          <p :if={positive?(@scheduler["due_waiting_checks"])} class="notice warn space-top">
            The runner reported executions waiting for capacity. Inspect slow or stuck checks and the concurrency limit before changing this check's schedule.
          </p>
          <p :if={positive?(@status["queue_count"])} class="notice warn space-top">
            The runner reported buffered evidence. If this persists, inspect controller reachability and upload responses from the runner. A brief queue can be normal.
          </p>
          <p :if={positive?(@status["dropped"])} class="notice warn space-top">
            The journal records past report loss. Inspect spool limits and the loss timeline; this cumulative counter alone does not show a current outage.
          </p>
          <details :if={@status["diagnostic"]} class="diagnostic-details space-top">
            <summary>Last recorded runner diagnostic</summary>
            <p class="footnote">
              This message can survive recovery and may describe an earlier problem.
            </p>
            <pre class="diagnostic-text investigation-evidence">{@status["diagnostic"]}</pre>
          </details>
          <.link
            navigate={MondekWeb.RunnersLive.detail_path(@runner["id"], @investigation_path)}
            class="text-link space-top"
          >Full status for this runner</.link>
        </div>
      </div>
    </section>
    """
  end

  defp next_action(:contact, _assignment, runner, _result, investigation),
    do: %{
      anchor: false,
      path: MondekWeb.RunnersLive.detail_path(runner["id"], investigation),
      label: "Inspect runner connection"
    }

  defp next_action(:configuration, assignment, _runner, _result, investigation),
    do: %{
      anchor: false,
      path: with_return("/configuration/" <> assignment["id"], investigation),
      label: "Review pending configuration"
    }

  defp next_action(:collection, _assignment, _runner, _result, _investigation),
    do: %{anchor: true, path: "#latest-execution", label: "Read collection error"}

  defp next_action(:stale, _assignment, _runner, _result, _investigation),
    do: %{anchor: true, path: "#latest-execution", label: "Compare measurement times"}

  defp next_action(:waiting, _assignment, _runner, _result, _investigation),
    do: %{anchor: true, path: "#runner-signals", label: "Inspect execution progress"}

  defp next_action(:unassigned, _assignment, _runner, _result, _investigation),
    do: %{anchor: false, path: "/guide", label: "Set up a runner"}

  defp next_action(_kind, _assignment, _runner, result, _investigation),
    do: %{anchor: false, path: result, label: "View result and incident history"}

  defp finding(result, assignment, runner, now) do
    knowledge = get_in(result, ["current", "knowledge"])

    cond do
      result["retired_at"] || assignment["retired_at"] ->
        {:retired, "Result retired",
         "This result is historical and no longer expected to produce measurements. Retirement does not mean recovery.",
         "Review the source removal or replacement and the retained incident history."}

      runner == %{} ->
        {:unassigned, "No runner assigned", "No runner owns this scheduled check yet.",
         "Attach the intended runner, then inspect its declarations and placement decisions in Coverage."}

      !recent_contact?(runner, now) ->
        {:contact, "Runner contact overdue",
         "The controller has not heard from this runner within the configured #{Mondek.MonitoringLoss.contact_seconds()}-second contact window. It may still be executing checks; the controller cannot confirm that.",
         "Inspect the runner process and its controller connection from the runner's host. Check startup or HTTP errors before interpreting the older evidence below."}

      assignment["active_generation"] != assignment["desired_generation"] ->
        {:configuration, "Waiting for configuration",
         "The runner has not reported the desired configuration as active for this check.",
         "Inspect preparation errors and the installed consumer version on this runner. A saved configuration is not proof it has run."}

      knowledge == "unavailable" ->
        {:collection, "Collection unavailable",
         "The latest execution did not confirm target health. The runner is in contact; check and datasource evidence is the starting point.",
         "Read the execution details below. Inspect this check's code and any named datasource from the runner's environment: timeouts, configuration, network access and permissions."}

      knowledge == "stale" ->
        {:stale, "Measurement overdue",
         "The source evidence is too old to establish current health, even though the runner has contacted the controller.",
         "Compare source, evaluation and receipt times. Check for cached or delayed datasource evidence, then inspect scheduling and buffered reports below."}

      knowledge == "fresh" ->
        {:current, "Measurement current",
         "This result has a current measurement. A Warning or Critical verdict can still describe a problem with the monitored target.",
         "Return to the result to inspect target health or its incident. Use the evidence below to investigate intermittent collection problems."}

      true ->
        {:waiting, "Waiting for measurement",
         "No current measurement is available for this runner session and configuration.",
         "Check the first due execution and preparation progress on the owning runner. Contact alone does not prove the check has completed."}
    end
  end

  defp recent_contact?(runner, now) do
    case DateTime.from_iso8601(runner["last_seen_at"] || "") do
      {:ok, at, _} ->
        DateTime.compare(at, DateTime.add(now, -Mondek.MonitoringLoss.contact_seconds())) ==
          :gt

      _ ->
        false
    end
  end

  defp recorded_time(assigns) do
    text =
      case DateTime.from_iso8601(assigns.value || "") do
        {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
        _ -> "Not recorded"
      end

    assigns = assign(assigns, :text, text)

    ~H"""
    <time :if={@value} datetime={@value} title={@value}>{@text}</time><span :if={!@value}>{@text}</span>
    """
  end

  defp value(nil), do: "Not reported"
  defp value(value), do: value
  defp positive?(value), do: is_number(value) && value > 0

  defp target_name(result),
    do: get_in(result, ["target", "label"]) || get_in(result, ["target", "key"]) || "Not declared"

  defp with_return(path, nil), do: path

  defp with_return(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp notification_path(incident, return_to) do
    "/incidents/" <>
      (incident["condition_incident_id"] || incident["id"]) <>
      "?" <>
      URI.encode_query(%{"return_to" => return_to, "notification_status" => "all"}) <>
      "#incident-occurrences"
  end

  # Runner telemetry is bounded JSON, not a typed observation contract. Ignore
  # unsupported signal shapes while retaining readable structured diagnostics.
  defp runner_status(raw) do
    status = if is_map(raw), do: raw, else: %{}
    scheduler = if is_map(status["scheduler"]), do: status["scheduler"], else: %{}

    Map.new(~w(queue_count dropped), &{&1, counter(status[&1])})
    |> Map.put(
      "scheduler",
      Map.new(~w(running_checks due_waiting_checks), &{&1, counter(scheduler[&1])})
    )
    |> Map.put("diagnostic", diagnostic(status["diagnostic"]))
  end

  defp counter(value) when is_number(value) and value >= 0, do: value
  defp counter(_), do: nil
  defp diagnostic(value) when value in [nil, ""], do: nil
  defp diagnostic(value) when is_binary(value), do: value
  defp diagnostic(value), do: Jason.encode!(value, pretty: true)
end
