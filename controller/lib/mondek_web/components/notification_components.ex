# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationComponents do
  @moduledoc "Shared delivery evidence for notification and incident pages; no LiveView state."
  import MondekWeb.EvidencePresentation

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

  def notification_check_label(%{"monitoring_incident_id" => id} = occurrence)
      when is_binary(id),
      do: occurrence["check_label"] || "Monitoring loss"

  def notification_check_label(%{"condition_incident_id" => id} = occurrence) when is_binary(id),
    do:
      occurrence["check_label"] || get_in(occurrence, ["payload", "condition", "label"]) ||
        "Shared condition"

  def notification_check_label(occurrence) do
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

  def requested_scope(occurrence) do
    case get_in(occurrence, ["payload", "requested_fact"]) do
      %{"kind" => "severity", "key" => health} -> badge_text(health) <> " severity"
      %{"kind" => "impact", "label" => label} -> label
      _ -> "Incident ended · " <> humanize(get_in(occurrence, ["payload", "closure_reason"]))
    end
  end

  def notification_gate_summary(occurrence) do
    gates = Enum.map_join(occurrence["gates"] || [], " and ", &humanize/1)

    if occurrence["gated_indefinitely"],
      do:
        "Waiting for #{gates}. Acknowledgement has no scheduled expiry and ends with the incident, a higher severity above its limit, a new impact, or an operator ending it.",
      else: "Waiting for #{gates} until #{acknowledgement_time(occurrence["gated_until"])}."
  end
end
