# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationNavigationTest do
  use ExUnit.Case, async: true

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationNavigation,
    InvestigationTrail,
    RunnerNavigation
  }

  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  test "coverage return paths retain exact scope and validated nested destinations" do
    scope = "/coverage/" <> String.duplicate("a", 64)
    path = scope <> "?source_id=source&environment=production&page=2&return_to=%2Fincidents"

    assert BrowserNavigation.return_path(path) ==
             scope <> "?environment=production&page=2&return_to=%2Fincidents&source_id=source"

    assert BrowserNavigation.return_path("https://example.org" <> scope) == nil
    assert BrowserNavigation.return_path(scope <> "#fragment") == nil
  end

  test "configuration returns retain typed result identity and reject external nested origins" do
    path = InvestigationTrail.path("/configuration/#{@id}", [{"result", @other}])
    assert BrowserNavigation.return_path(path) == path
    assert InvestigationNavigation.return_label("/results/#{@id}/full", "") == "Back to result"
    assert BrowserNavigation.return_path(path <> "&return_to=https%3A%2F%2Fexample.org") == path
  end

  test "untrusted or malformed return destinations cannot escape known browser routes" do
    for invalid <- [
          nil,
          %{},
          "https://example.org/checks",
          "//example.org/checks",
          "/checks#fragment",
          "/unknown",
          "/checks/../runners",
          String.duplicate("x", 8193),
          "/api/v1/checks",
          "/configuration.git/info/refs",
          "/licenses/notices"
        ] do
      assert BrowserNavigation.return_path(invalid) == nil, inspect(invalid)
    end
  end

  test "canonical list destinations remain stable after repeated normalization" do
    for path <- [
          "/?ignored=discard",
          "/checks?health=CRIT&search=disk&page=3",
          "/configuration?configuration_stage=active&page=2",
          "/incidents?grouping=all&status=closed&page=5",
          "/runners?search=node&collection=issues&page_size=50",
          "/notifications?notification_status=retrying&notification_page=3",
          "/coverage?environment=production&page=2"
        ] do
      canonical = BrowserNavigation.return_path(path)
      assert is_binary(canonical)
      assert BrowserNavigation.return_path(canonical) == canonical
    end
  end

  test "result incident and runner navigation uses typed identities rather than recursive return URLs" do
    trail = [{"result", @id}, {"health", @other}, {"runner", @id}]
    path = InvestigationTrail.path("/checks?health=CRIT&page=2", trail)

    assert {:ok, ^trail} =
             InvestigationTrail.parse(URI.decode_query(URI.parse(path).query)["inspect"])

    assert BrowserNavigation.return_path(path) == path
    assert {:ok, [{"result", @id}]} = InvestigationTrail.open(trail, {"result", @id})
    assert {:ok, []} = InvestigationTrail.open(trail, {"result", @id}, {"result", @id})
  end

  test "runner URLs retain real scalar source and search values" do
    assert RunnerNavigation.path(%{}) == "/runners"
    path = RunnerNavigation.path(%{"source_id" => "all", "search" => "all", "page" => "2"})
    query = URI.decode_query(URI.parse(path).query)
    assert query["source_id"] == "all"
    assert query["search"] == "all"
    assert RunnerNavigation.detail_path("invalid") == "/runners/not-found"
  end

  test "direct entity pages participate in root identity and dedup" do
    for {path, identity} <- [
          {"/results/#{@id}/full", {"result", @id}},
          {"/incidents/health/#{@id}/full", {"health", @id}},
          {"/incidents/loss/#{@id}/full", {"loss", @id}},
          {"/runners/#{@id}/full", {"runner", @id}},
          {"/executions/#{@id}", {"execution", @id}}
        ] do
      assert InvestigationTrail.root(path) == identity
      assert {:ok, []} = InvestigationTrail.open([{"result", @other}], identity, identity)
    end
  end

  test "exact target chips require both key and kind while retaining source and environment" do
    filters =
      Mondek.ChecksFilters.params(%{
        "source_id" => "source",
        "environment" => "production",
        "target_kind" => "host",
        "target_key" => "host-a",
        "page" => "4"
      })

    assert filters["target_key"] == "host-a"
    assert filters["target_kind"] == "host"
    assert filters["source_id"] == "source"
    assert Mondek.ChecksFilters.params(%{"target_key" => "host-a"}) == %{}
    assert Mondek.ChecksFilters.params(%{"target_kind" => "host"}) == %{}
  end

  test "monitoring loss and notifications retain independent page parameters in typed trails" do
    path =
      InvestigationTrail.path("/incidents?type=loss&member_page=3&notification_page=2", [
        {"loss", @id},
        {"notification", @other}
      ])

    canonical = BrowserNavigation.return_path(path)
    query = URI.decode_query(URI.parse(canonical).query)
    assert query["member_page"] == "3"
    assert query["notification_page"] == "2"
    assert query["type"] == "loss"
  end

  test "coverage identity and malformed investigation admission stay bounded" do
    hash = String.duplicate("a", 64)
    assert InvestigationTrail.initial("/coverage/" <> hash) == [{"coverage", hash}]
    assert InvestigationTrail.initial("/coverage/diagnostics/12") == [{"diagnostic", "12"}]
    assert InvestigationTrail.identity({"coverage", "not-valid"}) == nil
    assert InvestigationTrail.identity({"diagnostic", "-1"}) == nil
    assert BrowserNavigation.return_path("/coverage?inspect=not-valid") == nil
    assert BrowserNavigation.return_path("/checks?search[x]=bad") == nil
  end

  test "human return labels describe the actual destination without prototype vocabulary" do
    for {path, expected} <- [
          {"/", "overview"},
          {"/checks", "checks"},
          {"/incidents/health/#{@id}/full", "incident"},
          {"/executions/#{@id}", "scheduled execution"},
          {"/runners/#{@id}/full", "runner"},
          {"/coverage/" <> String.duplicate("a", 64), "coverage"}
        ] do
      assert InvestigationNavigation.return_label(path, "fallback") == "Back to " <> expected
    end

    assert InvestigationNavigation.return_label(nil, "fallback") == "fallback"
  end
end
