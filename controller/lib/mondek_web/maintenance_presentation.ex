# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenancePresentation do
  @moduledoc "Maintenance display formatting and local links, shared by the owner and its templates."
  alias Mondek.MaintenanceSelection

  def related_result_path(current, id) do
    identity = MondekWeb.InvestigationTrail.identity({"result", id})

    if identity,
      do:
        MondekWeb.InvestigationTrail.path(current, [identity], %{
          "surface" => nil,
          "page_entity" => nil
        }),
      else: current
  end

  def editable?(nil), do: true
  def editable?(window), do: window["status"] in ["active", "upcoming"]

  @scope_fields ~w(scope assignment_id source_id environment target_kind target_key)
  def selections(%{"scope" => "selection", "selections" => selections}) when is_list(selections),
    do: selections

  def selections(_), do: []
  def selected_pages(rows), do: max(1, ceil(length(rows) / 25))
  def selector_identity(row), do: MaintenanceSelection.identity(row)

  def encoded_draft(proposal, origin),
    do: proposal |> Map.put("_origin", origin) |> Jason.encode!()

  def same_scope?(left, right),
    do:
      Map.take(left, @scope_fields) == Map.take(right, @scope_fields) &&
        MaintenanceSelection.normalize(selections(left)) ==
          MaintenanceSelection.normalize(selections(right))

  def scope_key(scope) do
    @scope_fields
    |> Enum.map(&Map.get(scope, &1))
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  def cancel_label(%{"status" => "active"}), do: "End maintenance now"
  def cancel_label(_), do: "Cancel window"
  def status_label(%{"status" => "cancelled"} = window), do: cancellation_label(window)

  def status_label(%{"status" => status}), do: status_label(status)
  def status_label("upcoming"), do: "Upcoming"
  def status_label("active"), do: "Active"
  def status_label("ended"), do: "Ended"
  def status_label("cancelled"), do: "Cancelled"
  def status_label("between"), do: "Scheduled"
  def status_label("completed"), do: "Completed"
  def status_label(_), do: "Unknown"

  def cancellation_label(window) do
    case {parse_time(window["cancelled_at"]), parse_time(window["starts_at"])} do
      {%DateTime{} = ended, %DateTime{} = started} ->
        if DateTime.compare(ended, started) == :lt, do: "Cancelled", else: "Ended early"

      _ ->
        "Cancelled"
    end
  end

  def event_label(%{"kind" => "cancelled", "snapshot" => snapshot}) when is_map(snapshot) do
    if cancellation_label(snapshot) == "Ended early",
      do: "Maintenance ended early",
      else: "Window cancelled before start"
  end

  def event_label(%{"kind" => kind}), do: event_label(kind)
  def event_label("created"), do: "Window created"
  def event_label("updated"), do: "Window updated"
  def event_label("cancelled"), do: "Window cancelled"
  def event_label("expired"), do: "Window expired"
  def event_label(_), do: "Window updated"

  def scope_label(%{"scope" => "target"} = proposal),
    do:
      "Target #{proposal["target_kind"]}: #{proposal["target_key"]} · #{proposal["environment"] || "No declared environment"} · source #{proposal["source_id"] || "built-in checks"}"

  def scope_label(%{"scope" => "selection"} = proposal) do
    count = proposal["selection_count"] || length(selections(proposal))

    prefix =
      if repeating?(proposal) || proposal["kind"] == "series",
        do: "Each window covers",
        else: "One window covering"

    "#{prefix} #{count} #{if count == 1, do: "selected check or target", else: "selected checks or targets"}"
  end

  def scope_label(proposal),
    do:
      "#{proposal["check_label"] || "Selected scheduled check"} · all its results#{if proposal["runner_label"], do: " · " <> proposal["runner_label"], else: ""}"

  def scope_label(proposal, options) do
    case {proposal["scope"], Enum.find(options, &same_scope?(&1, proposal))} do
      {"check", %{"label" => label}} -> label
      _ -> scope_label(proposal)
    end
  end

  def target_label(target), do: target["label"] || "#{target["kind"]}: #{target["key"]}"
  def count_label(count, label), do: "#{count} #{label}#{if count == 1, do: "", else: "s"}"
  def repeating?(proposal), do: is_map(proposal) && is_map(proposal["recurrence"])

  def repeat_label(rule) do
    interval = rule["interval"] || 1
    cadence = if interval == 1, do: "Every week", else: "Every #{interval} weeks"

    case rule["end_mode"] do
      "date" -> cadence <> " through " <> (rule["until_date"] || "—")
      "open" -> cadence <> " until canceled"
      _ -> cadence <> " for " <> count_label(rule["count"] || 0, "window")
    end
  end

  def series_event_label("created"), do: "Series created"
  def series_event_label("upcoming_cancelled"), do: "Upcoming windows cancelled"
  def series_event_label("updated"), do: "Individual window changed"
  def series_event_label("cancelled"), do: "Individual window cancelled"
  def series_event_label("occurrence_updated"), do: "Individual window changed"
  def series_event_label("occurrence_cancelled"), do: "Individual window cancelled"
  def series_event_label(_), do: "Series updated"

  def series_remaining?(series),
    do: (series["remaining_count"] || 0) > 0 or series["generation_enabled"] == true

  def series_membership_copy("check"),
    do:
      "Future results from this same scheduled check instance join during each window. Replacement check instances are independent."

  def series_membership_copy("target"),
    do:
      "Future results matching this exact source, monitored environment and target join during each window, across observers."

  def series_membership_copy(_),
    do:
      "Each selected check stays with its scheduled instance and includes its future results. Each selected target follows exact matches across observers."

  def duration_label(row) do
    with %DateTime{} = first <- parse_time(row["starts_at"]),
         %DateTime{} = last <- parse_time(row["ends_at"]),
         elapsed when elapsed > 0 and elapsed < 1_000_000 <-
           DateTime.diff(last, first, :microsecond) do
      "Less than 1 second"
    else
      _ -> duration(row["starts_at"], row["ends_at"])
    end
  end

  def series_path(id), do: "/maintenance/series/" <> id

  def series_page_path(path, key, page) do
    uri = URI.parse(path)
    query = URI.decode_query(uri.query || "") |> Map.put(key, page) |> URI.encode_query()
    uri.path <> "?" <> query
  end

  def window_path(id, return_to \\ nil),
    do:
      "/maintenance/" <>
        id <>
        "/full" <>
        if(return_to, do: "?" <> URI.encode_query(%{"return_to" => return_to}), else: "")

  def preview_entity_path(kind, id, surface, filters) do
    prefix = if kind == :series, do: "/maintenance/series/", else: "/maintenance/"
    query = filters |> Map.reject(fn {_, value} -> is_nil(value) end) |> URI.encode_query()

    prefix <>
      id <>
      if(surface == :page, do: "/full", else: "") <>
      if(query == "", do: "", else: "?" <> query)
  end

  def pages(result), do: max(1, ceil((result["total"] || 0) / max(1, result["page_size"] || 25)))

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp parse_time(%DateTime{} = value), do: value
  defp parse_time(_), do: nil
  def form_time(value) when is_binary(value) and byte_size(value) == 16, do: value <> ":00"
  def form_time(value) when is_binary(value), do: String.slice(value, 0, 19)
  def form_time(_), do: ""

  def utc_time(value) do
    case parse_time(value) do
      nil -> "—"
      time -> Calendar.strftime(time, "%d %b %Y, %H:%M:%S UTC")
    end
  end

  def local_time(value, zone) do
    with time when not is_nil(time) <- parse_time(value),
         {:ok, local} <-
           DateTime.shift_zone(
             time,
             if(zone in [nil, "UTC"], do: "Etc/UTC", else: zone),
             Tz.TimeZoneDatabase
           ) do
      Calendar.strftime(local, "%a %d %b %Y, %H:%M:%S %Z (%z)")
    else
      _ -> "—"
    end
  end

  def duration(first, last) do
    with %DateTime{} = first <- parse_time(first), %DateTime{} = last <- parse_time(last) do
      seconds = DateTime.diff(last, first)

      [
        {div(seconds, 86_400), "day"},
        {div(rem(seconds, 86_400), 3_600), "hour"},
        {div(rem(seconds, 3_600), 60), "minute"},
        {rem(seconds, 60), "second"}
      ]
      |> Enum.reject(fn {count, _} -> count == 0 end)
      |> Enum.map_join(", ", fn {count, unit} ->
        "#{count} #{unit}#{if count == 1, do: "", else: "s"}"
      end)
    else
      _ -> "—"
    end
  end
end
