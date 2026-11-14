# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.OperatorRoutesTest do
  use ExUnit.Case, async: true
  alias MondekWeb.Router

  @id "10000000-0000-4000-8000-000000000001"
  @scope String.duplicate("a", 64)
  @entries [
    {"/", MondekWeb.NextOverviewLive},
    {"/checks", MondekWeb.NextOverviewLive},
    {"/results/#{@id}/full", MondekWeb.NextOverviewLive},
    {"/executions/#{@id}", MondekWeb.ExecutionLive},
    {"/incidents", MondekWeb.NextIncidentsLive},
    {"/incidents/health/#{@id}/full", MondekWeb.NextIncidentsLive},
    {"/incidents/loss/#{@id}/full", MondekWeb.NextIncidentsLive},
    {"/coverage", MondekWeb.NextOverviewLive},
    {"/coverage/#{@scope}/full", MondekWeb.NextOverviewLive},
    {"/coverage/diagnostics/1/full", MondekWeb.NextOverviewLive},
    {"/coverage/publishers", MondekWeb.PublicationInventoryLive},
    {"/coverage/publishers/1", MondekWeb.PublisherLive},
    {"/maintenance", MondekWeb.MaintenanceLive},
    {"/maintenance/new", MondekWeb.MaintenanceLive},
    {"/maintenance/#{@id}/full", MondekWeb.MaintenanceLive},
    {"/maintenance/series/#{@id}/full", MondekWeb.MaintenanceLive},
    {"/configuration", MondekWeb.ConfigurationLive},
    {"/configuration/#{@id}", MondekWeb.ConfigurationLive},
    {"/configuration/history", MondekWeb.ConfigurationRepositoryLive},
    {"/configuration/rules", MondekWeb.ConfigurationRulesLive},
    {"/configuration/rules/new", MondekWeb.ConfigurationRulesLive},
    {"/configuration/rules/#{@id}", MondekWeb.ConfigurationRulesLive},
    {"/checks/#{@id}/discovery", MondekWeb.DiscoveryLive},
    {"/configuration/discovery/#{@id}", MondekWeb.DiscoveryConfigurationLive},
    {"/configuration/discovery/changes/#{@id}", MondekWeb.DiscoveryConfigurationLive},
    {"/runners", MondekWeb.RunnersLive},
    {"/runners/#{@id}/full", MondekWeb.RunnersLive},
    {"/notifications", MondekWeb.NotificationsLive},
    {"/notifications/#{@id}/full", MondekWeb.NotificationsLive},
    {"/guide", MondekWeb.GuideLive},
    {"/licenses", MondekWeb.LicensesLive}
  ]

  test "every operator entry uses the one migrated session and expected page owner" do
    for {path, module} <- @entries do
      assert %{
               plug: Phoenix.LiveView.Plug,
               phoenix_live_view: {^module, _, _, %{name: :operator_ui}}
             } =
               Phoenix.Router.route_info(Router, "GET", path, "www.example.com")
    end
  end

  test "retired renderer routes and the parallel prefix are absent" do
    routes = Router.__routes__()
    refute Enum.any?(routes, &String.starts_with?(&1.path, "/next"))

    for path <- ["/", "/checks", "/incidents", "/coverage", "/maintenance"] do
      assert Enum.count(routes, &(&1.path == path && &1.verb == :get)) == 1
    end

    for path <- [
          "/resources/:id",
          "/checks/:id/diagnostics",
          "/monitoring-incidents",
          "/monitoring-incidents/:id",
          "/incidents/:id"
        ] do
      refute Enum.any?(routes, &(&1.path == path))
    end
  end

  test "API, Git and downloadable credits keep their explicit non-LiveView endpoints" do
    for {method, path} <- [
          {"GET", "/health"},
          {"GET", "/api/v1/checks"},
          {"GET", "/api/v1/monitoring-incidents"},
          {"GET", "/configuration.git/info/refs"},
          {"POST", "/configuration.git/git-upload-pack"},
          {"POST", "/configuration.git/git-receive-pack"},
          {"GET", "/licenses/notices"}
        ] do
      assert %{plug: plug} = Phoenix.Router.route_info(Router, method, path, "www.example.com")
      refute plug == Phoenix.LiveView.Plug
    end
  end
end
