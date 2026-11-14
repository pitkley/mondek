# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewIncidentControls do
  @moduledoc "Incident controls shared by preview hosts. Returns assign changes and whether evidence needs refreshing."
  alias Mondek.{Monitoring, MonitoringLoss}
  alias MondekWeb.NotificationRetry

  def save(kind, id, review, params) do
    draft = draft(params)
    note = Map.get(params, "note", "")

    note =
      if is_binary(note) && String.valid?(note) && String.trim(note) == "",
        do: "No note provided.",
        else: note

    result =
      with {:ok, options} <- options(review, draft),
           do: apply_acknowledgement(kind, id, options, note)

    {changes, refresh?} = acknowledgement_result(result, "Acknowledgement saved.")
    {Map.put_new(changes, :control_draft, draft), refresh?}
  end

  def finish(kind, id, review, incident) do
    if Monitoring.acknowledgement_active?(incident) do
      apply_acknowledgement(kind, id, Map.put(review, "mode", "end"), "Ended by operator.")
      |> acknowledgement_result("Acknowledgement ended.")
    else
      {%{}, false}
    end
  end

  def retry(detail, previous_drafts, id, reason) do
    occurrences = detail["occurrences"] || []
    drafts = NotificationRetry.keep_draft(previous_drafts, occurrences, id, reason)

    if Enum.any?(occurrences, &(&1["id"] == id && &1["can_retry"])) do
      case Monitoring.retry_notification(id, reason) do
        {:ok, _} ->
          {%{
             retry_drafts: Map.delete(drafts, id),
             delivery_feedback: {:ok, NotificationRetry.success_message()}
           }, true}

        {:error, error} ->
          {%{
             retry_drafts: drafts,
             delivery_feedback: {:error, NotificationRetry.error_message(error)}
           }, true}
      end
    else
      {%{delivery_feedback: {:error, "This notification is no longer eligible for a retry."}},
       false}
    end
  end

  defp apply_acknowledgement("health", id, options, note),
    do: Monitoring.acknowledge(id, options, note)

  defp apply_acknowledgement("loss", id, options, note),
    do: MonitoringLoss.acknowledge(id, options, note)

  defp acknowledgement_result({:ok, _}, message),
    do:
      {%{
         control_review: nil,
         control_draft: %{},
         control_replacing: false,
         control_feedback: {:ok, message}
       }, true}

  defp acknowledgement_result({:error, :stale}, _),
    do:
      {%{control_feedback: {:error, "The incident changed. Review it again before saving."}},
       true}

  defp acknowledgement_result({:error, reason}, _),
    do: {%{control_feedback: {:error, NotificationRetry.error_message(reason)}}, false}

  def revision(incident) do
    %{
      "revision" => incident["acknowledgement_revision"],
      "attention_revision" => incident["attention_revision"]
    }
  end

  def draft(params) do
    params
    |> Map.take(~w(mode amount unit expires_at note))
    |> Map.filter(fn {_, value} ->
      is_binary(value) and byte_size(value) <= 2_000 and String.valid?(value)
    end)
  end

  defp options(review, %{"mode" => mode})
       when mode == "until_incident_ends",
       do: {:ok, Map.put(review, "mode", mode)}

  defp options(review, %{"mode" => "duration"} = draft) do
    units = %{"minutes" => 60, "hours" => 3600, "days" => 86_400}

    with {amount, ""} when amount > 0 <- Integer.parse(draft["amount"] || ""),
         seconds_per_unit when is_integer(seconds_per_unit) <- units[draft["unit"]] do
      {:ok, Map.merge(review, %{"mode" => "duration", "seconds" => amount * seconds_per_unit})}
    else
      _ -> {:error, {:invalid, "Enter a positive whole number and choose a unit."}}
    end
  end

  defp options(review, %{"mode" => "until"} = draft) do
    value = draft["expires_at"] || ""
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, Map.merge(review, %{"mode" => "until", "expires_at" => DateTime.to_iso8601(utc)})}
    else
      _ -> {:error, {:invalid, "Enter a future date and time in UTC."}}
    end
  end

  defp options(_, _),
    do: {:error, {:invalid, "Choose when the acknowledgement should end."}}
end
