# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationEntity do
  @moduledoc "Bounded evidence and retained control state for one investigation entity."
  alias Mondek.{
    CorrelationCandidates,
    Investigation,
    Maintenance,
    Monitoring,
    MonitoringLoss,
    RunnerFleet
  }

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
      retry_drafts: %{},
      view: %{}
    }

  def refresh(%{identity: {"coverage", id}} = state, now, filters) do
    requested = if filters["coverage_entity"] in [nil, id], do: filters["coverage_observer_page"]
    page = requested || state.view["coverage_observer_page"]
    data = MondekWeb.CoverageEvidence.load("coverage", id, now, page)

    view =
      if data,
        do: %{
          "coverage_entity" => id,
          "coverage_observer_page" => to_string(data.observers["page"])
        },
        else: state.view

    %{state | data: data, view: view}
  end

  def refresh(%{identity: {"diagnostic", id}} = state, now, _filters),
    do: %{state | data: MondekWeb.CoverageEvidence.diagnostic(id, now)}

  def refresh(%{identity: {"execution", id}} = state, now, _filters) do
    inspection = Mondek.Inspection.execution_detail(id, now)

    data =
      if inspection,
        do: %{
          inspection: inspection,
          runner: Mondek.RunnerFleet.detail(inspection["assignment"]["runner_id"], now),
          windows: Maintenance.for_assignment(id, now)
        }

    %{state | data: data}
  end

  def refresh(%{identity: {"notification", id}} = state, now, _filters),
    do: %{state | data: Mondek.Inspection.notification_detail(id, now)}

  def refresh(%{identity: {"result", id}} = state, now, _filters),
    do: %{state | data: PreviewResult.load(id, now)}

  def refresh(%{identity: {"runner", id}} = state, now, _filters),
    do: %{state | data: RunnerFleet.detail(id, now)}

  def refresh(%{identity: {kind, id}} = state, now, filters) when kind in ~w(health loss) do
    detail =
      if kind == "health" do
        detail =
          Monitoring.incident_detail(id, now, %{
            "page" => filters["member_page"],
            "state" => filters["contributors"] || "default",
            "contradiction_page" => filters["healthy_page"],
            "notification_status" => filters["notification_status"] || "all",
            "notification_page" => filters["notification_page"]
          })

        if detail do
          type = if Map.has_key?(detail, "contributions"), do: "condition", else: "individual"

          candidates =
            case Investigation.read(fn -> CorrelationCandidates.for_episode(type, id) end) do
              {:ok, data} -> data
              {:error, _} -> %{"status" => "unavailable", "candidates" => []}
            end

          Map.put(detail, "correlation_candidates", candidates)
        end
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

  def title(%{identity: {"coverage", _}, data: %{scope: scope}}),
    do:
      MondekWeb.EvidencePresentation.target_label(scope["target"]) <>
        " · " <> MondekWeb.PreviewCoverage.title(scope)

  def title(%{identity: {"coverage", _}}), do: "Declaration unavailable"

  def title(%{identity: {"diagnostic", _}, data: %{item: item}}),
    do: MondekWeb.PreviewCoverage.title(item)

  def title(%{identity: {"diagnostic", _}}), do: "Diagnostic unavailable"

  def title(%{identity: {"execution", _}, data: %{inspection: inspection}}),
    do: inspection["assignment"]["label"] || "Scheduled execution"

  def title(%{identity: {"execution", _}}), do: "Scheduled execution not found"

  def title(%{identity: {"notification", _}, data: detail}),
    do: MondekWeb.NotificationDetail.title(detail && detail["occurrence"])

  def title(%{identity: {"runner", _}, data: runner}) when is_map(runner),
    do: runner["label"] || "Unnamed runner"

  def title(%{identity: {"result", _}, data: %{selected: result}}),
    do: result["label"] || get_in(result, ["check", "label"]) || "Check result"

  def title(%{data: %{incident: incident}}) when is_map(incident),
    do: Mondek.IncidentPresentation.title(incident)

  def title(_), do: "Evidence unavailable"

  def kind(%{identity: {"coverage", _}}), do: "Declared result"
  def kind(%{identity: {"diagnostic", _}}), do: "Runner diagnostic"
  def kind(%{identity: {"execution", _}}), do: "Scheduled execution"
  def kind(%{identity: {"notification", _}}), do: "Notification"
  def kind(%{identity: {"runner", _}}), do: "Runner"
  def kind(%{identity: {"result", _}}), do: "Check result"
  def kind(%{identity: {"loss", _}}), do: "Monitoring loss"
  def kind(%{data: %{detail: %{"contributions" => _}}}), do: "Shared incident"
  def kind(_), do: "Health incident"
end
