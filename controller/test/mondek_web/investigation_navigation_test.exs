# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationNavigationTest do
  use ExUnit.Case, async: true

  alias MondekWeb.{
    CheckNavigation,
    CoverageNavigation,
    InvestigationNavigation,
    MonitoringIncidentNavigation,
    NotificationNavigation,
    RunnerNavigation
  }

  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  defp nested(path, return_to), do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})
  defp params(path), do: URI.decode_query(URI.parse(path).query || "")

  test "coverage return paths preserve incident scope but reject external and recursive destinations" do
    incident = "/monitoring-incidents/" <> @id <> "?members_page=2&status=open"
    scope = nested("/coverage/" <> String.duplicate("a", 64), incident)
    assert CoverageNavigation.return_path(scope) == scope
    assert InvestigationNavigation.safe_return_path(scope) == scope
    assert RunnerNavigation.safe_return(scope) == scope
    diagnostic = nested("/checks/disk/diagnostics", scope)
    assert RunnerNavigation.safe_return(diagnostic) == diagnostic
    assert CoverageNavigation.return_path("https://example.org/coverage") == nil
    assert CoverageNavigation.return_path("/coverage/invalid") == nil
    assert CoverageNavigation.return_path(nested("/coverage", scope)) == "/coverage"

    assert CoverageNavigation.return_path(nested("/coverage", "https://example.org")) ==
             "/coverage"
  end

  test "configuration returns to an exact result with bounded, local context" do
    result = nested("/checks/" <> @id, "/checks?search=disk&tab=all&view=list")
    assert InvestigationNavigation.safe_return_path(result) == result
    assert InvestigationNavigation.return_label(result, "") == "Back to result"

    assert InvestigationNavigation.safe_return_path(
             nested("/checks/" <> @id, "https://example.org")
           ) == "/checks/" <> @id

    assert InvestigationNavigation.safe_return_path("https://example.org/checks/" <> @id) == nil
  end

  test "untrusted return destinations cannot escape the known local domains" do
    for invalid <- [
          nil,
          %{},
          "https://example.org/checks",
          "//example.org/checks",
          "/checks#fragment",
          "/unknown",
          "/checks/../runners",
          "/incidents/not-a-uuid",
          String.duplicate("x", 8193)
        ] do
      assert InvestigationNavigation.safe_return_path(invalid) == nil, inspect(invalid)
    end

    for navigation <- [RunnerNavigation, MonitoringIncidentNavigation, NotificationNavigation] do
      assert navigation.return_path("https://example.org/runners/" <> @id) == nil
      assert navigation.return_path("//example.org/runners/" <> @id) == nil
      assert navigation.return_path("/runners/" <> @id <> "#fragment") == nil
    end
  end

  test "canonical return destinations remain stable across refresh and repeated navigation" do
    paths = [
      "/?ignored=discard",
      "/checks?tab=critical&view=list&critical_view=targets&group_search=db&group_limit=240",
      "/configuration?search=disk&configuration_stage=active&page=2&unknown=discard",
      "/incidents?status=closed&page=5",
      "/runners?search=node&collection=issues&page_size=50",
      "/notifications?notification_status=retrying&notification_page=3",
      "/coverage?environment=production&lifecycle=active&page=2",
      nested("/runners/" <> @id, "/runners?contact=overdue"),
      nested("/notifications/" <> @id, "/notifications?notification_status=exhausted"),
      nested("/incidents/" <> @id, "/checks?tab=critical&view=list"),
      nested("/resources/check-id/diagnostics", "/incidents/" <> @id)
    ]

    for path <- paths do
      canonical = InvestigationNavigation.safe_return_path(path)
      assert is_binary(canonical), path
      assert InvestigationNavigation.safe_return_path(canonical) == canonical, path
    end
  end

  test "result diagnostics preserve one shared incident and its inventory but drop deeper incidents" do
    inventory = "/checks?tab=critical&view=list&search=disk&page=3&page_size=25&unknown=drop"
    incident = nested("/incidents/" <> @id, inventory)
    diagnostics = nested("/checks/disk/diagnostics", incident)
    actual = InvestigationNavigation.safe_return_path(diagnostics)
    returned_incident = params(actual)["return_to"]
    returned_inventory = params(returned_incident)["return_to"]
    assert URI.parse(returned_incident).path == "/incidents/" <> @id

    assert params(returned_inventory) == %{
             "tab" => "critical",
             "view" => "list",
             "health" => "CRIT",
             "search" => "disk",
             "page" => "3",
             "page_size" => "25"
           }

    extra = nested("/incidents/" <> @other, inventory)
    result = InvestigationNavigation.safe_return_path(nested("/incidents/" <> @id, extra))
    assert result == "/incidents/" <> @id

    assert InvestigationNavigation.safe_return_path(
             nested("/checks/disk/diagnostics", diagnostics)
           ) == "/checks/disk/diagnostics"
  end

  test "runner return destinations retain fleet filters but not recursively nested runners" do
    fleet = "/runners?search=node&contact=overdue&page=2&unknown=discard"
    runner = RunnerNavigation.return_path(nested("/runners/" <> @id, fleet))
    assert params(params(runner)["return_to"])["search"] == "node"
    refute Map.has_key?(params(params(runner)["return_to"]), "unknown")

    assert RunnerNavigation.return_path(nested("/runners/" <> @other, runner)) ==
             "/runners/" <> @other

    assert RunnerNavigation.path(%{}) == "/runners"
    assert RunnerNavigation.detail_path("invalid") == "/runners/not-found"
  end

  test "runner investigation may return to a result and inventory without creating a runner loop" do
    runner = "/runners/" <> @id
    # Build the query once: the source URL may already carry inventory filters.
    inventory = "/checks?" <> URI.encode_query(%{"tab" => "all", "return_to" => runner})
    path = RunnerNavigation.safe_return(nested("/checks/disk/diagnostics", inventory))
    assert URI.parse(path).path == "/checks/disk/diagnostics"
    refute Map.has_key?(params(params(path)["return_to"]), "return_to")
    assert RunnerNavigation.safe_return("/checks") == nil
  end

  test "exact target investigation retains origin and never silently accepts a malformed target" do
    origin =
      CheckNavigation.normalize(%{
        "tab" => "critical",
        "view" => "list",
        "search" => "disk",
        "page" => "4"
      })

    target = "target-" <> String.duplicate("a", 64)

    scoped =
      CheckNavigation.target_context_path(target, origin)
      |> params()
      |> CheckNavigation.normalize()

    assert scoped["target_scope"] == target
    assert scoped["tab"] == "all"
    assert scoped["view"] == "list"
    assert scoped["investigation_return"] == CheckNavigation.path(origin)
    refute Map.has_key?(scoped, "search")

    assert CheckNavigation.normalize(%{"target_scope" => "bad"})["target_scope"] ==
             "invalid-target"

    assert CheckNavigation.investigation_return(CheckNavigation.path(scoped)) == nil
    assert CheckNavigation.investigation_return("/checks?investigation_return=%2Fchecks") == nil
    assert CheckNavigation.normalize(%{"group_limit" => "99999"})["group_limit"] == "1000"
  end

  test "monitoring incident returns retain bounded status and runner or notification origin" do
    notification =
      NotificationNavigation.detail_path(@other, "/notifications?notification_status=exhausted")

    path =
      "/monitoring-incidents/" <>
        @id <>
        "?" <>
        URI.encode_query(%{
          "status" => "open",
          "members_page" => "3",
          "return_to" => notification,
          "unknown" => "discard"
        })

    result = MonitoringIncidentNavigation.return_path(path)

    assert params(result) == %{
             "status" => "open",
             "members_page" => "3",
             "return_to" => notification
           }

    assert MonitoringIncidentNavigation.return_path("/monitoring-incidents") == nil
    assert InvestigationNavigation.safe_return_path(path) == result

    assert MonitoringIncidentNavigation.normalize_filters(%{
             "status" => String.duplicate("x", 201),
             "page" => 2
           }) == %{}
  end

  test "coverage preserves valid bounded filters and exact scope identity" do
    id = String.duplicate("a", 64)

    path =
      InvestigationNavigation.safe_return_path(
        "/coverage/" <> id <> "?source_id=source&status=missing&page=2&unknown=discard"
      )

    assert URI.parse(path).path == "/coverage/" <> id
    assert params(path) == %{"source_id" => "source", "status" => "missing", "page" => "2"}
    assert InvestigationNavigation.safe_return_path("/coverage/not-valid") == nil

    assert CoverageNavigation.filters(%{"search" => "bad\ntext", "page" => 2, "unknown" => "x"}) ==
             %{"page" => 2}
  end

  test "incident notification links reset delivery page while retaining the investigation origin" do
    incident = %{"id" => @id}

    return_to =
      "/incidents/" <>
        @id <>
        "?" <>
        URI.encode_query(%{
          "notification_page" => "8",
          "notification_id" => @other,
          "state" => "active",
          "return_to" => "/incidents?status=open"
        })

    result = InvestigationNavigation.parent_notification_path(incident, return_to)
    assert URI.parse(result).fragment == "incident-occurrences"

    assert params(result) == %{
             "notification_status" => "all",
             "state" => "active",
             "return_to" => "/incidents?status=open"
           }

    assert InvestigationNavigation.return_label(result, "fallback") == "Back to incident"
    assert InvestigationNavigation.return_label(nil, "fallback") == "fallback"
  end
end
