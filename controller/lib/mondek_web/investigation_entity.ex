# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationEntity do
  @moduledoc "Bounded evidence and retained control state for one investigation entity."
  alias Mondek.{
    CorrelationAutomationPolicy,
    CorrelationCandidates,
    CorrelationDecisionProvider,
    CorrelationProviderDecisions,
    CorrelationRelationships,
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
      provider_request_id: Ecto.UUID.generate(),
      provider_fingerprint: nil,
      provider_review: nil,
      provider_message: nil,
      override_review: nil,
      override_message: nil,
      relationship_review: nil,
      relationship_message: nil,
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
    {provider, fingerprint} = if kind == "health", do: provider_disclosure(), else: {nil, nil}

    state =
      if state.provider_fingerprint != fingerprint do
        %{
          state
          | provider_fingerprint: fingerprint,
            provider_request_id: Ecto.UUID.generate(),
            provider_review: nil
        }
      else
        state
      end

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

          relationships =
            CorrelationRelationships.list(
              type,
              id,
              max(1, MondekWeb.MonitoringUI.integer(filters["relationships_page"]))
            )

          provider_decisions =
            if relationships do
              subject = relationships["subject"]
              page = max(1, MondekWeb.MonitoringUI.integer(filters["decisions_page"]))
              listing = CorrelationProviderDecisions.list(subject["type"], subject["id"], page)

              Map.merge(listing, %{"subject" => subject, "provider" => provider})
            end

          override =
            if relationships do
              override = CorrelationAutomationPolicy.override(relationships["subject"])

              if override && (override["active"] || CorrelationAutomationPolicy.enabled?()),
                do: override
            end

          evaluation =
            if relationships do
              subject = relationships["subject"]
              Mondek.CorrelationGrouping.latest(subject["type"], subject["id"])
            end

          standalone? =
            if (override || provider_decisions["provider"]) &&
                 detail["incident"]["status"] == "open" &&
                 relationships["subject"]["id"] == id do
              is_nil(Mondek.Correlations.membership(type, id))
            else
              false
            end

          requestable? =
            standalone? && !override["active"] && !is_nil(provider_decisions["provider"])

          detail
          |> Map.put("correlation_candidates", candidates)
          |> Map.put("relationships", relationships)
          |> Map.put(
            "provider_decisions",
            if(provider_decisions, do: Map.put(provider_decisions, "requestable", requestable?))
          )
          |> Map.put("grouping_evaluation", evaluation)
          |> Map.put("grouping_override", override)
          |> Map.put("grouping_override_editable", standalone? && !is_nil(override))
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

  defp provider_disclosure do
    case CorrelationDecisionProvider.configuration() do
      {:ok, config} ->
        uri = URI.new!(config.url)

        disclosure = %{
          "id" => config.id,
          "destination" =>
            URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port}),
          "evidence" => config.evidence
        }

        {disclosure, CorrelationDecisionProvider.fingerprint(config)}

      {:error, :unavailable} ->
        {nil, nil}
    end
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
