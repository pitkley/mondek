# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MondekWeb.PreviewLayouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :require_json_write
  end

  # Browser forms can reach loopback services cross-origin. JSON writes require a
  # non-simple content type, so browsers must pass CORS preflight first; this API
  # does not grant cross-origin access. LiveView forms use the CSRF-protected path.
  defp require_json_write(%Plug.Conn{method: method} = conn, _)
       when method in ["POST", "PUT", "PATCH", "DELETE"] do
    content_type = conn |> get_req_header("content-type") |> List.first()

    if is_binary(content_type) and
         match?({:ok, "application", "json", _}, Plug.Conn.Utils.media_type(content_type)) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> MondekWeb.API.Response.error(
        415,
        "unsupported_media_type",
        "API writes require application/json."
      )
      |> halt()
    end
  end

  defp require_json_write(conn, _), do: conn

  get "/api/docs", MondekWeb.API.SpecController, :docs
  get "/health", MondekWeb.API.V1.SystemController, :health

  get "/configuration.git/info/refs", MondekWeb.ConfigurationGitController, :info
  post "/configuration.git/git-upload-pack", MondekWeb.ConfigurationGitController, :upload

  post "/configuration.git/git-receive-pack",
       MondekWeb.ConfigurationGitController,
       :receive_pack

  live_session :operator_ui do
    scope "/", MondekWeb do
      pipe_through :browser
      live "/", NextOverviewLive, :index
      live "/guide", GuideLive, :guide
      live "/licenses", LicensesLive, :index
      get "/licenses/notices", LicenseController, :notices
      live "/results/:id", NextOverviewLive, :result
      live "/results/:id/full", NextOverviewLive, :result_page
      live "/expected/:id", NextOverviewLive, :expected
      live "/expected/:id/full", NextOverviewLive, :expected
      live "/checks", NextOverviewLive, :checks
      live "/checks/:id/discovery", DiscoveryLive, :show
      live "/checks/:id", NextOverviewLive, :checks_result
      live "/checks/:id/full", NextOverviewLive, :checks_result_page
      live "/executions/:id", ExecutionLive, :show
      live "/coverage", NextOverviewLive, :coverage
      live "/coverage/publishers", PublicationInventoryLive, :index
      live "/coverage/publishers/:id", PublisherLive, :show
      live "/coverage/diagnostics/:id", NextOverviewLive, :coverage_diagnostic
      live "/coverage/diagnostics/:id/full", NextOverviewLive, :coverage_diagnostic
      live "/coverage/:id", NextOverviewLive, :coverage_result
      live "/coverage/:id/full", NextOverviewLive, :coverage_result
      live "/maintenance", MaintenanceLive, :index
      live "/maintenance/new", MaintenanceLive, :new
      live "/maintenance/series/:id/full", MaintenanceLive, :series
      live "/maintenance/series/:id", MaintenanceLive, :series
      live "/maintenance/:id/full", MaintenanceLive, :edit
      live "/maintenance/:id", MaintenanceLive, :edit
      live "/incidents", NextIncidentsLive, :index
      live "/incidents/health/:id", NextIncidentsLive, :health
      live "/incidents/loss/:id", NextIncidentsLive, :loss
      live "/incidents/health/:id/full", NextIncidentsLive, :health
      live "/incidents/loss/:id/full", NextIncidentsLive, :loss
      live "/notifications", NotificationsLive, :notifications
      live "/notifications/:id/full", NotificationsLive, :notification
      live "/notifications/:id", NotificationsLive, :notification
      live "/configuration/history", ConfigurationRepositoryLive, :index
      live "/configuration/rules", ConfigurationRulesLive, :index
      live "/configuration/rules/new", ConfigurationRulesLive, :new
      live "/configuration/rules/:id", ConfigurationRulesLive, :edit
      live "/configuration/discovery/changes/:id", DiscoveryConfigurationLive, :receipt
      live "/configuration/discovery/:id", DiscoveryConfigurationLive, :edit
      live "/configuration", ConfigurationLive, :configuration
      live "/configuration/:id", ConfigurationLive, :configuration_detail
      live "/consumer-state", ConsumerStateLive, :index
      live "/runners", RunnersLive, :index
      live "/runners/:id/full", RunnersLive, :show
      live "/runners/:id", RunnersLive, :show
    end
  end

  scope "/api/v1", MondekWeb do
    pipe_through :api
    get "/openapi.json", API.SpecController, :show
    get "/consumer-state", API.V1.ConsumerStateController, :consumer_state
    get "/consumer-state/:id", API.V1.ConsumerStateController, :consumer_state_entry
    post "/runner/state", API.V1.ConsumerStateController, :runner_state, log: false
    get "/snapshot", API.V1.SystemController, :snapshot
    get "/overview", API.V1.SystemController, :overview
    get "/coverage", API.V1.CoverageController, :coverage
    get "/coverage/publishers", API.V1.CoverageController, :coverage_publishers
    get "/publishers/:id", API.V1.PublishersController, :publisher
    get "/publishers/:id/successors", API.V1.PublishersController, :publisher_successors
    get "/publishers/:id/events/:event_id", API.V1.PublishersController, :publisher_event

    get "/publishers/:id/events/:event_id/evidence/:observation_id",
        API.V1.PublishersController,
        :publisher_evidence

    post "/publishers/preview", API.V1.PublishersController, :publisher_preview
    post "/publishers/apply", API.V1.PublishersController, :publisher_apply
    get "/coverage/diagnostics", API.V1.CoverageController, :coverage_diagnostics
    get "/coverage/:id/observers", API.V1.CoverageController, :coverage_observers
    get "/coverage/:id", API.V1.CoverageController, :coverage_scope
    get "/results", API.V1.ResultsController, :checks
    get "/results/:id/inspection", API.V1.ResultsController, :result_inspection
    get "/results/:id/evidence/:observation_id", API.V1.ResultsController, :observation
    get "/results/:id/evidence", API.V1.ResultsController, :evidence
    get "/results/:id", API.V1.ResultsController, :check
    get "/assignments", API.V1.AssignmentsController, :configuration
    get "/configuration/assignments", API.V1.AssignmentsController, :assignment_configurations
    get "/configuration/revision", API.V1.ConfigurationController, :configuration_revision
    post "/configuration/policy/plan", API.V1.ConfigurationController, :policy_plan
    post "/configuration/policy/apply", API.V1.ConfigurationController, :policy_apply
    get "/configuration/policy/export", API.V1.ConfigurationController, :policy_export
    get "/configuration/policy/values", API.V1.ConfigurationController, :policy_values
    get "/maintenance", API.V1.MaintenanceController, :maintenance_windows
    get "/maintenance/seed/:assignment_id", API.V1.MaintenanceController, :maintenance_seed
    post "/maintenance/preview", API.V1.MaintenanceController, :maintenance_preview
    post "/maintenance/apply", API.V1.MaintenanceController, :maintenance_apply
    get "/maintenance/:id", API.V1.MaintenanceController, :maintenance_window
    post "/maintenance/:id/cancel", API.V1.MaintenanceController, :maintenance_cancel
    post "/maintenance-series/preview", API.V1.MaintenanceController, :maintenance_series_preview
    post "/maintenance-series/apply", API.V1.MaintenanceController, :maintenance_series_apply
    get "/maintenance-series/:id", API.V1.MaintenanceController, :maintenance_series

    post "/maintenance-series/:id/cancel-preview",
         API.V1.MaintenanceController,
         :maintenance_series_cancel_preview

    post "/maintenance-series/:id/cancel",
         API.V1.MaintenanceController,
         :maintenance_series_cancel

    get "/configuration/rules", API.V1.ConfigurationController, :rules
    get "/configuration/rules/seed/:assignment_id", API.V1.ConfigurationController, :rule_seed
    post "/configuration/rules/preview", API.V1.ConfigurationController, :rule_preview
    post "/configuration/rules/apply", API.V1.ConfigurationController, :rule_apply
    get "/configuration/rules/:id", API.V1.ConfigurationController, :rule
    post "/configuration/exception/reset", API.V1.ConfigurationController, :exception_reset
    post "/configuration/bulk/select", API.V1.ConfigurationController, :bulk_select
    post "/configuration/bulk/prepare", API.V1.ConfigurationController, :bulk_prepare
    post "/configuration/bulk/preview", API.V1.ConfigurationController, :bulk_preview
    post "/configuration/bulk/apply", API.V1.ConfigurationController, :bulk_apply
    post "/configuration/bulk/status", API.V1.ConfigurationController, :bulk_status
    get "/runners", API.V1.RunnersController, :runners
    get "/runners/:id", API.V1.RunnersController, :runner
    get "/notifications", API.V1.NotificationsController, :notifications
    get "/notifications/:id", API.V1.NotificationsController, :notification
    get "/assignments/:id", API.V1.AssignmentsController, :assignment
    get "/assignments/:id/configuration", API.V1.AssignmentsController, :assignment_inspection
    post "/assignments/:id/exception/preview", API.V1.ConfigurationController, :exception_preview
    get "/incidents/health", API.V1.IncidentsController, :incidents
    get "/incidents/monitoring-loss", API.V1.IncidentsController, :monitoring_incidents
    get "/incidents/monitoring-loss/:id", API.V1.IncidentsController, :monitoring_incident
    get "/incidents/health/:id", API.V1.IncidentsController, :incident
    post "/runner/control", API.V1.RunnerController, :control
    post "/runner/inventory", API.V1.RunnerController, :inventory
    post "/runner/observations", API.V1.RunnerController, :observations
    put "/assignments/:id/configuration", API.V1.AssignmentsController, :save
    post "/notifications/:id/retry", API.V1.NotificationsController, :retry_notification
    post "/incidents/health/:id/acknowledge", API.V1.IncidentsController, :acknowledge
  end
end
