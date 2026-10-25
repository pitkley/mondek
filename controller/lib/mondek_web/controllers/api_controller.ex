# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.APIController do
  use MondekWeb, :controller
  alias Mondek.Monitoring
  def health(conn, _), do: json(conn, %{status: "ok"})
  def snapshot(conn, _), do: json(conn, Monitoring.snapshot())
  def overview(conn, _), do: json(conn, Monitoring.overview())
  def checks(conn, params), do: json(conn, Monitoring.list_streams(params))
  def incidents(conn, params), do: json(conn, Monitoring.list_incidents(params))
  def monitoring_incidents(conn, params), do: json(conn, Mondek.MonitoringLoss.list(params))

  def monitoring_incident(conn, %{"id" => id} = params) do
    case Mondek.MonitoringLoss.detail(id, Monitoring.now(), params) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Monitoring incident not found."})
      incident -> json(conn, incident)
    end
  end

  def configuration(conn, params), do: json(conn, Monitoring.list_checks(params))
  def runners(conn, params), do: json(conn, Mondek.RunnerFleet.list(params))

  def runner(conn, %{"id" => id}) do
    case Mondek.RunnerFleet.detail(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Runner not found."})
      runner -> json(conn, runner)
    end
  end

  def notifications(conn, params), do: json(conn, Monitoring.delivery_inspection(params))

  def notification(conn, %{"id" => id}) do
    case Mondek.Inspection.notification_detail(id, Monitoring.now()) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Notification not found."})
      notification -> json(conn, notification)
    end
  end

  def coverage(conn, params), do: json(conn, Mondek.Coverage.scopes(params))
  def coverage_publishers(conn, params), do: json(conn, Mondek.Coverage.publishers(params))

  def publisher(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.get(id, p["page"] || 1))

  def publisher_successors(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.successors(id, p))

  def publisher_event(conn, %{"id" => id, "event_id" => event_id} = p),
    do: respond(conn, Mondek.PublisherLifecycle.event(id, event_id, p["page"] || 1))

  def publisher_evidence(conn, %{
        "id" => id,
        "event_id" => event_id,
        "observation_id" => observation_id
      }),
      do: respond(conn, Mondek.PublisherLifecycle.evidence(id, event_id, observation_id))

  def publisher_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.PublisherLifecycle.preview(
          p["proposal"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def publisher_apply(conn, p),
    do: respond(conn, Mondek.PublisherLifecycle.apply(p["review_token"], p["proposal"]))

  def coverage_diagnostics(conn, params), do: json(conn, Mondek.Coverage.diagnostics(params))

  def coverage_observers(conn, %{"id" => id} = params),
    do: json(conn, Mondek.Coverage.observers(id, params))

  def coverage_scope(conn, %{"id" => id}) do
    case Mondek.Coverage.scope(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Coverage scope not found."})
      scope -> json(conn, scope)
    end
  end

  def maintenance_windows(conn, p), do: json(conn, Mondek.Maintenance.list(p))

  def maintenance_seed(conn, %{"assignment_id" => id} = p),
    do: respond(conn, Mondek.Maintenance.seed(id, p["stream_id"]))

  def maintenance_window(conn, %{"id" => id}), do: respond(conn, Mondek.Maintenance.get(id))

  def maintenance_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.Maintenance.preview(
          p["proposal"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_apply(conn, p),
    do: respond(conn, Mondek.Maintenance.apply(p["review_token"], p["proposal"]))

  def maintenance_cancel(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.Maintenance.cancel(id, integer(p["revision"]), p["reason"]))

  def maintenance_series(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.MaintenanceSchedules.get(id, p))

  def maintenance_series_preview(conn, p),
    do:
      respond(
        conn,
        Mondek.MaintenanceSchedules.preview(
          p["proposal"],
          p["occurrence_page"] || 1,
          p["result_page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_series_apply(conn, p),
    do: respond(conn, Mondek.MaintenanceSchedules.apply(p["review_token"], p["proposal"]))

  def maintenance_series_cancel_preview(conn, %{"id" => id} = p),
    do:
      respond(
        conn,
        Mondek.MaintenanceSchedules.cancel_preview(
          id,
          integer(p["revision"]),
          p["reason"],
          p["page"] || 1,
          nil,
          p["review_token"]
        )
      )

  def maintenance_series_cancel(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.MaintenanceSchedules.cancel(id, p["review_token"], p["reason"]))

  def rules(conn, p), do: json(conn, Mondek.ConfigurationRules.list(p["page"] || 1))

  def configuration_revision(conn, _params) do
    case Mondek.ConfigurationRepository.state() do
      {:ok, state} -> json(conn, %{head: state.head, installation_id: state.installation_id})
      {:error, reason} -> respond(conn, {:error, reason})
    end
  end

  def policy_plan(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.plan(p["manifest"], p["base_head"]))

  def policy_apply(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.apply(p["review_token"], p["manifest"]))

  def policy_export(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.export(p["project"]))

  def policy_values(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.values(p["source_id"], p["page"] || 1))

  def rule_seed(conn, %{"assignment_id" => id}),
    do: respond(conn, Mondek.ConfigurationRules.seed(id))

  def rule(conn, %{"id" => id}), do: respond(conn, Mondek.ConfigurationRules.get(id))

  def rule_preview(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.preview(p["proposal"], p["page"] || 1))

  def rule_apply(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.apply(p["review_token"], p["proposal"]))

  def exception_preview(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.ConfigurationRules.preview_reset(id, integer(p["revision"])))

  def exception_reset(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.reset_exception(p["review_token"]))

  def bulk_select(conn, p),
    do: respond(conn, Monitoring.select_bulk_configuration(p["filters"] || %{}))

  def bulk_prepare(conn, p),
    do: respond(conn, Monitoring.prepare_bulk_configuration(p["selection"], p["page"] || 1))

  def bulk_preview(conn, p),
    do:
      respond(
        conn,
        Monitoring.preview_bulk_configuration(p["prepare_token"], p["params"], p["page"] || 1)
      )

  def bulk_apply(conn, p),
    do: respond(conn, Monitoring.apply_bulk_configuration(p["review_token"], p["params"]))

  def bulk_status(conn, p),
    do: respond(conn, Monitoring.bulk_configuration_status(p["receipts"], p["page"] || 1))

  def check(conn, %{"id" => id}) do
    case Monitoring.stream_inspection(id) do
      nil -> respond(conn, {:error, :not_found})
      detail -> json(conn, detail)
    end
  end

  def assignment(conn, %{"id" => id}) do
    case Monitoring.assignment_detail(id) do
      nil -> respond(conn, {:error, :not_found})
      detail -> json(conn, detail)
    end
  end

  def assignment_inspection(conn, %{"id" => id}) do
    case Monitoring.assignment_inspection(id) do
      nil -> respond(conn, {:error, :not_found})
      detail -> json(conn, detail)
    end
  end

  def retry_notification(conn, %{"id" => id} = p),
    do: respond(conn, Monitoring.retry_notification(id, p["reason"]))

  def incident(conn, %{"id" => id} = params) do
    case Monitoring.incident_detail(id, Monitoring.now(), Map.drop(params, ["id"])) do
      nil -> respond(conn, {:error, :not_found})
      detail -> json(conn, detail)
    end
  end

  def inventory(conn, params), do: respond(conn, Monitoring.inventory(params))

  def observations(conn, params), do: respond(conn, Monitoring.ingest(params))

  def control(conn, params) do
    case Mondek.Protocol.control(params) do
      :ok ->
        # Subscribe before the durable read, then wait outside its transaction.
        # Heartbeats and observations update the UI topic only: waking every peer
        # on recurring traffic creates a self-sustaining fleet polling storm.
        topics = [
          Monitoring.control_topic(nil),
          Monitoring.control_topic(params["installation_id"])
        ]

        for topic <- topics, do: Phoenix.PubSub.subscribe(Mondek.PubSub, topic)

        try do
          result = Monitoring.control(params)
          wait = control_wait_seconds(params, result)

          if match?({:ok, _}, result) and wait > 0 do
            receive do
              :control_changed -> :ok
            after
              wait * 1000 -> :ok
            end

            respond(conn, Monitoring.control(Map.put(params, "wait_seconds", 0)))
          else
            respond(conn, result)
          end
        after
          for topic <- topics, do: Phoenix.PubSub.unsubscribe(Mondek.PubSub, topic)
        end

      error ->
        respond(conn, error)
    end
  end

  defp control_wait_seconds(params, {:ok, response}) do
    desired = Map.new(response["assignments"], &{&1["id"], &1["generation"]})

    actionable =
      response["assignments_authoritative"] != true ||
        desired != (params["active"] || %{}) ||
        desired != (params["prepared"] || %{}) ||
        map_size(response["inventory_refresh"] || %{}) > 0

    if actionable && (params["wait_seconds"] || 0) > 2,
      do: 0,
      else: min(params["wait_seconds"] || 0, div(Mondek.MonitoringLoss.contact_seconds(), 2))
  end

  defp control_wait_seconds(_params, _result), do: 0

  def save(conn, %{"id" => id} = p),
    do: respond(conn, Monitoring.save_assignment(id, integer(p["revision"]), p["params"]))

  def acknowledge(conn, %{"id" => id} = p) do
    respond(
      conn,
      Monitoring.acknowledge(id, Map.drop(p, ["id", "note"]), p["note"] || "Acknowledged locally")
    )
  end

  defp integer(n) when is_integer(n), do: n

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp respond(conn, {:ok, value}), do: json(conn, value)

  defp respond(conn, {:error, {:invalid, reason}}),
    do: conn |> put_status(422) |> json(%{error: reason})

  defp respond(conn, {:error, {:conflict, reason}}),
    do: conn |> put_status(409) |> json(%{code: "configuration_conflict", error: reason})

  defp respond(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "Not found"})

  defp respond(conn, {:error, :publisher_retired}),
    do:
      conn
      |> put_status(409)
      |> json(%{
        code: "publisher_retired",
        error:
          "This source publication was retired by the operator. Its inventory remains fenced until explicitly restored."
      })

  defp respond(conn, {:error, :publication_refresh_required}),
    do:
      conn
      |> put_status(409)
      |> json(%{
        code: "publication_refresh_required",
        error:
          "Restoration requires successful discovery for the controller's current restoration request and a newer complete inventory. Upgrade to a runner supporting this request and refresh discovery before publishing again."
      })

  defp respond(conn, {:error, {:stale, ids}}),
    do:
      conn
      |> put_status(409)
      |> json(%{
        code: "stale_selection",
        stale_ids: ids,
        error:
          "Selected checks changed. Keep the draft, refresh the selection and review it again."
      })

  defp respond(conn, {:error, :review_expired}),
    do:
      conn
      |> put_status(409)
      |> json(%{
        code: "review_expired",
        error: "This review expired after 15 minutes. Keep the draft and review it again."
      })

  defp respond(conn, {:error, :review_changed}),
    do:
      conn
      |> put_status(409)
      |> json(%{
        code: "review_changed",
        error:
          "The draft or matching records changed after review. Review the current draft before applying it."
      })

  defp respond(conn, {:error, :invalid_review}),
    do:
      conn
      |> put_status(422)
      |> json(%{
        code: "invalid_review",
        error: "Supply a valid review before applying changes."
      })

  defp respond(conn, {:error, reason}),
    do: conn |> put_status(409) |> json(%{error: to_string(reason)})
end
