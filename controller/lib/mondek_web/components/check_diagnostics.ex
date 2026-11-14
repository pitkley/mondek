# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckDiagnostics do
  def finding(result, assignment, runner, now) do
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
end
