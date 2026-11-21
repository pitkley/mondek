# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MonitoringUI do
  use MondekWeb, :html
  import MondekWeb.EvidencePresentation

  defdelegate return_label(path, fallback), to: MondekWeb.InvestigationNavigation

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

  def confirmed_measurement?(assignment),
    do: not is_nil(get_in(assignment, ["current", "confirmed_observation_id"]))

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

  def error_message(:delivery_disabled),
    do: "Notification delivery is off for this installation."

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
