# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CoverageTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Coverage, SourceInventory, CoverageDeclaration, Runner}
  alias Mondek.CoverageFixtures, as: F

  test "group metadata persists for excluded declarations and must match selected outputs" do
    group = %{"key" => "shared", "label" => "Shared"}

    selected =
      F.candidate(F.check("selected")) |> put_in(["outputs", Access.at(0), "group"], group)

    excluded =
      F.candidate(F.check("excluded"), false) |> put_in(["outputs", Access.at(0), "group"], group)

    publication = F.publication([selected, excluded])
    assert {:ok, _} = Monitoring.inventory(publication, at())
    assert Enum.all?(Repo.all(CoverageDeclaration), &(&1.check_group == group))

    mismatch =
      put_in(
        publication,
        ["coverage", "candidates", Access.at(0), "outputs", Access.at(0), "group", "key"],
        "other"
      )

    assert {:error, {:invalid, _}} = Coverage.validate(mismatch)

    explicit_null =
      put_in(
        publication,
        ["coverage", "candidates", Access.at(1), "outputs", Access.at(0), "group"],
        nil
      )

    assert {:error, {:invalid, _}} = Coverage.validate(explicit_null)
  end

  test "zero-selected catalogues expose concrete missing scopes and unresolved templates" do
    remote = F.candidate(F.check("node-b", "production", "never-installed-node"), false)

    unbound =
      F.candidate(F.check("local-template"), false)
      |> Map.merge(%{
        "environment" => nil,
        "environment_label" => nil,
        "scope_resolved" => false,
        "scope_reason" => "Declare a monitored environment"
      })
      |> put_in(["outputs", Access.at(0), "target"], nil)

    p = F.publication([remote, unbound])
    assert {:ok, %{"accepted_checks" => 0}} = Monitoring.inventory(p, at())
    result = Coverage.scopes(%{}, at())
    assert result["total"] == 1
    [scope] = result["items"]
    assert scope["status"] == "missing"
    assert scope["target"]["key"] == "never-installed-node"
    assert scope["counts"]["declaring"] == 1
    assert scope["counts"]["selected"] == 0
    assert result["summary"]["unbound_declarations"] == 1
    [diagnostic] = Coverage.diagnostics(%{}, at())["items"]
    assert diagnostic["scope_reason"] == "Declare a monitored environment"
    assert diagnostic["target"] == nil

    assert Coverage.observers(scope["id"], %{}, at())["items"]
           |> hd()
           |> Map.fetch!("exclusion_reason") == remote["exclusion_reason"]
  end

  test "concrete null environment scopes admit fresh evidence without merging named namespaces" do
    candidate = F.candidate(F.check("service", nil, "shared-target"))
    explicit = F.publication([candidate])

    omitted =
      F.publication([candidate])
      |> Map.update!("checks", fn checks ->
        Enum.map(checks, &Map.drop(&1, ~w(environment environment_label)))
      end)

    named = F.publication([F.candidate(F.check("service", "production", "shared-target"))])

    for p <- [explicit, omitted, named] do
      assert {:ok, _} = Monitoring.inventory(p, at())
      assert {:ok, _} = F.activate(p)
      assert disposition(F.sample(p, "CRIT")) == "current"
    end

    listing = Coverage.scopes(%{}, at())
    assert listing["total"] == 2
    null = Enum.find(listing["items"], &is_nil(&1["environment"]))
    production = Enum.find(listing["items"], &(&1["environment"] == "production"))
    refute null["id"] == production["id"]
    assert null["environment_label"] == nil
    assert null["counts"]["selected"] == 2
    assert null["counts"]["fresh"] == 2
    assert null["status"] == "observed"
    assert production["counts"]["fresh"] == 1

    assert Enum.all?(
             Coverage.observers(null["id"], %{}, at())["items"],
             &(&1["measurement_state"] == "fresh" and is_nil(&1["environment"]))
           )

    assert Coverage.diagnostics(%{}, at())["total"] == 0
  end

  test "fresh Critical is covered; desired version, collection, age and session remain authoritative" do
    p = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert hd(Coverage.scopes(%{}, at())["items"])["status"] == "awaiting"
    assert {:ok, _} = F.activate(p)
    assert disposition(F.sample(p, "CRIT")) == "current"
    [scope] = Coverage.scopes(%{}, at())["items"]
    assert scope["status"] == "observed"
    [observer] = Coverage.observers(scope["id"], %{}, at())["items"]
    assert observer["current"]["health"] == "CRIT"
    assert observer["measurement_state"] == "fresh"
    incident = Repo.one!(Incident)

    newer =
      p |> Map.merge(%{"inventory_revision" => 2, "source_revision" => String.duplicate("f", 64)})

    assert {:ok, _} = Monitoring.inventory(newer, at())
    scope = Coverage.scope(scope["id"], at())
    assert scope["status"] == "awaiting"
    assert scope["counts"]["older_version"] == 1
    assert scope["counts"]["fresh"] == 0
    assert {:ok, _} = F.activate(newer)
    assert disposition(F.sample(newer, "UNKNOWN", 2)) == "current"
    assert Coverage.scope(scope["id"], at())["status"] == "unavailable"
    assert Repo.get!(Incident, incident.id).status == "open"
    assert disposition(F.sample(newer, "OK", 3)) == "current"
    assert Coverage.scope(scope["id"], at())["status"] == "observed"
    assert Coverage.scope(scope["id"], DateTime.add(at(), 12))["status"] == "stale"
    restarted = Map.merge(newer, %{"session_id" => Ecto.UUID.generate(), "boot" => 2})
    assert {:ok, _} = Monitoring.inventory(restarted, at())
    assert Coverage.scope(scope["id"], at())["status"] == "awaiting"
  end

  test "observer filters retain complete scope counts and independent verdicts" do
    candidate = F.candidate(F.check())
    one = F.publication([candidate])
    two = F.publication([candidate], %{"runner_label" => "Second"})

    for p <- [one, two] do
      assert {:ok, _} = Monitoring.inventory(p, at())
      assert {:ok, _} = F.activate(p)
    end

    assert disposition(F.sample(one, "CRIT")) == "current"
    assert disposition(F.sample(two, "UNKNOWN")) == "current"
    [scope] = Coverage.scopes(%{"runner_id" => one["installation_id"]}, at())["items"]
    assert scope["status"] == "partial"
    assert scope["counts"]["declaring"] == 2
    assert scope["counts"]["selected"] == 2
    assert scope["counts"]["fresh"] == 1
    assert scope["counts"]["unavailable"] == 1
    assert Coverage.observers(scope["id"], %{}, at())["total"] == 2
    assert Coverage.scopes(%{"runner_id" => Ecto.UUID.generate()}, at())["total"] == 0
    assert Repo.one!(Incident).health == "CRIT"
  end

  test "complete withdrawal affects one publisher; downgrade preserves last-known declarations" do
    c = F.candidate(F.check(), false)
    one = F.publication([c])
    two = F.publication([c])
    for p <- [one, two], do: assert({:ok, _} = Monitoring.inventory(p, at()))
    id = hd(Coverage.scopes(%{}, at())["items"])["id"]
    empty = one |> Map.put("inventory_revision", 2) |> put_in(["coverage", "candidates"], [])
    assert {:ok, _} = Monitoring.inventory(empty, at())
    assert Coverage.scope(id, at())["counts"]["declaring"] == 1
    old = two |> Map.put("inventory_revision", 2) |> Map.delete("coverage")
    assert {:ok, _} = Monitoring.inventory(old, at())
    assert Coverage.scope(id, at())["status"] == "unconfirmed"
    assert Coverage.summary(%{}, at())["unconfirmed_publishers"] == 1
    restored = Map.put(two, "inventory_revision", 3)
    assert {:ok, _} = Monitoring.inventory(restored, at())
    assert Coverage.scope(id, at())["status"] == "missing"
    assert {:error, :stale_inventory} = Monitoring.inventory(two, at())
    assert Coverage.scope(id, at())["counts"]["declaring"] == 1
  end

  test "older publishers are unsupported without inferred empty declarations" do
    p = F.publication([]) |> Map.delete("coverage")
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert Coverage.summary(%{}, at())["unsupported_publishers"] == 1
    [publisher] = Coverage.publishers(%{}, at())["items"]
    assert publisher["audit_status"] == "unsupported"
    assert publisher["declarations"] == 0
  end

  test "catalogue replay is immutable and malformed proposals preserve accepted membership" do
    p = F.publication([F.candidate(F.check())])
    assert {:ok, reply} = Monitoring.inventory(p, at())
    source = Repo.one!(SourceInventory)
    rows = Repo.all(CoverageDeclaration)
    assert {:ok, ^reply} = Monitoring.inventory(p, DateTime.add(at(), 1))
    changed = put_in(p, ["coverage", "runner_context", "label"], "Changed")
    assert {:error, :inventory_conflict} = Monitoring.inventory(changed, at())

    invalid = [
      put_in(p, ["coverage", "version"], 999),
      put_in(p, ["coverage", "candidates", Access.at(0), "selected"], false),
      put_in(
        p,
        ["coverage", "candidates", Access.at(0), "outputs", Access.at(0), "target", "key"],
        "wrong"
      ),
      put_in(p, ["coverage", "candidates", Access.at(0), "label"], "nul\0value"),
      Map.put(p, "coverage", nil),
      put_in(p, ["coverage", "candidates"], [])
    ]

    for bad <- invalid do
      assert {:error, {:invalid, _}} =
               Monitoring.inventory(Map.put(bad, "inventory_revision", 2), at())

      assert Repo.one!(SourceInventory) == source
      assert Repo.all(CoverageDeclaration) == rows
    end
  end

  test "scope identity is exact while package, runtime and definition differences remain visible" do
    c = F.candidate(F.check())
    one = F.publication([c])

    two =
      F.publication([c])
      |> put_in(["coverage", "code_revision"], String.duplicate("1", 64))
      |> put_in(["coverage", "runtime_revision"], String.duplicate("2", 64))
      |> put_in(
        ["coverage", "candidates", Access.at(0), "definition_revision"],
        String.duplicate("3", 64)
      )

    for p <- [one, two], do: assert({:ok, _} = Monitoring.inventory(p, at()))
    [scope] = Coverage.scopes(%{}, at())["items"]
    assert scope["code_variants"] == 2
    assert scope["runtime_variants"] == 2
    assert scope["definition_variants"] == 2

    for overrides <- [
          %{"source_id" => "another-source"},
          %{
            "coverage" =>
              Map.put(one["coverage"], "candidates", [F.candidate(F.check("other"), false)])
          },
          %{
            "coverage" =>
              Map.put(one["coverage"], "candidates", [
                F.candidate(F.check("service", "staging"), false)
              ])
          }
        ] do
      p = F.publication([], overrides)
      assert {:ok, _} = Monitoring.inventory(p, at())
    end

    # The empty different source does not fabricate a scope.
    assert Coverage.scopes(%{}, at())["total"] == 3
  end

  test "all 8192 excluded output declarations remain countable with bounded pages" do
    candidates =
      for n <- 1..512 do
        outputs =
          for k <- 1..16,
              do: %{
                "key" => "result-#{k}",
                "label" => "Result #{k}",
                "target" => %{"key" => "target-#{n}", "kind" => "host", "label" => "Target #{n}"}
              }

        check = F.check("check-#{n}") |> Map.put("outputs", outputs)
        F.candidate(check, false)
      end

    p = F.publication(candidates)
    assert {:ok, _} = Monitoring.inventory(p, at())
    page = Coverage.scopes(%{}, at())
    assert page["total"] == 8192
    assert page["summary"]["missing"] == 8192
    assert length(page["items"]) == 25
    last = Coverage.scopes(%{"page" => 9999}, at())
    assert last["page"] == 328
    assert length(last["items"]) == 17
    assert Coverage.scopes(%{"search" => "target-512"}, at())["total"] == 16
    assert Repo.aggregate(CoverageDeclaration, :count) == 8192
  end

  test "contact freshness does not erase still-fresh desired measurement coverage" do
    p = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(p, at())
    assert {:ok, _} = F.activate(p)
    assert disposition(F.sample(p)) == "current"

    Repo.update_all(from(r in Runner, where: r.id == ^p["installation_id"]),
      set: [last_seen_at: DateTime.add(at(), -20)]
    )

    [scope] = Coverage.scopes(%{}, at())["items"]
    assert scope["status"] == "observed"
    assert scope["counts"]["offline"] == 1
    assert scope["counts"]["declaring"] == 1
    assert scope["counts"]["fresh"] == 1
  end

  test "concurrent complete publications are serialized before declarations or assignments change" do
    base = F.publication([F.candidate(F.check("original"))])
    assert {:ok, _} = Monitoring.inventory(base, at())

    variants =
      for name <- ["alpha", "beta"] do
        F.publication(
          [F.candidate(F.check(name), false)],
          Map.merge(Map.take(base, ~w(installation_id session_id boot)), %{
            "inventory_revision" => 2
          })
        )
      end

    parent = self()

    {:ok, tasks} =
      Mondek.ConfigurationRepository.transaction("inventory", fn ->
        Mondek.ConfigurationRules.lock_source!(base["source_id"])
        [[holder]] = Repo.query!("SELECT pg_backend_pid()").rows

        tasks =
          Enum.map(variants, fn publication ->
            Task.async(fn ->
              Repo.checkout(fn ->
                [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {:waiting, pid})
                {publication, Monitoring.inventory(publication, at())}
              end)
            end)
          end)

        pids =
          for _ <- tasks do
            receive do
              {:waiting, pid} -> pid
            after
              5000 -> flunk("publisher did not start")
            end
          end

        Enum.each(pids, &await_blocked(&1, holder, System.monotonic_time(:millisecond) + 5000))
        assert Repo.one!(SourceInventory).revision == 1
        assert Repo.one!(CoverageDeclaration).source_key == "original"
        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 10000))
    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 1
    assert Enum.count(results, &match?({_, {:error, :inventory_conflict}}, &1)) == 1
    {winner, _} = Enum.find(results, &match?({_, {:ok, _}}, &1))

    assert Repo.one!(CoverageDeclaration).source_key ==
             hd(winner["coverage"]["candidates"])["key"]

    assert Repo.one!(SourceInventory).revision == 2
    assert F.assignments(base) == []
  end

  test "database constraints reject orphaned scope and publisher metadata shapes" do
    p = F.publication([F.candidate(F.check(), false)])
    assert {:ok, _} = Monitoring.inventory(p, at())
    row = Repo.one!(CoverageDeclaration)

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(d in CoverageDeclaration, where: d.id == ^row.id),
        set: [scope_id: nil]
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(SourceInventory, set: [coverage_code_revision: nil])
    end

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(d in CoverageDeclaration, where: d.id == ^row.id),
        set: [source_id: "another-owner"]
      )
    end

    assert Repo.get!(CoverageDeclaration, row.id) == row
  end

  test "publisher and observer pages are bounded and filters match every declared label" do
    for n <- 1..27 do
      c =
        F.candidate(F.check(), false)
        |> Map.put("label", if(n == 27, do: "Unique check label", else: "Common"))
        |> put_in(
          ["outputs", Access.at(0), "target", "label"],
          if(n == 27, do: "Unique target label", else: "Common")
        )

      assert {:ok, _} = Monitoring.inventory(F.publication([c]), at())
    end

    [scope] = Coverage.scopes(%{"search" => "Unique target label"}, at())["items"]
    assert scope["counts"]["declaring"] == 27
    assert Coverage.observers(scope["id"], %{}, at())["items"] |> length() == 25
    assert Coverage.observers(scope["id"], %{"page" => 2}, at())["items"] |> length() == 2
    assert Coverage.publishers(%{"environment" => "production"}, at())["total"] == 27
    assert Coverage.publishers(%{"environment" => "staging"}, at())["total"] == 0
    assert Coverage.publishers(%{"page" => 2}, at())["items"] |> length() == 2
  end

  defp await_blocked(pid, holder, deadline) do
    [[blockers]] = Repo.query!("SELECT pg_blocking_pids($1)", [pid]).rows

    if holder not in blockers do
      assert System.monotonic_time(:millisecond) < deadline,
             "publisher never waited for source lock"

      await_blocked(pid, holder, deadline)
    end
  end
end
