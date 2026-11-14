# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationEntity do
  @moduledoc "Bounded evidence and retained control state for one investigation entity."
  alias Mondek.{Maintenance, Monitoring, MonitoringLoss}
  alias MondekWeb.{PreviewIncidentControls, PreviewResult}

  def new(identity),
    do: %{
      identity: identity,
      data: nil,
      review: nil,
      draft: %{},
      replacing: false,
      feedback: nil,
      delivery_feedback: nil,
      retry_drafts: %{}
    }

  def refresh(%{identity: {"result", id}} = state, now, _filters),
    do: %{state | data: PreviewResult.load(id, now)}

  def refresh(%{identity: {kind, id}} = state, now, filters) when kind in ~w(health loss) do
    detail =
      if kind == "health" do
        Monitoring.incident_detail(id, now, %{
          "page" => filters["member_page"],
          "state" => filters["contributors"] || "default",
          "contradiction_page" => filters["healthy_page"],
          "notification_status" => filters["notification_status"] || "all",
          "notification_page" => filters["notification_page"]
        })
      else
        MonitoringLoss.detail(id, now, %{"members_page" => filters["member_page"]})
      end

    incident = if kind == "health", do: detail && detail["incident"], else: detail

    windows =
      if kind == "health" && incident && incident["status"] == "open" do
        cond do
          id = incident["stream_id"] -> Maintenance.for_stream(id, now)
          id = incident["assignment_id"] -> Maintenance.for_assignment(id, now)
          true -> []
        end
        |> Enum.filter(&(&1["status"] == "active"))
      else
        []
      end

    review =
      state.review ||
        if incident && incident["status"] == "open",
          do: PreviewIncidentControls.revision(incident)

    %{
      state
      | data: %{detail: detail, incident: incident, maintenance_windows: windows},
        review: review
    }
  end

  def title(%{identity: {"result", _}, data: %{selected: result}}),
    do: result["label"] || get_in(result, ["check", "label"]) || "Check result"

  def title(%{identity: {"loss", _}, data: %{incident: %{"scope_kind" => "coverage"}}}),
    do: "No runner selected"

  def title(%{data: %{incident: incident, detail: detail}}) when is_map(incident),
    do: incident["label"] || get_in(detail, ["assignment", "label"]) || "Incident"

  def title(_), do: "Evidence unavailable"

  def kind(%{identity: {"result", _}}), do: "Check result"
  def kind(%{identity: {"loss", _}}), do: "Monitoring loss"
  def kind(%{data: %{detail: %{"contributions" => _}}}), do: "Shared incident"
  def kind(_), do: "Health incident"
end
