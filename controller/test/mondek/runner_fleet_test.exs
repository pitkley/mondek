# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RunnerFleetTest do
  use Mondek.DataCase, async: false
  alias Mondek.{ResultStream, Runner, RunnerFleet, SourceInventory}
  alias Mondek.CoverageFixtures, as: F

  setup do
    Repo.query!("TRUNCATE runners, assignments RESTART IDENTITY CASCADE")
    :ok
  end

  test "all runners remain reachable with stable ties, complete counts and SQL ordering before pagination" do
    runners =
      for index <- 1..131 do
        runner("Same observer", last_seen_at: DateTime.add(at(), -index))
      end

    last = List.last(runners)
    result(last, knowledge: "unavailable")
    first = RunnerFleet.list(%{}, at())
    assert first["total"] == 131
    assert first["page_size"] == 25
    assert length(first["items"]) == 25
    assert hd(first["items"])["id"] == last.id
    assert first["counts"]["recent"] == 59
    assert first["counts"]["overdue"] == 72
    assert first["counts"]["empty"] == 130
    assert first["counts"]["issues"] == 1
    assert first["counts"]["coverage"]["unavailable"] == 1
    assert RunnerFleet.counts(at()) == first["counts"]

    pages = for page <- 1..6, do: RunnerFleet.list(%{page: page, sort: "name"}, at())
    ids = Enum.flat_map(pages, &Enum.map(&1["items"], fn row -> row["id"] end))
    assert ids == Enum.sort(Enum.map(runners, & &1.id))
    assert length(Enum.uniq(ids)) == 131
    assert List.last(pages)["counts"] == first["counts"]

    clamped = RunnerFleet.list(%{page: "999", page_size: "999"}, at())
    assert clamped["page"] == 3
    assert clamped["page_size"] == 50
    assert length(clamped["items"]) == 31
    assert RunnerFleet.detail(last.id, at())["id"] == last.id

    contacted = RunnerFleet.list(%{sort: "last_contact"}, at())
    assert hd(contacted["items"])["id"] == hd(runners).id
  end

  test "transport and measurement truth vary independently at exact boundaries and after restart" do
    publication = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(publication, at())
    id = publication["installation_id"]
    assert RunnerFleet.detail(id, at())["collection_status"] == "issues"
    assert RunnerFleet.detail(id, at())["coverage"]["awaiting"] == 1
    assert {:ok, _} = F.activate(publication)
    assert disposition(F.sample(publication, "CRIT")) == "current"
    measured = RunnerFleet.detail(id, at())
    assert measured["contact_status"] == "recent"
    assert measured["collection_status"] == "fresh"
    refute Map.has_key?(measured, "health")
    assert measured["coverage"]["fresh"] == 1
    assert RunnerFleet.detail(id, DateTime.add(at(), 12))["coverage"]["stale"] == 1
    assert RunnerFleet.detail(id, DateTime.add(at(), 59))["contact_status"] == "recent"
    assert RunnerFleet.detail(id, DateTime.add(at(), 60))["contact_status"] == "overdue"

    assert disposition(F.sample(publication, "UNKNOWN", 2)) == "current"
    unavailable = RunnerFleet.detail(id, at())
    assert unavailable["contact_status"] == "recent"
    assert unavailable["coverage"]["unavailable"] == 1
    assert Repo.one!(Mondek.Incident).status == "open"

    restarted = Map.merge(publication, %{"boot" => 2, "session_id" => Ecto.UUID.generate()})
    assert {:ok, _} = Monitoring.inventory(restarted, at())
    waiting = RunnerFleet.detail(id, at())
    assert waiting["contact_status"] == "recent"
    assert waiting["coverage"]["awaiting"] == 1
    assert waiting["coverage"]["unavailable"] == 0
  end

  test "filters combine before pagination and summaries cover the fleet and full matching set" do
    healthy = runner("A healthy")
    overdue = runner("B overdue", last_seen_at: DateTime.add(at(), -60))
    mixed = runner("C mixed")
    empty = runner("D empty")
    result(healthy, health: "CRIT")
    result(overdue, health: "OK")
    result(mixed)
    result(mixed, knowledge: "unavailable")
    result(mixed, current: %{})
    result(mixed, source_at: DateTime.add(at(), -12))
    result(empty, retired_at: at())

    filtered = RunnerFleet.list(%{contact: "recent", collection: "issues", page_size: 1}, at())
    assert filtered["total"] == 1
    assert hd(filtered["items"])["id"] == mixed.id
    assert filtered["matching_counts"]["check_count"] == 4

    assert filtered["matching_counts"]["coverage"] == %{
             "active" => 4,
             "expected_count" => 4,
             "fresh" => 1,
             "stale" => 1,
             "unavailable" => 1,
             "awaiting" => 1
           }

    assert filtered["counts"]["total"] == 4
    assert filtered["counts"]["fresh"] == 2
    assert filtered["counts"]["empty"] == 1
    assert filtered["counts"]["check_count"] == 6
    assert RunnerFleet.list(%{contact: "overdue", collection: "fresh"}, at())["total"] == 1
    assert RunnerFleet.list(%{collection: "empty"}, at())["total"] == 1
    assert RunnerFleet.detail(empty.id, at())["retired_check_count"] == 1
    assert RunnerFleet.detail(empty.id, at())["check_count"] == 0
    assert RunnerFleet.detail(empty.id, at())["collection_status"] == "empty"
  end

  test "search matches complete source and execution context without rendering or loading consumer settings" do
    first = runner("Edge _% observer")
    second = runner("Edge generic observer")

    for index <- 1..24 do
      publication(first, "source-#{String.pad_leading(to_string(index), 2, "0")}",
        coverage_context: %{
          "id" => "context-#{index}",
          "label" => "Network #{index}",
          "local_environment" => "exec-environment-#{index}"
        }
      )
    end

    publication(second, "unrelated")
    assert RunnerFleet.list(%{search: "_%"}, at())["total"] == 1
    assert RunnerFleet.list(%{search: "% OR true --"}, at())["total"] == 0
    assert RunnerFleet.list(%{search: first.id}, at())["total"] == 1

    for search <- ~w(source-24 context-24 exec-environment-24) ++ ["Network 24"] do
      result = RunnerFleet.list(%{search: search}, at())
      assert result["total"] == 1
      assert [row] = result["items"]
      assert row["id"] == first.id
      assert length(row["publications"]) == 5
      assert row["publication_count"] == 24
      assert row["publications_omitted"] == 19
      refute Jason.encode!(row) =~ "consumer-secret-never-render"
    end

    assert RunnerFleet.list(%{source_id: "source-24"}, at())["total"] == 1
    assert RunnerFleet.list(%{source_id: "source"}, at())["total"] == 0
    detailed = RunnerFleet.detail(first.id, at())
    assert detailed["publication_count"] == 24
    assert length(detailed["publications"]) == 20
    assert detailed["publications_omitted"] == 4
  end

  test "retired publishers remain labelled historical and never multiply active counts" do
    r = runner("Many sources")
    result(r)
    result(r)
    publication(r, "old", retired_at: at(), retirement_reason: "Replaced")
    publication(r, "new")
    row = RunnerFleet.detail(r.id, at())
    assert row["publication_count"] == 2
    assert row["active_publication_count"] == 1
    assert Enum.map(row["publications"], & &1["source_id"]) == ["new", "old"]
    assert List.last(row["publications"])["retired_at"] == Monitoring.iso(at())
    assert row["check_count"] == 2
    assert row["coverage"]["active"] == 2
    assert RunnerFleet.list(%{search: "old"}, at())["total"] == 1
  end

  test "malformed optional telemetry cannot crash or fabricate zero counters" do
    r =
      runner("Telemetry",
        status: %{
          "queue_count" => "0",
          "queue_bytes" => -1,
          "dropped" => %{"bad" => true},
          "running" => ["one", "two"],
          "oldest_at" => "not a timestamp",
          "diagnostic" => %{"details" => String.duplicate("x", 5_000)},
          "scheduler" => "not a map",
          "unexpected" => "consumer-secret-never-render"
        }
      )

    status = RunnerFleet.detail(r.id, at())["status"]
    assert status["queue_count"] == nil
    assert status["queue_bytes"] == nil
    assert status["dropped"] == nil
    assert status["running"] == 2
    assert status["oldest_at"] == nil
    assert status["scheduler"]["due_waiting_checks"] == nil
    assert String.length(status["diagnostic"]) == 2_000
    refute Map.has_key?(status, "unexpected")

    Monitoring.change(r, %{
      status: %{
        "queue_count" => 0,
        "queue_bytes" => 512,
        "dropped" => 4,
        "oldest_at" => Monitoring.iso(at()),
        "scheduler" => %{
          "due_waiting_checks" => 2,
          "oldest_due_seconds" => 1.5,
          "max_concurrency" => 4,
          "running_checks" => -1
        }
      }
    })

    status = RunnerFleet.detail(r.id, DateTime.add(at(), 120))["status"]
    assert status["queue_count"] == 0
    assert status["queue_bytes"] == 512
    assert status["dropped"] == 4
    assert status["oldest_at"] == Monitoring.iso(at())
    assert status["scheduler"]["due_waiting_checks"] == 2
    assert status["scheduler"]["oldest_due_seconds"] == 1.5
    assert status["scheduler"]["max_concurrency"] == 4
    assert status["scheduler"]["running_checks"] == nil
  end

  test "empty and invalid inputs are bounded and unregistered identities remain not found" do
    empty = RunnerFleet.list(%{page: "999", search: ["bad"], contact: %{}, sort: "sql"}, at())
    assert empty["total"] == 0
    assert empty["page"] == 1
    assert empty["items"] == []
    assert empty["counts"]["coverage"]["active"] == 0
    assert empty["matching_counts"] == empty["counts"]
    assert empty["filters"]["sort"] == "attention"
    assert empty["filters"]["contact"] == "all"
    assert RunnerFleet.detail("broken", at()) == nil
    assert RunnerFleet.detail(nil, at()) == nil
    assert RunnerFleet.detail(Ecto.UUID.generate(), at()) == nil
  end

  defp runner(label, opts \\ []) do
    Repo.insert!(
      struct(
        Runner,
        Keyword.merge(
          [
            id: Ecto.UUID.generate(),
            session_id: Ecto.UUID.generate(),
            boot: 1,
            label: label,
            last_seen_at: at()
          ],
          opts
        )
      )
    )
  end

  defp result(runner, opts \\ []) do
    id = Ecto.UUID.generate()
    retired_at = Keyword.get(opts, :retired_at)

    Repo.insert!(%Assignment{
      id: id,
      kind: "10000000-0000-4000-8000-000000000003",
      label: id,
      source_key: id,
      source_id: "fleet-test",
      runner_id: runner.id,
      params: %{},
      expected_keys: ["health"],
      authorized_generation: 1,
      retired_at: retired_at,
      retirement_reason: if(retired_at, do: "Source removed")
    })

    Repo.insert!(%ResultStream{
      assignment_id: id,
      result_key: "health",
      label: "Health",
      target: %{"kind" => "host", "key" => runner.id, "label" => runner.label},
      retired_at: retired_at,
      current:
        Keyword.get(opts, :current, %{
          "generation" => 1,
          "session_id" => runner.session_id,
          "health" => Keyword.get(opts, :health, "OK"),
          "knowledge" => Keyword.get(opts, :knowledge, "fresh"),
          "source_at" => Monitoring.iso(Keyword.get(opts, :source_at, at()))
        })
    })
  end

  defp publication(runner, source_id, opts \\ []) do
    context = Keyword.get(opts, :coverage_context)

    fields = [
      runner_id: runner.id,
      source_id: source_id,
      revision: 1,
      source_revision: String.duplicate("a", 64),
      payload: %{"params" => "consumer-secret-never-render"},
      received_at: at()
    ]

    fields =
      if context do
        Keyword.merge(fields,
          coverage_version: 1,
          coverage_revision: 1,
          coverage_received_at: at(),
          coverage_source_revision: String.duplicate("a", 64),
          coverage_code_revision: String.duplicate("a", 64),
          coverage_runtime_revision: String.duplicate("a", 64),
          coverage_confirmed: true
        )
      else
        fields
      end

    Repo.insert!(struct(SourceInventory, Keyword.merge(fields, opts)))
  end
end
