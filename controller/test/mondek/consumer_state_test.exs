# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConsumerStateTest do
  use Mondek.DataCase, async: false
  alias Mondek.ConsumerState, as: State
  alias Mondek.ConsumerState.{Entry, Namespace}
  @assignment "10000000-0000-4000-8000-000000000001"

  def request(op, fields \\ %{}) do
    c = control()
    # Native source fixtures don't publish a complete inventory.
    Repo.insert_all(
      Mondek.SourceInventory,
      [
        %{
          runner_id: c["installation_id"],
          source_id: "controller-fixture-source",
          revision: 1,
          source_revision: String.duplicate("a", 64),
          payload: %{},
          received_at: at()
        }
      ],
      on_conflict: :nothing
    )

    a = Repo.get!(Assignment, @assignment)
    a |> Ecto.Changeset.change(authorized_generation: 1) |> Repo.update!()

    Map.merge(
      %{
        "version" => 1,
        "operation" => op,
        "installation_id" => c["installation_id"],
        "session_id" => c["session_id"],
        "boot" => 1,
        "assignment_id" => @assignment,
        "generation" => 1,
        "source_id" => a.source_id,
        "scope" => "source",
        "key" => "peers"
      },
      fields
    )
  end

  test "recursive JSON accounting agrees with SDK vectors" do
    cases = File.read!("../contracts/v1/consumer-state.json") |> Jason.decode!()
    for c <- cases["values"], do: assert(State.value_bytes(c["value"]) == c["bytes"])
  end

  test "missing differs from JSON null, versions change, conditional writes fence ABA" do
    p = request("get")
    assert {:ok, %{"status" => "missing", "entry" => nil}} = State.exchange(p)
    assert Repo.aggregate(Namespace, :count) == 0
    assert {:ok, %{"entry" => first}} = State.exchange(request("put", %{"value" => nil}))
    assert first.value == nil
    assert {:ok, %{"entry" => second}} = State.exchange(request("put", %{"value" => nil}))
    refute first.version == second.version

    assert {:ok, %{"status" => "conflict"}} =
             State.exchange(
               request("compare_and_set", %{"expected_version" => first.version, "value" => []})
             )

    assert {:ok, _} = State.exchange(request("delete"))

    assert {:ok, %{"entry" => third}} =
             State.exchange(
               request("compare_and_set", %{"expected_version" => "missing", "value" => []})
             )

    refute third.version == first.version

    assert {:ok, %{"status" => "conflict"}} =
             State.exchange(request("delete", %{"expected_version" => second.version}))

    assert Repo.get!(Namespace, p["source_id"]).entries == 1
  end

  test "TTL boundary is logical, create-if-absent replaces expiry and clears old TTL" do
    p = request("put", %{"value" => %{"items" => []}, "ttl_seconds" => 1})
    assert {:ok, %{"entry" => first}} = State.exchange(p, fn -> at() end)
    boundary = DateTime.add(at(), 1)
    assert {:ok, %{"status" => "missing"}} = State.exchange(request("get"), fn -> boundary end)

    assert {:ok, %{"entry" => next}} =
             State.exchange(
               request("compare_and_set", %{"value" => false, "expected_version" => "missing"}),
               fn -> boundary end
             )

    assert next.expires_at == nil
    refute next.version == first.version
    assert Repo.get!(Namespace, p["source_id"]).entries == 1
  end

  test "state fences session, boot, source, generation and retirement without registration" do
    p = request("put", %{"value" => 7})

    for change <- [
          %{"session_id" => Ecto.UUID.generate()},
          %{"boot" => 2},
          %{"source_id" => "another"},
          %{"generation" => 2}
        ] do
      assert {:error, :state_not_authorized} = State.exchange(Map.merge(p, change))
    end

    assert Repo.aggregate(Namespace, :count) == 0
    assert {:ok, _} = State.exchange(p)
    local = Map.put(p, "scope", "check")
    assert {:ok, %{"entry" => e}} = State.exchange(local)
    a = Repo.get!(Assignment, @assignment)
    Repo.update!(Ecto.Changeset.change(a, retired_at: at(), retirement_reason: "source_removed"))
    assert {:error, :state_not_authorized} = State.exchange(p)
    assert {:error, :not_found} = State.get(e.id)
    assert State.cleanup() == 1
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "concurrent CAS has exactly one winner and consistent accounting" do
    p =
      request("compare_and_set", %{"expected_version" => "missing", "value" => %{"counter" => 1}})

    results =
      1..8
      |> Task.async_stream(fn _ -> State.exchange(p) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, {:ok, r}} -> r["status"] end)

    assert Enum.count(results, &(&1 == "stored")) == 1
    assert Enum.count(results, &(&1 == "conflict")) == 7

    assert Repo.get!(Namespace, p["source_id"]).bytes ==
             Repo.one!(from e in Entry, select: e.bytes)
  end

  test "value, nesting, key and aggregate quotas roll back atomically" do
    p = request("put", %{"value" => String.duplicate("x", 65_534)})
    assert {:ok, _} = State.exchange(p)

    assert {:error, {:invalid, _}} =
             State.exchange(Map.put(p, "value", String.duplicate("x", 65_535)))

    assert {:error, {:invalid, _}} = State.exchange(Map.put(p, "value", %{"nul" => <<0>>}))
    assert {:error, {:invalid, _}} = State.exchange(Map.put(p, "key", "bad\nkey"))

    assert {:error, {:invalid, _}} =
             State.exchange(Map.put(p, "value", Enum.reduce(1..33, nil, fn _, x -> [x] end)))

    for i <- 1..14, do: assert({:ok, _} = State.exchange(%{p | "key" => "key#{i}"}))
    assert {:error, :state_quota_exceeded} = State.exchange(%{p | "key" => "overflow"})
    assert Repo.get!(Namespace, p["source_id"]).entries == 15
    assert Repo.aggregate(Entry, :count) == 15
  end

  test "two publications share source data but assignment-local state stays separate" do
    one = Mondek.ConsumerStateFixtures.observer()
    two = Mondek.ConsumerStateFixtures.observer()

    assert {:ok, %{"entry" => first}} =
             State.exchange(Map.merge(one, %{"operation" => "put", "value" => ["peer-a"]}))

    assert {:ok, %{"entry" => same}} = State.exchange(two)
    assert same.version == first.version

    assert {:ok, %{"entry" => local}} =
             State.exchange(
               Map.merge(one, %{"operation" => "put", "scope" => "check", "value" => "local"})
             )

    assert {:ok, %{"status" => "missing"}} = State.exchange(Map.put(two, "scope", "check"))

    pub =
      Repo.get_by!(Mondek.SourceInventory,
        runner_id: one["installation_id"],
        source_id: one["source_id"]
      )

    Repo.update!(
      Ecto.Changeset.change(pub,
        retired_at: Monitoring.now(),
        retirement_reason: "operator_retired"
      )
    )

    assert {:error, :state_not_authorized} = State.exchange(one)
    assert {:ok, %{"entry" => still_shared}} = State.exchange(two)
    assert still_shared.version == first.version
    # Retirement of the assignment is the local-data lifetime boundary.
    a = Repo.get!(Assignment, one["assignment_id"])

    Repo.update!(
      Ecto.Changeset.change(a, retired_at: Monitoring.now(), retirement_reason: "source_removed")
    )

    assert {:error, :not_found} = State.get(local.id)
  end

  test "expiry clock is sampled after waiting for namespace ownership" do
    p = Mondek.ConsumerStateFixtures.observer()
    start = Monitoring.now()

    assert {:ok, %{"entry" => first}} =
             State.exchange(
               Map.merge(p, %{"operation" => "put", "value" => 1, "ttl_seconds" => 1}),
               fn -> start end
             )

    {:ok, clock} = Agent.start_link(fn -> start end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from n in Namespace, where: n.source_id == ^p["source_id"], lock: "FOR UPDATE"
          )

          send(parent, :namespace_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :namespace_held

    writer =
      Task.async(fn ->
        State.exchange(
          Map.merge(p, %{
            "operation" => "compare_and_set",
            "expected_version" => first.version,
            "value" => 2
          }),
          fn -> Agent.get(clock, & &1) end
        )
      end)

    assert Task.yield(writer, 50) == nil
    Agent.update(clock, fn _ -> DateTime.add(start, 1) end)
    send(holder.pid, :release)
    Task.await(holder)
    assert {:ok, %{"status" => "conflict"}} = Task.await(writer)
  end

  test "session fencing is rechecked after lock waits and state doesn't refresh contact" do
    p = Mondek.ConsumerStateFixtures.observer()
    original = Repo.get!(Mondek.Runner, p["installation_id"])
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          r =
            Repo.one!(
              from r in Mondek.Runner, where: r.id == ^original.id, lock: "FOR NO KEY UPDATE"
            )

          send(parent, :runner_held)

          receive do
            :release -> :ok
          end

          Repo.update!(Ecto.Changeset.change(r, session_id: Ecto.UUID.generate(), boot: 2))
        end)
      end)

    assert_receive :runner_held

    writer =
      Task.async(fn -> State.exchange(Map.merge(p, %{"operation" => "put", "value" => 1})) end)

    assert Task.yield(writer, 50) == nil
    send(holder.pid, :release)
    Task.await(holder)
    assert {:error, :state_not_authorized} = Task.await(writer)
    assert Repo.get!(Mondek.Runner, original.id).last_seen_at == original.last_seen_at
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "physical entry quota includes expired unswept data and cleanup frees capacity" do
    p = Mondek.ConsumerStateFixtures.observer()
    now = Monitoring.now()
    Repo.insert!(%Namespace{source_id: p["source_id"], entries: 1024, bytes: 1024})

    entries =
      for i <- 1..1024,
          do: %{
            id: Ecto.UUID.generate(),
            source_id: p["source_id"],
            scope: "source",
            key: "old#{i}",
            payload: %{"value" => nil},
            version: Ecto.UUID.generate(),
            bytes: 1,
            updated_at: now,
            expires_at: DateTime.add(now, -1),
            installation_id: p["installation_id"],
            session_id: p["session_id"],
            assignment_id: p["assignment_id"],
            generation: 1
          }

    Repo.insert_all(Entry, entries)
    put = Map.merge(p, %{"operation" => "put", "value" => nil})
    assert {:error, :state_quota_exceeded} = State.exchange(put)

    assert {:ok, _} =
             State.exchange(
               Map.merge(put, %{
                 "key" => "old1",
                 "operation" => "compare_and_set",
                 "expected_version" => "missing"
               })
             )

    assert State.cleanup(10) == 10
    assert Repo.get!(Namespace, p["source_id"]).entries == 1014
    assert {:ok, _} = State.exchange(put)
  end

  test "different installations contend on source CAS and quota, with exact accounting" do
    one = Mondek.ConsumerStateFixtures.observer()
    two = Mondek.ConsumerStateFixtures.observer()

    requests =
      for p <- [one, two],
          do:
            Map.merge(p, %{
              "operation" => "compare_and_set",
              "expected_version" => "missing",
              "value" => 1
            })

    results =
      requests
      |> Task.async_stream(&State.exchange/1, max_concurrency: 2)
      |> Enum.map(fn {:ok, {:ok, r}} -> r["status"] end)

    assert Enum.sort(results) == ["conflict", "stored"]
    assert {:ok, _} = State.exchange(Map.put(one, "operation", "delete"))

    for i <- 1..15 do
      assert {:ok, _} =
               State.exchange(
                 Map.merge(one, %{
                   "operation" => "put",
                   "key" => "seed#{i}",
                   "value" => String.duplicate("x", 65_500)
                 })
               )
    end

    requests =
      for {p, key} <- [{one, "quota-one"}, {two, "quota-two"}],
          do:
            Map.merge(p, %{
              "operation" => "put",
              "key" => key,
              "value" => String.duplicate("y", 40_000)
            })

    results =
      requests
      |> Task.async_stream(&State.exchange/1, max_concurrency: 2)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, %{"status" => "stored"}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :state_quota_exceeded})) == 1
    ns = Repo.get!(Namespace, one["source_id"])
    assert ns.bytes == Repo.aggregate(Entry, :sum, :bytes)
    assert ns.entries == Repo.aggregate(Entry, :count)
  end

  test "cleanup rechecks a renewal committed while waiting for namespace ownership" do
    p = Mondek.ConsumerStateFixtures.observer()

    assert {:ok, %{"entry" => first}} =
             State.exchange(
               Map.merge(p, %{"operation" => "put", "value" => 1, "ttl_seconds" => 1}),
               fn -> DateTime.add(Monitoring.now(), -10) end
             )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from n in Namespace, where: n.source_id == ^p["source_id"], lock: "FOR UPDATE"
          )

          send(parent, :renewal_held)

          receive do
            :renew -> :ok
          end

          Repo.get!(Entry, first.id)
          |> Ecto.Changeset.change(
            expires_at: DateTime.add(Monitoring.now(), 60),
            version: Ecto.UUID.generate()
          )
          |> Repo.update!()
        end)
      end)

    assert_receive :renewal_held
    cleanup = Task.async(fn -> State.cleanup() end)
    assert Task.yield(cleanup, 50) == nil
    send(holder.pid, :renew)
    Task.await(holder)
    assert Task.await(cleanup) == 1
    assert {:ok, %{"entry" => current}} = State.exchange(p)
    refute current.version == first.version
    assert Repo.get!(Namespace, p["source_id"]).entries == 1
  end

  test "authorized generation cutover fences a waiting operation and rate cap is bounded" do
    p = Mondek.ConsumerStateFixtures.observer()
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from r in Mondek.Runner,
              where: r.id == ^p["installation_id"],
              lock: "FOR NO KEY UPDATE"
          )

          a =
            Repo.one!(
              from a in Assignment, where: a.id == ^p["assignment_id"], lock: "FOR UPDATE"
            )

          send(parent, :cutover_held)

          receive do
            :cutover -> :ok
          end

          # The fixture models the authorized-generation boundary, not a desired save.
          Repo.update!(Ecto.Changeset.change(a, authorized_generation: nil))
        end)
      end)

    assert_receive :cutover_held

    writer =
      Task.async(fn -> State.exchange(Map.merge(p, %{"operation" => "put", "value" => 1})) end)

    assert Task.yield(writer, 50) == nil
    send(holder.pid, :cutover)
    Task.await(holder)
    assert {:error, :state_not_authorized} = Task.await(writer)
    a = Repo.get!(Assignment, p["assignment_id"])
    Repo.update!(Ecto.Changeset.change(a, authorized_generation: 1))
    r = Repo.get!(Mondek.Runner, p["installation_id"])
    Repo.update!(Ecto.Changeset.change(r, state_window_at: State.now(), state_requests: 256))
    assert {:error, :state_rate_limited} = State.exchange(p)
    assert Repo.aggregate(Namespace, :count) == 0

    Repo.update!(
      Ecto.Changeset.change(r,
        state_window_at: DateTime.add(State.now(), -2),
        state_requests: 256
      )
    )

    assert {:ok, %{"status" => "missing"}} = State.exchange(p)
    assert Repo.get!(Mondek.Runner, r.id).state_requests == 1
  end
end
