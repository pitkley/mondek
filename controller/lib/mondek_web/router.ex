# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MondekWeb.Layouts, :root}
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
      |> send_resp(415, ~s({"error":"API writes require application/json."}))
      |> halt()
    end
  end

  defp require_json_write(conn, _), do: conn

  get "/health", MondekWeb.APIController, :health

  get "/configuration.git/info/refs", MondekWeb.ConfigurationGitController, :info
  post "/configuration.git/git-upload-pack", MondekWeb.ConfigurationGitController, :upload

  post "/configuration.git/git-receive-pack",
       MondekWeb.ConfigurationGitController,
       :receive_pack

  scope "/", MondekWeb do
    pipe_through :browser
    live "/licenses", LicensesLive, :index
    get "/licenses/notices", LicenseController, :notices
    live "/", OverviewLive, :overview
    live "/checks", ChecksLive, :checks
    live "/coverage", CoverageLive, :index
    live "/coverage/publishers", CoverageLive, :publishers
    live "/coverage/publishers/:id", PublisherLive, :show
    live "/coverage/diagnostics", CoverageLive, :diagnostics
    live "/coverage/:id", CoverageLive, :show
    live "/checks/:id/diagnostics", ResultLive, :check_diagnostics
    live "/resources/:id/diagnostics", ResultLive, :resource_diagnostics
    live "/checks/:id/discovery", DiscoveryLive, :show
    live "/checks/:id", ResultLive, :check
    live "/resources/:id", ResultLive, :resource
    live "/incidents", IncidentsLive, :incidents
    live "/monitoring-incidents", MonitoringIncidentsLive, :index
    live "/monitoring-incidents/:id", MonitoringIncidentsLive, :show
    live "/maintenance", MaintenanceLive, :index
    live "/maintenance/new", MaintenanceLive, :new
    live "/maintenance/series/:id", MaintenanceLive, :series
    live "/maintenance/:id", MaintenanceLive, :edit
    live "/configuration", ConfigurationLive, :configuration
    live "/configuration/history", ConfigurationRepositoryLive, :index
    live "/configuration/rules", ConfigurationRulesLive, :index
    live "/configuration/rules/new", ConfigurationRulesLive, :new
    live "/configuration/rules/:id", ConfigurationRulesLive, :edit
    live "/configuration/new", ConfigurationLive, :onboarding
    live "/configuration/discovery/changes/:id", DiscoveryConfigurationLive, :receipt
    live "/configuration/discovery/:id", DiscoveryConfigurationLive, :edit
    live "/configuration/:id", ConfigurationLive, :configuration_detail
    live "/incidents/:id", IncidentLive, :incident
    live "/runners", RunnersLive, :index
    live "/runners/:id", RunnersLive, :show
    live "/notifications", NotificationsLive, :notifications
    live "/notifications/:id", NotificationsLive, :notification
    live "/guide", GuideLive, :guide
  end

  scope "/api/v1", MondekWeb do
    pipe_through :api
    get "/snapshot", APIController, :snapshot
    get "/overview", APIController, :overview
    get "/coverage", APIController, :coverage
    get "/coverage/publishers", APIController, :coverage_publishers
    get "/publishers/:id", APIController, :publisher
    get "/publishers/:id/successors", APIController, :publisher_successors
    get "/publishers/:id/events/:event_id", APIController, :publisher_event

    get "/publishers/:id/events/:event_id/evidence/:observation_id",
        APIController,
        :publisher_evidence

    post "/publishers/preview", APIController, :publisher_preview
    post "/publishers/apply", APIController, :publisher_apply
    get "/coverage/diagnostics", APIController, :coverage_diagnostics
    get "/coverage/:id/observers", APIController, :coverage_observers
    get "/coverage/:id", APIController, :coverage_scope
    get "/checks", APIController, :checks
    get "/checks/:id", APIController, :check
    get "/configuration", APIController, :configuration
    get "/configuration/revision", APIController, :configuration_revision
    post "/configuration/policy/plan", APIController, :policy_plan
    post "/configuration/policy/apply", APIController, :policy_apply
    get "/configuration/policy/export", APIController, :policy_export
    get "/configuration/policy/values", APIController, :policy_values
    get "/maintenance", APIController, :maintenance_windows
    get "/maintenance/seed/:assignment_id", APIController, :maintenance_seed
    post "/maintenance/preview", APIController, :maintenance_preview
    post "/maintenance/apply", APIController, :maintenance_apply
    get "/maintenance/:id", APIController, :maintenance_window
    post "/maintenance/:id/cancel", APIController, :maintenance_cancel
    post "/maintenance-series/preview", APIController, :maintenance_series_preview
    post "/maintenance-series/apply", APIController, :maintenance_series_apply
    get "/maintenance-series/:id", APIController, :maintenance_series

    post "/maintenance-series/:id/cancel-preview",
         APIController,
         :maintenance_series_cancel_preview

    post "/maintenance-series/:id/cancel", APIController, :maintenance_series_cancel
    get "/configuration/rules", APIController, :rules
    get "/configuration/rules/seed/:assignment_id", APIController, :rule_seed
    post "/configuration/rules/preview", APIController, :rule_preview
    post "/configuration/rules/apply", APIController, :rule_apply
    get "/configuration/rules/:id", APIController, :rule
    post "/configuration/exception/reset", APIController, :exception_reset
    post "/configuration/bulk/select", APIController, :bulk_select
    post "/configuration/bulk/prepare", APIController, :bulk_prepare
    post "/configuration/bulk/preview", APIController, :bulk_preview
    post "/configuration/bulk/apply", APIController, :bulk_apply
    post "/configuration/bulk/status", APIController, :bulk_status
    get "/runners", APIController, :runners
    get "/runners/:id", APIController, :runner
    get "/notifications", APIController, :notifications
    get "/notifications/:id", APIController, :notification
    get "/assignments/:id", APIController, :assignment
    get "/assignments/:id/inspection", APIController, :assignment_inspection
    post "/assignments/:id/exception/preview", APIController, :exception_preview
    get "/incidents", APIController, :incidents
    get "/monitoring-incidents", APIController, :monitoring_incidents
    get "/monitoring-incidents/:id", APIController, :monitoring_incident
    get "/incidents/:id", APIController, :incident
    get "/health", APIController, :health
    post "/control", APIController, :control
    post "/inventory", APIController, :inventory
    post "/observations", APIController, :observations
    put "/assignments/:id", APIController, :save
    post "/notifications/:id/retry", APIController, :retry_notification
    post "/incidents/:id/acknowledge", APIController, :acknowledge
  end
end
