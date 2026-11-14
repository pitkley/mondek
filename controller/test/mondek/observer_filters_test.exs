# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ObserverFiltersTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    ChecksFilters,
    Coverage,
    CoverageFilters,
    CoverageFixtures,
    Inspection,
    ObserverFilters
  }

  @moduletag :empty_source_fixture

  test "check and coverage scopes apply exact runner and source before pagination" do
    now = Monitoring.now()
    candidate = CoverageFixtures.candidate(CoverageFixtures.check("Shared check"))

    publications =
      for source <- ["source-one", "source-two"] do
        p = CoverageFixtures.publication([candidate], %{"source_id" => source})
        assert {:ok, _} = Monitoring.inventory(p, now)
        assert {:ok, _} = CoverageFixtures.activate(p, now)
        assert disposition(CoverageFixtures.sample(p, "OK", 1, now)) == "current"
        p
      end

    [first, second] = publications
    assert Inspection.preview_checks(%{}, now).total == 2

    assert Inspection.preview_checks(
             ChecksFilters.params(%{"runner_id" => first["installation_id"]}),
             now
           ).total == 1

    assert Inspection.preview_checks(
             ChecksFilters.params(%{"source_id" => first["source_id"]}),
             now
           ).total == 1

    assert Inspection.preview_checks(
             ChecksFilters.params(%{
               "runner_id" => first["installation_id"],
               "source_id" => second["source_id"]
             }),
             now
           ).total == 0

    assert Coverage.scopes(
             CoverageFilters.params(%{"runner_id" => first["installation_id"]}),
             now
           )["total"] == 1

    assert Coverage.scopes(CoverageFilters.params(%{"source_id" => first["source_id"]}), now)[
             "total"
           ] == 1

    assert Coverage.scopes(
             CoverageFilters.params(%{
               "runner_id" => first["installation_id"],
               "source_id" => second["source_id"]
             }),
             now
           )["total"] == 0

    assert Inspection.preview_checks(ChecksFilters.params(%{"runner_id" => "unknown"}), now).total ==
             0

    assert Coverage.scopes(CoverageFilters.params(%{"runner_id" => "unknown"}), now)["total"] == 0

    assert [%{key: id, label: label}] =
             ObserverFilters.options("runner_id", "", {first["installation_id"], ""})

    assert id == first["installation_id"]
    assert label =~ String.slice(id, 0, 8)
    assert length(ObserverFilters.options("source_id", "source-")) == 2
  end
end
