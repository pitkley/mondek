# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewMaintenanceSummary do
  @moduledoc "Scoped maintenance navigation shared by result and scheduled execution evidence."
  use MondekWeb, :html
  alias MondekWeb.{EvidencePresentation, PreviewDetail}

  attr :assignment, :map, required: true
  attr :stream, :map, default: nil
  attr :windows, :list, default: []
  attr :current, :string, required: true
  attr :id, :string, required: true

  attr :full_page, :boolean, default: false

  def body(assigns) do
    stream_id = assigns.stream && assigns.stream["id"]
    params = %{"return_to" => assigns.current}
    params = if stream_id, do: Map.put(params, "stream_id", stream_id), else: params

    assigns =
      assign(assigns,
        schedule_path:
          "/maintenance/new?" <>
            URI.encode_query(Map.put(params, "check_id", assigns.assignment["id"])),
        history_path:
          "/maintenance?" <>
            URI.encode_query(
              Map.merge(params, %{
                "assignment_id" => assigns.assignment["id"],
                "status" => "history"
              })
            ),
        retired:
          assigns.assignment["retired_at"] || (assigns.stream && assigns.stream["retired_at"])
      )

    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id}
      title="Notification maintenance"
    >
      <p :if={@windows == []} class="preview-empty">
        No active or upcoming maintenance windows cover this {if @stream,
          do: "result",
          else: "scheduled check"}.
      </p>
      <PreviewDetail.facts :if={@windows != []} label="Current and upcoming maintenance">
        <tr :for={window <- @windows} data-maintenance-window={window["id"]}>
          <th scope="row">{EvidencePresentation.badge_text(window["status"])}</th>
          <td>
            <.link navigate={destination("/maintenance/" <> window["id"], @current)}>{window["name"] ||
              "Maintenance window"}</.link>
            <p class="preview-caption">
              {scope(window["scope"])} · {EvidencePresentation.time(window["starts_at"])} – {EvidencePresentation.time(
                window["ends_at"]
              )}
            </p>
            <.link
              :if={window["series_id"]}
              class="maintenance-series-link"
              navigate={destination("/maintenance/series/" <> window["series_id"], @current)}
            >All dates in series</.link>
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={Enum.any?(@windows, & &1["series_id"])} class="preview-caption">
        Repeating series show their active windows, or their next upcoming window. Open the series for all dates.
      </p>
      <div class="preview-recorded-actions">
        <.link :if={!@retired} navigate={@schedule_path}>Schedule maintenance</.link>
        <.link navigate={@history_path}>View maintenance history</.link>
      </div>
      <p class="preview-caption">
        Maintenance holds notifications within its reviewed scope. Checks continue running, and recovery notifications can still be delivered.
      </p>
    </PreviewDetail.card>
    """
  end

  defp destination(path, current), do: path <> "?" <> URI.encode_query(%{"return_to" => current})
  defp scope("selection"), do: "Selected checks and targets"
  defp scope("target"), do: "Matching target results"
  defp scope(_), do: "All results of this scheduled check"
end
