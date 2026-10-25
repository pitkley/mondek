# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.EvidencePresentation do
  @moduledoc "Shared evidence labels and timing for investigation and delivery."
  use MondekWeb, :html

  def plural(1, noun), do: noun
  def plural(_, noun), do: noun <> "s"

  def inspection_limit(assigns) do
    ~H"""
    <div :if={@counts} class="panel-footer">
      Showing {@counts["returned"]} of {@counts["total"]} retained {@label}.
      <span :if={@counts["omitted"] > 0}>
        {@counts["omitted"]} are outside this bounded view.
      </span>
    </div>
    """
  end

  attr :value, :any, required: true

  def badge(assigns) do
    value = to_string(assigns.value || "pending")
    assigns = assign(assigns, class: String.downcase(value), text: badge_text(value))

    ~H"""
    <span class={"badge " <> @class}><span class="dot"></span>{@text}</span>
    """
  end

  def target_label(target) when is_map(target),
    do: target["label"] || target["key"] || "Declared target"

  def target_label(target) when is_binary(target), do: target
  def target_label(_), do: "Target not recorded"

  def pending_occurrences(snapshot),
    do:
      Enum.filter(
        snapshot["occurrences"],
        &(&1["status"] in [
            "pending",
            "delivering",
            "exhausted",
            "retrying",
            "deferred",
            "available",
            "executing",
            "scheduled",
            "gated"
          ])
      )

  def backlog_total(snapshot),
    do:
      get_in(snapshot, ["notification_backlog", "total"]) || length(pending_occurrences(snapshot))

  def find(items, id), do: Enum.find(items, %{}, &(&1["id"] == id))

  def label(%{"id" => "consumer", "source_id" => nil}), do: "Queue backlog"

  def label(assignment),
    do:
      assignment["label"] ||
        %{
          "filesystem" => "Filesystem capacity",
          "http" => "HTTP readiness",
          "consumer" => "Queue backlog"
        }[assignment["id"]] || "Unknown check"

  def badge_text("OK"), do: "Healthy"
  def badge_text("WARN"), do: "Warning"
  def badge_text("CRIT"), do: "Critical"
  def badge_text("UNKNOWN"), do: "Unknown"
  def badge_text("not_measured"), do: "Not measured"
  def badge_text("fresh"), do: "Fresh measurement"
  def badge_text("pending"), do: "Pending"
  def badge_text("awaiting"), do: "Pending"
  def badge_text("current"), do: "Recorded"
  def badge_text("delivered"), do: "Receiver accepted"
  def badge_text("exhausted"), do: "Retries exhausted"
  def badge_text("failed_or_ambiguous"), do: "Failed / uncertain"
  def badge_text(value), do: humanize(value)
  def humanize(nil), do: "—"

  def humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def acknowledgement_time(value) do
    case parse_time(value) do
      nil -> "—"
      date -> Calendar.strftime(date, "%d %b %Y, %H:%M:%S UTC")
    end
  end

  def parse_time(nil), do: nil
  def parse_time(%DateTime{} = value), do: value

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _} -> parsed
      _ -> nil
    end
  end

  def parse_time(_), do: nil

  def age(value, now) do
    case parse_time(value) do
      nil ->
        "—"

      time ->
        seconds = max(0, DateTime.diff(now, time, :second))

        cond do
          seconds < 60 -> "#{seconds}s ago"
          seconds < 3_600 -> "#{div(seconds, 60)}m ago"
          seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
          true -> "#{div(seconds, 86_400)}d ago"
        end
    end
  end

  def time(value) do
    case parse_time(value) do
      nil -> "—"
      parsed -> Calendar.strftime(parsed, "%d %b, %H:%M:%S UTC")
    end
  end

  def active_gate?(value, now),
    do: parse_time(value) != nil and DateTime.compare(parse_time(value), now) == :gt
end
